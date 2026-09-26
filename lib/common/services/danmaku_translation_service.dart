import 'dart:async';
import 'dart:collection';

import 'package:pure_live/core/translation/danmaku_translator.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/common/services/utils/hive_rx.dart';
import 'package:pure_live/common/services/settings/danmaku_settings_controller.dart';

/// 弹幕翻译的共享状态：译文缓存、可订阅槽位与失败熔断。
///
/// 这里刻意不持有房间、播放器或渲染对象。房间会话随路由进入/离开反复重建，
/// 而缓存应当跨房间存活，两者的生命周期必须分开。
class DanmakuTranslationService extends GetxService {
  static DanmakuTranslationService get to => Get.find<DanmakuTranslationService>();

  /// 连续失败多少次后暂停请求。
  ///
  /// 断网或目标网络不可达时，弹幕每秒都在进来；没有熔断就会持续空转并拖慢
  /// 整条投放链路。
  static const int failureThreshold = 3;

  /// 熔断后的静默时长。
  static const Duration circuitCooldown = Duration(seconds: 60);

  /// 可观察槽位的上限。弹幕列表自身只保留约 160 行，这里留一倍余量。
  static const int slotCapacity = 256;

  /// 译文的正文缓存，按插入顺序淘汰。
  final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();

  /// 行级可观察槽位，按文本去重。
  final LinkedHashMap<String, RxString> _slots = LinkedHashMap<String, RxString>();

  DanmakuTranslator? _translator;
  String? _translatorService;
  String? _translatorKey;
  String? _translatorEndpoint;
  String? _translatorModel;

  int _consecutiveFailures = 0;
  DateTime? _mutedUntil;

  /// 最近一次失败的标识，供设置页显示。
  ///
  /// 存标识而不是成品文案：服务层不依赖 i18n，显示语言由 UI 决定。
  final RxString lastError = RxString('');

  /// 请求是否因连续失败被暂停。
  bool get isMuted {
    final until = _mutedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// 已缓存的译文；没有则返回 null。同步查询，供渲染层直接使用。
  String? cachedTranslation(String text) => _cache[text];

  /// 渲染层专用的安全查表。
  ///
  /// 弹幕可能在服务注册完成之前就被渲染（例如独立测试夹具），这里不能抛。
  static String? cachedTranslationOrNull(String text) {
    if (!Get.isRegistered<DanmakuTranslationService>()) return null;
    return Get.find<DanmakuTranslationService>().cachedTranslation(text);
  }

  /// 渲染层专用的安全槽位查询；服务不可用时返回 null，调用方退回原文。
  static RxString? slotOrNull(String text) {
    if (!Get.isRegistered<DanmakuTranslationService>()) return null;
    return Get.find<DanmakuTranslationService>().slotFor(text);
  }

  /// 设置页专用的失败状态槽位；服务不可用时返回 null。
  static RxString? errorSlotOrNull() {
    if (!Get.isRegistered<DanmakuTranslationService>()) return null;
    return Get.find<DanmakuTranslationService>().lastError;
  }

  /// 返回某一行的可观察译文槽位。
  ///
  /// 弹幕列表按消息对象缓存每一行 widget，译文异步到达时不会触发重建，所以
  /// 需要一个稳定的可订阅对象把结果送回那一行。按文本去重，同一句话在整场
  /// 直播里只需要一个槽位；译文先到时会带上初值，因此新建槽位同样是正确的。
  RxString slotFor(String text) {
    final existing = _slots[text];
    if (existing != null) return existing;
    final slot = RxString(_cache[text] ?? '');
    _slots[text] = slot;
    // 先淘汰最旧的槽位。正在显示的槽位会被下一次 build 重新创建，代价只是
    // 一次缓存命中查询，不会丢译文。
    while (_slots.length > slotCapacity) {
      _slots.remove(_slots.keys.first);
    }
    return slot;
  }

  /// 批量翻译。返回与 [texts] 等长的列表，无法翻译的位置为 null。
  ///
  /// 命中缓存、判定为"已经读得懂"以及开关关闭的文本都不产生网络请求。
  Future<List<String?>> translateBatch(List<String> texts) async {
    final result = List<String?>.filled(texts.length, null);
    if (texts.isEmpty) return result;
    if (!Get.isRegistered<SettingsService>()) return result;

    final settings = SettingsService.to.danmaku;
    if (!settings.enableDanmakuAutoTranslate.v) return result;
    if (isMuted) return result;

    // 自建后端还没配好时直接放行：既不打一个必然失败的请求，也不让它计入熔断。
    // "配置不全"和"服务故障"是两回事，混在一起用户只会看到莫名其妙的暂停提示。
    final service = settings.danmakuTranslateService.v;
    if (danmakuTranslationNeedsEndpoint(service) && settings.danmakuTranslateEndpointUrl.v.trim().isEmpty) {
      return result;
    }
    if (service == danmakuTranslationServiceOpenAiCompatible &&
        settings.danmakuTranslateModelName.v.trim().isEmpty) {
      return result;
    }

    final targetLang = settings.danmakuTranslateTargetLang.v;

    // 1) 先筛出真正需要出网的文本：缓存命中的直接回填，同一批里的重复文本
    //    合并成一次请求。
    final pending = <String>[];
    final indexesByText = <String, List<int>>{};
    for (var index = 0; index < texts.length; index++) {
      final text = texts[index].trim();
      if (text.isEmpty) continue;
      final cached = _cache[text];
      if (cached != null) {
        result[index] = cached;
        continue;
      }
      if (!danmakuNeedsTranslation(text, targetLang: targetLang)) continue;
      final indexes = indexesByText[text];
      if (indexes == null) {
        indexesByText[text] = <int>[index];
        pending.add(text);
      } else {
        indexes.add(index);
      }
    }
    if (pending.isEmpty) return result;

    // 2) 出网。后端自己吞掉网络异常，这里只负责写回缓存与槽位。
    final translated = await _translatorFor(settings).translate(
      pending,
      sourceLang: danmakuTranslationAutoSource,
      targetLang: targetLang,
    );

    var succeeded = 0;
    for (var index = 0; index < pending.length; index++) {
      final text = pending[index];
      final value = index < translated.length ? translated[index] : null;
      // 与原文相同的返回值代表"没有翻译"，按失败处理而不是当作译文。
      if (value == null || value.isEmpty || value == text) continue;
      succeeded++;
      _store(text, value);
      for (final target in indexesByText[text]!) {
        result[target] = value;
      }
    }
    _recordOutcome(attempted: pending.length, succeeded: succeeded);
    return result;
  }

  void _store(String text, String translation) {
    _cache.remove(text);
    _cache[text] = translation;
    while (_cache.length > danmakuTranslationCacheCapacity) {
      _cache.remove(_cache.keys.first);
    }
    final slot = _slots[text];
    if (slot != null && slot.value != translation) slot.value = translation;
  }

  void _recordOutcome({required int attempted, required int succeeded}) {
    if (attempted == 0) return;
    if (succeeded > 0) {
      _consecutiveFailures = 0;
      _mutedUntil = null;
      lastError.value = '';
      return;
    }
    _consecutiveFailures++;
    lastError.value = 'unavailable';
    if (_consecutiveFailures >= failureThreshold) {
      _consecutiveFailures = 0;
      _mutedUntil = DateTime.now().add(circuitCooldown);
    }
  }

  /// 后端按设置惰性重建：改动服务或 key 后不需要重启，也不必在启动阶段就去
  /// 读取设置控制器（那会在冷启动的依赖容器里形成一次重入）。
  DanmakuTranslator _translatorFor(DanmakuSettingsController settings) {
    final service = settings.danmakuTranslateService.v;
    final apiKey = settings.danmakuTranslateApiKey.v;
    final endpointUrl = settings.danmakuTranslateEndpointUrl.v;
    final modelName = settings.danmakuTranslateModelName.v;
    final current = _translator;
    if (current != null &&
        _translatorService == service &&
        _translatorKey == apiKey &&
        _translatorEndpoint == endpointUrl &&
        _translatorModel == modelName) {
      return current;
    }
    current?.dispose();
    final created = createDanmakuTranslator(
      service: service,
      apiKey: apiKey,
      endpointUrl: endpointUrl,
      modelName: modelName,
    );
    _translator = created;
    _translatorService = service;
    _translatorKey = apiKey;
    _translatorEndpoint = endpointUrl;
    _translatorModel = modelName;
    return created;
  }

  /// 清空译文缓存与失败状态。主要供测试与"换翻译服务后重来"使用。
  void clearCache() {
    _cache.clear();
    _slots.clear();
    lastError.value = '';
  }

  @override
  void onClose() {
    _translator?.dispose();
    _translator = null;
    _cache.clear();
    _slots.clear();
    super.onClose();
  }
}

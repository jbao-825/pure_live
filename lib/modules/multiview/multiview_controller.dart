import 'dart:async';
import 'dart:developer' as developer;

import 'package:pure_live/common/index.dart';
import 'package:flame_barrage/flame_barrage.dart';
import 'package:pure_live/model/live_play_quality.dart';
import 'package:pure_live/core/interface/live_site.dart';
import 'package:pure_live/core/interface/live_danmaku.dart';
import 'package:pure_live/common/global/platform_utils.dart';
import 'package:pure_live/core/interface/live_quality_discovery.dart';
import 'package:pure_live/common/utils/latest_async_value_queue.dart';
import 'package:pure_live/player/core/live_input_playback_binding.dart';
import 'package:pure_live/modules/multiview/models/multiview_models.dart';
import 'package:pure_live/modules/multiview/models/multiview_preset.dart';
import 'package:pure_live/modules/multiview/cells/multiview_cell_player.dart';
import 'package:pure_live/modules/live_play/controllers/player_controller.dart';
import 'package:pure_live/modules/multiview/danmaku/multiview_danmaku_session.dart';

/// 房间对象 → 可播放源解析器。
///
/// 复用站点适配器既有入口（getRoomDetail/getPlayQualites/getPlayUrls），
/// 禁止在 multiview 内复制解析逻辑；测试注入假实现。
/// [preferLowest] 为小格自动降质联动服务：true 时默认取最低档（列表末项）。
typedef MultiviewStreamResolver = Future<MultiviewStreamSource> Function(LiveRoom room, {required bool preferLowest});

/// 进入 multiview 时暂停全局播放器的钩子。
///
/// multiview 自建每格播放器实例，与全局单实例播放系统并存；
/// 两者同时出声不可接受，进入时必须先让全局侧静默。注入以便测试。
typedef MultiviewGlobalPauseHook = Future<void> Function();

/// Loads and saves the per-room volume used by multiview.
///
/// Production reuses the same persistent room-volume store as the normal
/// player. Tests inject deterministic callbacks so the controller remains
/// independent from the GetX settings lifecycle.
typedef MultiviewRoomVolumeLoader = double Function(LiveRoom room);
typedef MultiviewRoomVolumeSaver = Future<void> Function(LiveRoom room, double volume);

/// 多画面同看控制器（无头核心层）。
///
/// 架构决策：
/// - 绕开 PlayerManager/GlobalPlayerService/PlayerPool 的全局单实例假设，
///   通过 [MultiviewCellPlayerFactory] 为每格创建独立 media_kit 实例；
/// - 仅活跃格出声（音频焦点模型），新起播成功的格自动成为焦点；
/// - 所有释放（removeCell/setLayout 缩容/disposeAll）走同一条
///   「pause → 销毁渲染控制器 → 销毁播放内核」路径。
///
/// Remaining enhancement: optional session persistence.
class MultiviewController extends GetxController {
  MultiviewController({
    MultiviewCellPlayerFactory? playerFactory,
    this._streamResolver,
    Site Function(String)? siteFor,
    MultiviewGlobalPauseHook? pauseGlobalPlayback,
    MultiviewDanmakuEngineFactory? danmakuEngineFactory,
    MultiviewRoomVolumeLoader? roomVolumeLoader,
    MultiviewRoomVolumeSaver? roomVolumeSaver,
    int? maxCellCount,
    bool? perCellMode,
  }) : _playerFactory = playerFactory ?? _defaultPlayerFactory,
       _siteFor = siteFor ?? Sites.of,
       _pauseGlobalPlayback = pauseGlobalPlayback ?? _defaultPauseGlobalPlayback,
       _danmakuEngineFactory = danmakuEngineFactory ?? _defaultDanmakuEngineFactory,
       _roomVolumeLoader = roomVolumeLoader ?? _defaultRoomVolumeLoader,
       _roomVolumeSaver = roomVolumeSaver ?? _defaultRoomVolumeSaver,
       maxCellCount = maxCellCount ?? (PlatformUtils.isDesktop ? maxCells : MultiviewLayout.focus.capacity),
       perCellMode = perCellMode ?? PlatformUtils.isWindows {
    if (this.maxCellCount < MultiviewLayout.focus.capacity || this.maxCellCount > maxCells) {
      throw ArgumentError.value(this.maxCellCount, 'maxCellCount', 'must be between 4 and $maxCells');
    }
    _audioFocusTransitions = LatestAsyncValueQueue<int>(_applyAudioFocus);
  }

  /// focus（一大多小）布局的格子数上限。
  ///
  /// 性能护栏：桌面端多实例解码上限取 9 路，超过后 addCell Fail Fast；
  /// 小格滚动呈现由 UI 层负责。
  static const int maxCells = 9;

  /// Effective decoder cap. Mobile remains at four simultaneous cells while
  /// desktop can expand the focus rail to [maxCells].
  final int maxCellCount;

  /// 逐格独立模式：Windows 上启用「每格独立弹幕会话 + 多格同时出声 +
  /// 逐格播放控制条」，其他平台保持既有单声源/单弹幕会话体验不变。
  ///
  /// 默认按平台派生（[PlatformUtils.isWindows]）；测试显式注入即可分别覆盖
  /// 两套行为。它同时决定三件事：
  /// - 音量：true 时只由 [allMuted] 决定静音，各格互不影响、可同时出声；
  ///   false 时维持音频焦点互斥（只有焦点格出声）。
  /// - 弹幕：true 时每格各自持有会话与渲染入口；false 时只有所选格连接。
  /// - 页面交互：true 时点按格子呼出该格控制条，false 时维持晋升/切焦点。
  final bool perCellMode;

  /// 生产环境每格播放器工厂。
  static MultiviewCellPlayerHandle _defaultPlayerFactory({required int renderWidth, required int renderHeight}) {
    return MultiviewCellPlayer(renderWidth: renderWidth, renderHeight: renderHeight);
  }

  /// 生产环境解析器：完整复用 LivePlayController 同一条站点解析链路。
  ///
  /// 同时取回清晰度列表并构造换档加载器闭包（捕获 detail/site/headers），
  /// 后续 setCellQuality 无需重走 getRoomDetail/getPlayQualites。
  Future<MultiviewStreamSource> _defaultStreamResolver(
    LiveRoom room, {
    required bool preferLowest,
    required LiveQualityDiscoveryScope discoveryScope,
  }) => resolveStreamForSite(
    room,
    site: _siteFor(room.platform!),
    preferLowest: preferLowest,
    discoveryScope: discoveryScope,
  );

  @visibleForTesting
  static Future<MultiviewStreamSource> resolveStreamForSite(
    LiveRoom room, {
    required Site site,
    required bool preferLowest,
    LiveInputPlaybackBinder bindOwnedInput = bindLiveInputForPlayback,
    LiveQualityDiscoveryScope? discoveryScope,
  }) async {
    discoveryScope?.checkActive();
    final platform = room.platform!;

    // Multiview must not use the UI-oriented fallback lookup for platforms
    // that expose a strict playback-complete resolver. The fallback can turn
    // a transport/shape failure into an offline-looking room; the strict path
    // preserves the difference between "platform says offline" and "request
    // failed" while retaining all signed playback fields.
    final liveSite = site.liveSite;
    final detail = liveSite is LiveSiteRecordRoomResolver
        ? await (liveSite as LiveSiteRecordRoomResolver).getRoomDetailForRecording(
            roomId: room.roomId!,
            platform: platform,
          )
        : await liveSite.getRoomDetail(roomId: room.roomId!, platform: platform);
    discoveryScope?.checkActive();
    if (detail.isExplicitlyOfflineNow) {
      throw MultiviewRoomOffline(detail);
    }
    if (!detail.isPlayableNow) {
      throw StateError('multiview: room status is ${detail.effectiveLiveStatus.name} for $platform/${room.roomId}');
    }
    final qualities = discoveryScope == null
        ? await liveSite.discoverPlayQualities(detail: detail)
        : await discoveryScope.discover(liveSite, detail);
    if (qualities.isEmpty) {
      throw StateError('multiview: no play qualities for $platform/${room.roomId}');
    }

    // 默认最高档（列表首项）；小格自动降质联动开启时小格取最低档（末项）。
    final qualityIndex = preferLowest ? qualities.length - 1 : 0;
    Future<MultiviewStreamSource> loadQuality(LivePlayQuality quality) async {
      final resolution = await site.liveSite.resolvePlayUrls(detail: detail, quality: quality);
      final nextUrls = resolution.urls;
      if (!resolution.hasSources) {
        throw StateError('multiview: no play urls for $platform/${room.roomId} @ ${quality.quality}');
      }
      final applied = resolveAppliedPlayQuality(qualities: qualities, requested: quality, resolution: resolution);
      final choices = List<LivePlayQuality>.unmodifiable([
        for (final choice in qualities)
          choice.selectionId == applied.selectionId ? applied : choice.withPlaybackUnconfirmed(false),
      ]);
      final appliedIndex = choices.indexWhere((choice) => choice.selectionId == applied.selectionId);
      final recipe = resolution.inputRecipe;
      if (recipe != null) {
        return MultiviewStreamSource.owned(
          source: bindOwnedInput(recipe),
          qualities: choices,
          qualityIndex: appliedIndex < 0 ? qualityIndex : appliedIndex,
        );
      }
      final headers = await PlayerController.resolvePlaybackHeaders(site: site, room: detail);
      return MultiviewStreamSource(
        url: nextUrls.first,
        headers: Map.unmodifiable(headers),
        lines: List.unmodifiable(nextUrls),
        qualities: choices,
        qualityIndex: appliedIndex < 0 ? qualityIndex : appliedIndex,
        sourceQueryPolicies: resolution.sourceQueryPolicies,
      );
    }

    discoveryScope?.checkActive();
    final initial = await loadQuality(qualities[qualityIndex]);
    discoveryScope?.checkActive();
    final owned = initial.ownedSource;
    if (owned != null) {
      return MultiviewStreamSource.owned(
        source: owned,
        qualities: initial.qualities,
        qualityIndex: initial.qualityIndex,
        qualityLoader: loadQuality,
      );
    }
    return MultiviewStreamSource(
      url: initial.url,
      headers: initial.headers,
      qualities: initial.qualities,
      qualityIndex: initial.qualityIndex,
      qualityLoader: loadQuality,
      lines: initial.lines,
      sourceQueryPolicies: initial.sourceQueryPolicies,
    );
  }

  static Future<void> _openCellSource(
    MultiviewCellPlayerHandle handle,
    MultiviewStreamSource source, {
    required bool start,
    String? url,
  }) {
    final owned = source.ownedSource;
    if (owned != null) {
      if (handle is! MultiviewOwnedInputHandle) {
        throw StateError('Multiview backend has no owned-input entry point');
      }
      final consumer = handle as MultiviewOwnedInputHandle;
      return start ? consumer.startOwned(owned) : consumer.openOwned(owned);
    }
    final selected = url ?? source.url;
    return start
        ? handle.start(url: selected, headers: source.headers, sourceQueryPolicy: source.sourceQueryPolicies[selected])
        : handle.open(url: selected, headers: source.headers, sourceQueryPolicy: source.sourceQueryPolicies[selected]);
  }

  /// 生产环境弹幕引擎工厂：复用站点适配器的 getDanmaku()。
  static LiveDanmaku _defaultDanmakuEngineFactory(LiveRoom room) {
    return Sites.of(room.platform!).liveSite.getDanmaku();
  }

  static double _defaultRoomVolumeLoader(LiveRoom room) => room.getSavedVolume();

  static Future<void> _defaultRoomVolumeSaver(LiveRoom room, double volume) {
    return room.saveCurrentVolume(volume);
  }

  /// 生产环境全局播放静默钩子。
  ///
  /// 全局播放服务尚未初始化说明当前没有全局会话，无需处理。
  /// app 浮窗激活时仅 pause 会留下冻结画面悬浮在网格上方，用户点浮窗播放
  /// 即双出声；语义与 AppNavigator.toLiveRoomDetail 进入直播间前一致，
  /// 直接关闭浮窗。其余情况维持暂停行为。
  static Future<void> _defaultPauseGlobalPlayback() async {
    final service = GlobalPlayerService.instance;
    if (!service.initialized) return;
    final manager = service.player;
    if (manager.isAppFloatingActive) {
      await manager.closeAppFloating();
      return;
    }
    if (manager.isPlayingNow) {
      await manager.pause();
    }
  }

  /// 当前布局；初始为四画面（本功能的核心形态）。
  final Rx<MultiviewLayout> layout = MultiviewLayout.quad.obs;

  /// focus（一大多小）布局下当前显示为大画面的格子下标，默认 0。
  ///
  /// 仅在 focus 布局下有语义；其他布局下无意义但保持合法值
  /// （始终在当前容量内），供切换布局时无损恢复。
  final RxInt focusedCellIndex = 0.obs;

  /// 单格状态列表，长度恒等于 [layout] 容量。
  final RxList<MultiviewCellState> cells = RxList<MultiviewCellState>(
    List.generate(MultiviewLayout.quad.capacity, MultiviewCellState.empty),
  );

  /// 每格播放器句柄，与 cells 一一对应；空格为 null。
  final List<MultiviewCellPlayerHandle?> _players = List<MultiviewCellPlayerHandle?>.generate(
    MultiviewLayout.quad.capacity,
    (_) => null,
    growable: true,
  );

  /// 每格加载纪元，用于丢弃迟到的解析/起播结果（竞态防护）。
  final List<int> _cellEpochs = List<int>.generate(MultiviewLayout.quad.capacity, (_) => 0, growable: true);
  // Slot indices are reused after shrinking/expanding. A request identity must
  // never reset with the array slot, even for a non-cancellable legacy resolver.
  int _nextCellEpoch = 0;
  int _advanceCellEpoch(int index) => _cellEpochs[index] = ++_nextCellEpoch;

  /// 每格播放状态（供 UI 播放/暂停按钮态），与 cells 平行维护；
  /// 由句柄的播放状态流订阅驱动，临时暂停/恢复即时翻转。
  final RxList<bool> playingFlags = RxList<bool>(
    List.generate(MultiviewLayout.quad.capacity, (_) => false, growable: true),
  );

  /// 每格播放状态流订阅；随句柄创建/释放同步管理，防泄漏。
  final List<StreamSubscription<bool>?> _playingSubs = List<StreamSubscription<bool>?>.generate(
    MultiviewLayout.quad.capacity,
    (_) => null,
    growable: true,
  );

  /// 音频焦点格下标，默认 0。
  ///
  /// 必须是响应式状态：非 focus 布局点击格子后，顶部音量入口、声音来源
  /// 标识和弹幕目标需要在同一帧切换。旧实现使用普通 int，只能依赖页面
  /// 手工 setState，导致页级弹幕按钮在 1×1/1×2/2×2 下没有有效目标。
  final RxInt _audioFocusIndex = 0.obs;

  /// 是否一键静音所有直播间。
  ///
  /// 开启后所有播放器保持静音；恢复时仅恢复当前音频焦点格，
  /// 不会让多个直播间同时出声。
  final RxBool allMuted = false.obs;

  /// Serializes native mute calls and coalesces rapid focus taps to the latest
  /// cell, preventing out-of-order futures from leaving multiple cells audible.
  late final LatestAsyncValueQueue<int> _audioFocusTransitions;

  /// 小格自动降质联动开关（仅 focus 布局生效）。
  ///
  /// 开启时：向非大画面格分配房间默认取最低档；晋升格自动换最高档、
  /// 被降格的原大画面自动换最低档。关闭时一切维持默认（全部最高档，
  /// 晋升不换流）。
  final RxBool smallCellsLowQuality = false.obs;

  /// multiview 页级弹幕总开关。
  ///
  /// 逐格模式（Windows）默认开启：进入页面并起播后各格立即连接弹幕。
  /// 非逐格模式维持默认关，由用户手动开启后只连接所选格。
  /// 本开关同时控制显隐与连接。
  late final RxBool danmakuEnabled = perCellMode.obs;

  /// 每格弹幕渲染入口：UI 直接接 FlameBarrageWidget(controller: ...)。
  ///
  /// 会话过滤后的聊天消息经 [BarrageItem] 注入；样式/速度调优归 UI 层。
  /// 与 [cells] 平行维护（setLayout/addCell 同步增删）。
  late final List<BarrageController> _barrageControllers = List<BarrageController>.generate(
    MultiviewLayout.quad.capacity,
    (_) => BarrageController(),
  );

  /// 指定格的弹幕渲染控制器；越界返回 null（缩容后 UI 仍可能短暂引用旧下标）。
  BarrageController? barrageControllerFor(int index) =>
      index >= 0 && index < _barrageControllers.length ? _barrageControllers[index] : null;

  final MultiviewCellPlayerFactory _playerFactory;
  final MultiviewStreamResolver? _streamResolver;
  final Site Function(String) _siteFor;
  final Map<int, LiveQualityDiscoveryScope> _discoveryScopes = {};
  final Set<Future<void>> _retiringDiscoveries = {};
  bool _closed = false;

  /// 应用预设的重入保护。
  ///
  /// UI 侧同时禁用入口；这里兜底，避免快速连点两份预设导致布局与房间
  /// 交错成第三种状态。
  bool _applyingPreset = false;

  /// 是否有预设正在应用（UI 据此禁用入口）。
  bool get isApplyingPreset => _applyingPreset;

  void _retireDiscovery(LiveQualityDiscoveryScope scope) {
    late final Future<void> pending;
    pending = scope.close().whenComplete(() => _retiringDiscoveries.remove(pending));
    _retiringDiscoveries.add(pending);
  }

  void _cancelDiscovery(int cellIndex) {
    final scope = _discoveryScopes.remove(cellIndex);
    if (scope != null) _retireDiscovery(scope);
  }

  final MultiviewGlobalPauseHook _pauseGlobalPlayback;
  final MultiviewDanmakuEngineFactory _danmakuEngineFactory;
  final MultiviewRoomVolumeLoader _roomVolumeLoader;
  final MultiviewRoomVolumeSaver _roomVolumeSaver;

  /// 每格弹幕会话：异常自容错（记日志不外抛），绝不影响播放主链路。
  ///
  /// 与 [cells] 平行维护。逐格模式下每格各自连接；非逐格模式下只有
  /// 所选格连接（见 [_syncDanmakuSessions]），与原单会话行为等价。
  late final List<MultiviewDanmakuSession> _danmakuSessions = List<MultiviewDanmakuSession>.generate(
    MultiviewLayout.quad.capacity,
    _createDanmakuSession,
  );

  MultiviewDanmakuSession _createDanmakuSession(int index) {
    return MultiviewDanmakuSession(
      engineFactory: _danmakuEngineFactory,
      onChatMessage: (message) => _forwardChatMessage(index, message),
    );
  }

  /// 响应式监听（onInit 注册，onClose 释放）：弹幕生命周期 + 降质开关 reconcile。
  final List<Worker> _rxWorkers = <Worker>[];

  /// 当前持有音频焦点的格子下标。
  int get audioFocusIndex => _audioFocusIndex.value;

  /// UI-only reactive source for selected-cell controls.
  RxInt get audioFocusIndexState => _audioFocusIndex;

  /// focus 布局下是否还能追加小格。
  bool get canAddCell => layout.value == MultiviewLayout.focus && cells.length < maxCellCount;

  @override
  void onInit() {
    super.onInit();
    // 进入 multiview 时先让全局播放器静默，避免双系统同时出声。
    unawaited(
      _pauseGlobalPlayback().catchError((Object error, StackTrace stackTrace) {
        developer.log(
          'MultiviewController: pause global playback failed',
          name: 'MultiviewController',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
    // 弹幕会话跟随页级开关与大画面切换；房间变化由各变更点显式触发同步。
    _rxWorkers.add(
      everAll([danmakuEnabled, layout, focusedCellIndex, _audioFocusIndex], (_) => unawaited(_syncDanmakuSessions())),
    );
    // 降质开关切换后即时 reconcile 在播小格，避免开关只影响后续分配。
    _rxWorkers.add(ever(smallCellsLowQuality, (_) => unawaited(_reconcileSmallCellQualities())));
  }

  /// 降质开关切换后的即时 reconcile（仅 focus 布局）。
  ///
  /// 开启→在播小格非最低档者降到最低档；关闭→非最高档者升到最高档。
  /// 走 [setCellQuality] 既有纪元防护与错误态呈现，不绕过任何防护。
  Future<void> _reconcileSmallCellQualities() async {
    if (layout.value != MultiviewLayout.focus) return;
    for (var i = 0; i < cells.length; i++) {
      if (i == focusedCellIndex.value) continue;
      final cell = cells[i];
      if (cell.status != MultiviewCellStatus.playing || _players[i] == null) continue;
      if (cell.qualities.isEmpty) continue;
      final targetIndex = smallCellsLowQuality.value ? cell.qualities.length - 1 : 0;
      if (cell.qualityIndex == targetIndex) continue;
      await setCellQuality(i, targetIndex);
    }
  }

  /// 某格在当前设置下是否应静音（唯一的静音判定入口）。
  ///
  /// 非逐格模式：音频焦点互斥——除焦点格外全部静音。
  /// 逐格模式（Windows）：[allMuted] 是唯一静音来源，各格互不影响，
  /// 因而所有格可同时出声，且每格音量独立生效。
  bool _shouldMute(int index) => allMuted.value || (!perCellMode && index != _audioFocusIndex.value);

  Future<void> toggleMuteAll() => setAllMuted(!allMuted.value);
  Future<void> setAllMuted(bool muted) async {
    allMuted.value = muted;

    for (var index = 0; index < _players.length; index++) {
      final handle = _players[index];
      if (handle == null) continue;

      try {
        await handle.setMuted(_shouldMute(index));
      } catch (error, stackTrace) {
        developer.log(
          'MultiviewController: failed to set mute for cell $index',
          name: 'MultiviewController',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void _forwardChatMessage(int index, LiveMessage message) {
    // 与 live_play 的弹幕上屏同构：仅注入内容与颜色，速度等样式归 UI 层。
    barrageControllerFor(index)?.send(
      BarrageItem(
        content: message.message,
        userId: message.userId,
        userName: message.userName,
        textColor: Color.fromARGB(255, message.color.r, message.color.g, message.color.b),
      ),
    );
  }

  int get _selectedCellIndex {
    if (cells.isEmpty) return 0;
    final selected = layout.value == MultiviewLayout.focus ? focusedCellIndex.value : _audioFocusIndex.value;
    return selected.clamp(0, cells.length - 1);
  }

  /// 按当前开关/布局/房间同步各格弹幕会话（幂等）。
  ///
  /// 逐格模式：每格按自己的房间独立连接/断开。
  /// 非逐格模式：只有 [_selectedCellIndex] 一格连接——focus 布局下为大画面，
  /// 1×1/1×2/2×2 下为当前声音来源格，与原单会话行为等价。
  Future<void> _syncDanmakuSessions() async {
    final enabled = danmakuEnabled.value;
    for (var index = 0; index < cells.length && index < _danmakuSessions.length; index++) {
      try {
        final targeted = perCellMode || index == _selectedCellIndex;
        final room = enabled && targeted ? cells[index].room : null;
        final session = _danmakuSessions[index];
        if (room == null || !MultiviewDanmakuSession.supportsRoom(room)) {
          await session.disconnect();
          continue;
        }
        await session.connect(room);
      } catch (error, stackTrace) {
        // 弹幕故障不得影响播放主链路：记录后会话自身状态已由其内部回滚。
        developer.log(
          'MultiviewController: danmaku session sync failed for cell $index',
          name: 'MultiviewController',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// 该格当前是否应渲染弹幕层（开关 + 状态 + 目标格三重判定）。
  ///
  /// UI 每次 build 读取；内部读 Rx 使调用方的 Obx 自动订阅开关与格状态。
  bool shouldRenderDanmaku(int index) {
    if (!danmakuEnabled.value) return false;
    if (index < 0 || index >= cells.length) return false;
    final cell = cells[index];
    if (cell.status != MultiviewCellStatus.playing || cell.videoController == null) return false;
    return perCellMode || index == _selectedCellIndex;
  }

  /// 切换布局；可选地把格子数对齐到目标值。
  ///
  /// 缩容时按同一条释放路径销毁多余格；保留前 N 格的播放状态不重建。
  /// 扩容时追加空白格。Windows 已有格由视图层按实际 cell viewport
  /// 防抖重设渲染目标，无需重建播放器或重新解析直播源。
  ///
  /// [cellCount] 缺省等于新布局的固定容量，此时语义与旧版逐字一致：布局
  /// 未变即不做任何事——focus 经 addCell 扩到多格后再点同一布局不会缩容。
  /// 显式传入时按目标值增删尾部格子，用于恢复场景预设这类"布局 + 动态
  /// 格数"需一并还原的场合；容量范围内的已有格子原样保留，不重建播放器。
  Future<void> setLayout(MultiviewLayout newLayout, {int? cellCount}) async {
    final capacity = newLayout.capacity;
    final target = (cellCount ?? capacity).clamp(capacity, maxCellCount);
    if (newLayout == layout.value && (cellCount == null || target == cells.length)) return;

    // Cancel every removed slot before waiting for any one slow cleanup.
    await Future.wait([for (var i = target; i < _players.length; i++) _releaseSlot(i)]);

    while (cells.length > target) {
      _shrinkSlot();
    }
    while (cells.length < target) {
      _appendEmptyCell();
    }

    layout.value = newLayout;

    // 进入 focus 布局时视觉跟随既有声源（零音频扰动），
    // 避免出现「大画面无声、声音来自某个小格」的失同步。
    // 先同步后钳制：缩容可能让 _audioFocusIndex 越界，由下方钳制兜住。
    if (newLayout == MultiviewLayout.focus) {
      focusedCellIndex.value = _audioFocusIndex.value;
    }

    // 缩容后旧的大画面格可能越界，钳制到目标格数内
    // （与页面选台目标 _targetCell 的整改同一模式，防越界）。
    // 用 target 而非固定容量：focus 的格数可由 cellCount 扩到固定容量
    // 以上，此时末尾格同样是合法的大画面格，不该被钳掉。
    if (focusedCellIndex.value >= target) {
      focusedCellIndex.value = target - 1;
    }

    if (_audioFocusIndex.value >= target) {
      _refocusToFirstPlaying(fallback: 0);
    }

    // 布局变化可能改变大画面格（进入/离开 focus），同步弹幕会话。
    unawaited(_syncDanmakuSessions());
  }

  /// 从尾部裁掉一个格子，并断开其弹幕会话。
  ///
  /// 播放器句柄的释放在调用方（[setLayout] 已先批量 [_releaseSlot]）；
  /// 本方法只做与 cells 平行的各数组收尾，保持它们的长度一致。
  void _shrinkSlot() {
    _playingSubs.removeLast()?.cancel();
    playingFlags.removeLast();
    cells.removeLast();
    _players.removeLast();
    _cellEpochs.removeLast();
    // 缩容后该 slot 不再存在：断开其弹幕会话并清空残留弹幕。
    unawaited(_danmakuSessions.removeLast().disconnect());
    _barrageControllers.removeLast().clear();
  }

  /// 在尾部追加一个空格，含独立的弹幕会话与渲染入口。
  void _appendEmptyCell() {
    final index = cells.length;
    cells.add(MultiviewCellState.empty(index));
    _players.add(null);
    _cellEpochs.add(0);
    playingFlags.add(false);
    _playingSubs.add(null);
    _danmakuSessions.add(_createDanmakuSession(index));
    _barrageControllers.add(BarrageController());
  }

  /// focus 布局下追加一个空白小格（动态容量，滚动呈现由 UI 层负责）。
  ///
  /// 仅 focus 布局且未达 [maxCellCount] 时有效；否则 Fail Fast。
  Future<void> addCell() async {
    if (layout.value != MultiviewLayout.focus) {
      throw StateError('multiview: addCell is only available in focus layout');
    }
    if (!canAddCell) {
      throw StateError('multiview: cell limit reached ($maxCellCount)');
    }
    _appendEmptyCell();
  }

  /// focus 布局下把 [cellIndex] 格晋升为大画面。
  ///
  /// 交互模型（YouTube TV 聚焦式）：只切换「哪个格显示为大」，
  /// 播放器实例不迁移、不重建、不重新解析，各路播放状态完整保留；
  /// 音频焦点跟随新的大画面，即大画面成为唯一声音来源。
  ///
  /// 小格自动降质联动开启时（仅 focus 布局）：晋升格非最高档则自动换
  /// 最高档，被降格的原大画面非最低档则自动换最低档——均走同实例换流，
  /// 不重建播放器。可能触发换流故为异步；UI 层无需等待其完成。
  Future<void> promoteCell(int cellIndex) async {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    final previousFocused = focusedCellIndex.value;
    focusedCellIndex.value = cellIndex;
    await setAudioFocus(cellIndex);

    if (!smallCellsLowQuality.value || layout.value != MultiviewLayout.focus) return;

    // 晋升格：非最高档自动换最高档。
    final promoted = cells[cellIndex];
    if (_players[cellIndex] != null && promoted.qualities.isNotEmpty && promoted.qualityIndex != 0) {
      await setCellQuality(cellIndex, 0);
    }
    // 被降格的原大画面：非最低档自动换最低档。
    if (previousFocused == cellIndex || previousFocused < 0 || previousFocused >= cells.length) return;
    final demoted = cells[previousFocused];
    if (_players[previousFocused] != null &&
        demoted.qualities.isNotEmpty &&
        demoted.qualityIndex != demoted.qualities.length - 1) {
      await setCellQuality(previousFocused, demoted.qualities.length - 1);
    }
  }

  /// 向指定格分配房间并起播；成功后该格自动成为音频焦点。
  ///
  /// 若该格已被占用，先走统一释放路径再重新分配。
  /// 解析失败/起播失败置 status=error 并记录错误种类与原始详情，不吞异常。
  Future<void> assignRoom(int cellIndex, LiveRoom room) async {
    if (_closed || isClosed) return;
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    if (room.platform == null || !Sites.isSupported(room.platform!)) {
      throw ArgumentError.value(room.platform, 'room.platform', 'Unsupported live platform');
    }
    if (room.roomId == null || room.roomId!.isEmpty) {
      throw ArgumentError.value(room.roomId, 'room.roomId', 'Room id is required');
    }

    // 先推进纪元使该格任何在途解析/起播失效，再释放旧句柄。
    // 旧句柄的销毁不再推进纪元：本此分配已独占该格。
    final epoch = _advanceCellEpoch(cellIndex);
    _cancelDiscovery(cellIndex);
    final previousHandle = _players[cellIndex];
    _players[cellIndex] = null;
    if (previousHandle != null) {
      await _teardown(previousHandle);
    }
    if (_isStale(cellIndex, epoch)) return;

    _updateCell(
      cellIndex,
      cells[cellIndex].copyWith(
        room: room,
        status: MultiviewCellStatus.resolving,
        clearError: true,
        clearVideoController: true,
        // 清空旧房间的清晰度上下文：解析失败时错误态快照不得残留
        // 旧清晰度表/换档闭包，否则 UI 会展示与新房间无关的档位。
        clearQuality: true,
      ),
    );

    // A room already verified as offline is a valid picker result. Do not hit
    // playback APIs or construct a native decoder only to surface a generic
    // error card.
    if (room.isExplicitlyOfflineNow) {
      _setOfflineCell(cellIndex, epoch, room);
      return;
    }

    // 小格自动降质联动（仅 focus 布局）：向非大画面格分配时默认取最低档。
    final preferLowest =
        smallCellsLowQuality.value && layout.value == MultiviewLayout.focus && cellIndex != focusedCellIndex.value;

    final MultiviewStreamSource source;
    final scope = LiveQualityDiscoveryScope();
    _discoveryScopes[cellIndex] = scope;
    try {
      source = _streamResolver != null
          ? await _streamResolver(room, preferLowest: preferLowest)
          : await _defaultStreamResolver(room, preferLowest: preferLowest, discoveryScope: scope);
    } on MultiviewRoomOffline catch (offline) {
      _setOfflineCell(cellIndex, epoch, offline.room.fillFromDetail(room));
      return;
    } catch (error, stackTrace) {
      if (_isStale(cellIndex, epoch)) return;
      developer.log(
        'MultiviewController: resolve stream failed for ${room.platform}/${room.roomId}',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
      _failCell(cellIndex, epoch, MultiviewCellErrorKind.resolveFailure, error.toString());
      return;
    } finally {
      if (identical(_discoveryScopes[cellIndex], scope)) _discoveryScopes.remove(cellIndex);
      await scope.close();
    }
    if (_isStale(cellIndex, epoch)) return;

    final target = _resolveRenderTarget(layout.value);
    final handle = _playerFactory(renderWidth: target.width.toInt(), renderHeight: target.height.toInt());
    // Publish ownership before async start so remove/close can retire a relay
    // whose factory or native initialization is still pending.
    _players[cellIndex] = handle;

    try {
      await _openCellSource(handle, source, start: true);
    } catch (error, stackTrace) {
      developer.log(
        'MultiviewController: start playback failed for ${room.platform}/${room.roomId}',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
      if (cellIndex < _players.length && identical(_players[cellIndex], handle)) {
        _players[cellIndex] = null;
        await _teardown(handle);
      }
      _failCell(cellIndex, epoch, MultiviewCellErrorKind.startFailure, error.toString());
      return;
    }

    // Restore the same per-room volume used by the normal player before this
    // handle can receive audio focus. All multiview handles start muted, so
    // this cannot create a first-frame volume burst.
    try {
      await handle.setVolume(_roomVolumeLoader(room).clamp(0.0, 1.0));
    } catch (error, stackTrace) {
      developer.log(
        'MultiviewController: restore room volume failed',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (_isStale(cellIndex, epoch)) {
      if (cellIndex < _players.length && identical(_players[cellIndex], handle)) {
        _players[cellIndex] = null;
        await _teardown(handle);
      }
      return;
    }

    // A cell assigned while mute-all is engaged must not become the sole
    // audible exception. Establish its mute state before it can take focus.
    try {
      await handle.setMuted(_shouldMute(cellIndex));
    } catch (error, stackTrace) {
      developer.log(
        'MultiviewController: initial mute setup failed for cell $cellIndex',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
    }

    _players[cellIndex] = handle;
    _playingSubs[cellIndex]?.cancel();
    _playingSubs[cellIndex] = handle.playingStream.listen((playing) {
      if (cellIndex < _players.length && identical(_players[cellIndex], handle) && cellIndex < playingFlags.length) {
        playingFlags[cellIndex] = playing;
      }
    });
    playingFlags[cellIndex] = true;
    _updateCell(
      cellIndex,
      cells[cellIndex].copyWith(
        status: MultiviewCellStatus.playing,
        videoController: handle.videoController,
        ownedSource: source.ownedSource,
        qualities: source.qualities,
        qualityIndex: source.qualityIndex,
        qualityLoader: source.qualityLoader,
        headers: source.headers,
        lines: source.lines,
        lineIndex: source.lineIndex,
        sourceQueryPolicies: source.sourceQueryPolicies,
      ),
    );
    // focus 布局下向非大格分配房间时，新流保持静音起播、不抢声源，
    // 用户点击晋升（promoteCell）才出声；其余布局维持「新格即声源」。
    final shouldTakeAudioFocus = layout.value != MultiviewLayout.focus || cellIndex == focusedCellIndex.value;
    if (shouldTakeAudioFocus) {
      await setAudioFocus(cellIndex);
    }
    // 大画面房间可能已变化，同步弹幕会话（幂等）。
    unawaited(_syncDanmakuSessions());
  }

  Future<void> setCellMuted(int cellIndex, bool muted) async {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');

    final handle = _players[cellIndex];
    if (handle == null) {
      throw StateError('multiview: cell $cellIndex is not playing');
    }

    if (allMuted.value && !muted) {
      return;
    }

    await handle.setMuted(muted);
  }

  /// 切换指定格的清晰度：同 Player 换流，不重建播放器实例。
  ///
  /// 纪元推进防竞态——换流期间该格被重新分配时，迟到的换流结果被丢弃。
  /// URL 取回失败置 resolveFailure、open 失败置 startFailure，
  /// 均按 [_failCell] 既有模式呈现。
  Future<void> setCellQuality(int cellIndex, int qualityIndex) async {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    final state = cells[cellIndex];
    if (state.qualities.isEmpty) {
      throw StateError('multiview: cell $cellIndex has no quality list');
    }
    if (qualityIndex < 0 || qualityIndex >= state.qualities.length) {
      throw RangeError.range(qualityIndex, 0, state.qualities.length - 1, 'qualityIndex');
    }
    final loader = state.qualityLoader;
    if (loader == null) {
      throw StateError('multiview: cell $cellIndex has no quality loader');
    }
    if (qualityIndex == state.qualityIndex) return;
    final handle = _players[cellIndex];
    if (handle == null) {
      throw StateError('multiview: cell $cellIndex is not playing');
    }

    final epoch = _advanceCellEpoch(cellIndex);
    final MultiviewStreamSource next;
    try {
      next = await loader(state.qualities[qualityIndex]);
    } catch (error, stackTrace) {
      developer.log(
        'MultiviewController: quality url resolve failed for cell $cellIndex',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
      _failCell(cellIndex, epoch, MultiviewCellErrorKind.resolveFailure, error.toString());
      return;
    }
    if (_isStale(cellIndex, epoch)) return;

    // 换清晰度尽量保持当前线路：新档位线路数不足时回退首线路；
    // 加载器未提供线路列表时维持原状（兼容假实现/旧解析器）。
    final hasLines = next.lines.isNotEmpty;
    final owned = next.ownedSource != null;
    final resetLines = owned || state.ownedSource != null;
    final keepLine = owned
        ? 0
        : hasLines
        ? (state.lineIndex < next.lines.length ? state.lineIndex : 0)
        : resetLines
        ? 0
        : state.lineIndex;
    final openUrl = hasLines ? next.lines[keepLine] : next.url;

    try {
      await _openCellSource(handle, next, start: false, url: openUrl);
    } catch (error, stackTrace) {
      developer.log(
        'MultiviewController: quality switch open failed for cell $cellIndex',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
      _failCell(cellIndex, epoch, MultiviewCellErrorKind.startFailure, error.toString());
      return;
    }
    if (_isStale(cellIndex, epoch)) return;

    _updateCell(
      cellIndex,
      cells[cellIndex].copyWith(
        ownedSource: next.ownedSource,
        clearOwnedSource: !owned,
        qualities: next.qualities.isEmpty ? null : next.qualities,
        qualityIndex: next.qualities.isEmpty ? qualityIndex : next.qualityIndex,
        headers: next.headers,
        sourceQueryPolicies: next.sourceQueryPolicies,
        lines: hasLines
            ? next.lines
            : resetLines
            ? const []
            : null,
        lineIndex: hasLines || resetLines ? keepLine : null,
      ),
    );
  }

  /// 切换指定格的线路：同 Player 换流，不重建播放器实例。
  ///
  /// 线路列表来自解析阶段 getPlayUrls 的完整返回；换清晰度时线路下标
  /// 尽量保持（见 [setCellQuality] 的线路保持逻辑）。
  Future<void> setCellLine(int cellIndex, int lineIndex) async {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    final state = cells[cellIndex];
    if (state.status != MultiviewCellStatus.playing) {
      throw StateError('multiview: cell $cellIndex is not playing');
    }
    if (state.lines.isEmpty) {
      throw StateError('multiview: cell $cellIndex has no line list');
    }
    if (lineIndex < 0 || lineIndex >= state.lines.length) {
      throw RangeError.range(lineIndex, 0, state.lines.length - 1, 'lineIndex');
    }
    if (lineIndex == state.lineIndex) return;
    final handle = _players[cellIndex];
    if (handle == null) {
      throw StateError('multiview: cell $cellIndex is not playing');
    }

    final epoch = _advanceCellEpoch(cellIndex);
    try {
      await handle.open(
        url: state.lines[lineIndex],
        headers: state.headers,
        sourceQueryPolicy: state.sourceQueryPolicies[state.lines[lineIndex]],
      );
    } catch (error, stackTrace) {
      developer.log(
        'MultiviewController: line switch open failed for cell $cellIndex',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
      _failCell(cellIndex, epoch, MultiviewCellErrorKind.startFailure, error.toString());
      return;
    }
    if (_isStale(cellIndex, epoch)) return;

    _updateCell(cellIndex, cells[cellIndex].copyWith(lineIndex: lineIndex));
  }

  /// 临时暂停/恢复指定格（不触发释放流程，格状态保持 playing）。
  Future<void> toggleCellPlayPause(int cellIndex) async {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    if (cells[cellIndex].status != MultiviewCellStatus.playing) {
      throw StateError('multiview: cell $cellIndex is not playing');
    }
    final handle = _players[cellIndex];
    if (handle == null) {
      throw StateError('multiview: cell $cellIndex is not playing');
    }
    if (cellIndex >= playingFlags.length) {
      throw StateError('multiview: playing flag missing for cell $cellIndex');
    }
    final epoch = _cellEpochs[cellIndex];
    bool current() => !_isStale(cellIndex, epoch) && identical(_players[cellIndex], handle);
    try {
      if (handle.isPlaying) {
        await handle.pause();
      } else {
        // A closed owned session may require fresh network acquisition here.
        await handle.resume();
      }
      if (current()) playingFlags[cellIndex] = handle.isPlaying;
    } catch (error, stackTrace) {
      if (!current()) return;
      developer.log(
        'Multiview playback intent failed',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
      playingFlags[cellIndex] = handle.isPlaying;
      _failCell(cellIndex, epoch, MultiviewCellErrorKind.startFailure, error.toString());
    }
  }

  /// 设置指定格的音量（0.0-1.0）并写入普通播放器共用的房间音量存储。
  /// 静音状态独立于音量值。
  Future<void> setCellVolume(int cellIndex, double volume) async {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    if (cells[cellIndex].status != MultiviewCellStatus.playing) {
      throw StateError('multiview: cell $cellIndex is not playing');
    }
    final handle = _players[cellIndex];
    if (handle == null) {
      throw StateError('multiview: cell $cellIndex is not playing');
    }
    final resolved = volume.clamp(0.0, 1.0).toDouble();
    await handle.setVolume(resolved);
    final room = cells[cellIndex].room;
    if (room == null) return;
    try {
      await _roomVolumeSaver(room, resolved);
    } catch (error, stackTrace) {
      // A damaged preference store must not turn a working volume adjustment
      // into a playback failure. The active player has already applied it.
      developer.log(
        'MultiviewController: persist room volume failed',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 读取指定格的会话音量当前值（供 UI 音量控件初始化）；未起播返回 1.0。
  double cellVolume(int cellIndex) {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    return _players[cellIndex]?.volume ?? 1.0;
  }

  /// 把当前画面抓成一份场景快照（不落盘，持久化由预设控制器负责）。
  ///
  /// 只记录可恢复的部分：布局、大画面格、各格房间与音量、两个开关。
  /// 解析中或失败的格子同样按其 room 记录——房间身份与当下成败无关。
  MultiviewPreset createPreset(String name) {
    final snapshotCells = <MultiviewPresetCell?>[];
    for (var index = 0; index < cells.length; index++) {
      final room = cells[index].room;
      snapshotCells.add(room == null ? null : MultiviewPresetCell(room: room, volume: cellVolume(index)));
    }

    return MultiviewPreset(
      id: MultiviewPreset.newId(),
      name: name,
      layout: layout.value,
      focusedCellIndex: focusedCellIndex.value,
      cells: snapshotCells,
      smallCellsLowQuality: smallCellsLowQuality.value,
      danmakuEnabled: danmakuEnabled.value,
    );
  }

  /// 应用场景预设。
  ///
  /// 步骤顺序有讲究：降质开关与大画面格必须先于换房落定，因为 [assignRoom]
  /// 正是按 `smallCellsLowQuality` + `focusedCellIndex` 决定小格取不取最低档。
  /// 已播放同一房间的格子跳过（[assignRoom] 是无条件重建），否则每按一次
  /// 预设都会把整屏重新拉流。音量则相反，必须晚于换房，见下方说明。
  Future<void> applyPreset(MultiviewPreset preset) async {
    if (_closed || isClosed || _applyingPreset) return;
    _applyingPreset = true;
    try {
      await setLayout(preset.layout, cellCount: preset.cellCount);
      if (_closed || isClosed) return;

      final limit = preset.cellCount < cells.length ? preset.cellCount : cells.length;

      // 空位先清掉：removeCell 会重定位大画面格，先清可免去事后再纠正一次。
      for (var index = 0; index < limit; index++) {
        if (preset.cells[index] == null) removeCell(index);
      }

      smallCellsLowQuality.value = preset.smallCellsLowQuality;
      danmakuEnabled.value = preset.danmakuEnabled;
      if (preset.layout == MultiviewLayout.focus) {
        focusedCellIndex.value = preset.focusedCellIndex.clamp(0, cells.length - 1);
      }

      // 换房：各格并发解析（彼此不共享状态），总耗时取决于最慢的一格。
      final pending = <Future<void>>[];
      for (var index = 0; index < limit; index++) {
        final wanted = preset.cells[index];
        if (wanted == null) continue;
        // 站点已不被支持：该位留作空格，不让一格失败中断整次恢复。
        if (!Sites.isSupported(wanted.room.platform ?? '')) continue;
        if (cells[index].room?.hasSameIdentity(wanted.room) == true) continue;
        pending.add(assignRoom(index, wanted.room));
      }
      if (pending.isNotEmpty) {
        try {
          await Future.wait(pending);
        } catch (error, stackTrace) {
          developer.log(
            'MultiviewController: some preset cells failed to start',
            name: 'MultiviewController',
            error: error,
            stackTrace: stackTrace,
          );
        }
        if (_closed || isClosed) return;
      }

      // 音量必须晚于换房：assignRoom 会重建播放器（默认音量、静音起播），
      // 先写会被新实例覆盖。且只写已起播的格——未起播的格没有播放器，
      // setCellVolume 会直接抛。
      for (var index = 0; index < limit; index++) {
        final wanted = preset.cells[index];
        if (wanted == null || cells[index].status != MultiviewCellStatus.playing) continue;
        try {
          await setCellVolume(index, wanted.volume);
        } catch (error, stackTrace) {
          developer.log(
            'MultiviewController: restoring preset volume failed for cell $index',
            name: 'MultiviewController',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      if (_closed || isClosed) return;

      // 恢复声音来源：focus 跟随大画面格（与 promoteCell 的约定一致），
      // 其余布局落在第一个有房间的格——非逐格模式下这才决定谁出声。
      final focusTarget = preset.layout == MultiviewLayout.focus ? preset.focusedCellIndex : preset.firstFilledIndex;
      if (focusTarget >= 0 && focusTarget < cells.length && cells[focusTarget].room != null) {
        await setAudioFocus(focusTarget);
      }
    } finally {
      _applyingPreset = false;
    }
  }

  /// 释放指定格并回到 empty。
  ///
  /// 契约为同步签名：状态立即回到 empty，原生释放按同一条路径在后台完成。
  void removeCell(int cellIndex) {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    final handle = _captureSlot(cellIndex);
    if (_audioFocusIndex.value == cellIndex) {
      _refocusToFirstPlaying(fallback: cellIndex);
    }
    // 关闭大画面格后显示焦点不能空置：转移到第一个播放中的格，无播放格归 0
    // （与音频焦点的重定位语义对齐）。
    if (focusedCellIndex.value == cellIndex) {
      focusedCellIndex.value = _findPlayingCell() ?? 0;
    }
    if (handle != null) {
      unawaited(_teardown(handle));
    }
    // 大画面格可能被关闭或焦点转移，同步弹幕会话（幂等）。
    unawaited(_syncDanmakuSessions());
  }

  /// 切换音频焦点：仅目标格出声，其余全部静音。
  Future<void> setAudioFocus(int cellIndex) {
    RangeError.checkValidIndex(cellIndex, cells, 'cellIndex');
    _audioFocusIndex.value = cellIndex;
    return _audioFocusTransitions.submit(cellIndex).catchError((Object error, StackTrace stackTrace) {
      developer.log(
        'MultiviewController: audio focus transition failed',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
    });
  }

  Future<void> _applyAudioFocus(int targetIndex) async {
    // Mute every non-target handle, not just the previously remembered one:
    // this also repairs any inconsistent state left by a native call failure.
    for (var index = 0; index < _players.length; index++) {
      final handle = _players[index];
      if (handle == null) continue;

      final muted = _shouldMute(index);

      try {
        await handle.setMuted(muted);
      } catch (error, stackTrace) {
        developer.log(
          'MultiviewController: failed to update mute for cell $index',
          name: 'MultiviewController',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // A newer tap arrived while native mute calls were in flight. The queue
    // will apply that pending target next, so never unmute this stale target.
    if (_audioFocusIndex.value != targetIndex || targetIndex >= _players.length) return;

    final target = _players[targetIndex];
    if (target != null) {
      await target.setMuted(allMuted.value);
    }
  }

  /// 释放全部格子（页面 onClose 调用），cells 全部回到 empty。
  ///
  /// 状态清理同步前置：pop 动画期间 Video widget 可能仍在树中监听渲染
  /// notifier，必须先摘除全部渲染引用再开始原生销毁；句柄随后在后台
  /// 串行 teardown，onClose 场景不阻塞路由 pop。
  Future<void> disposeAll() async {
    final handles = <MultiviewCellPlayerHandle>[];
    for (var i = 0; i < _players.length; i++) {
      final handle = _captureSlot(i);
      if (handle != null) {
        handles.add(handle);
      }
    }
    _audioFocusIndex.value = 0;
    focusedCellIndex.value = 0;

    // 弹幕会话先行断开：网络栈清理与播放器销毁互不依赖。
    for (final session in _danmakuSessions) {
      unawaited(session.disconnect());
    }
    for (final barrage in _barrageControllers) {
      barrage.clear();
    }

    for (final handle in handles) {
      try {
        await _teardown(handle);
      } catch (error, stackTrace) {
        // 单个句柄销毁失败不得中断循环，否则后续句柄泄漏；
        // 记录后继续处理剩余句柄。
        developer.log(
          'MultiviewController: cell teardown failed during disposeAll',
          name: 'MultiviewController',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    // Slots removed earlier may still own a creating seat or draining input.
    // Joining them is part of page teardown, even though their UI is empty.
    await Future.wait([for (final pending in _retiringPlayers.values.toList()) pending.catchError((Object _) {})]);
    await Future.wait(_retiringDiscoveries.toList());
  }

  @override
  void onClose() {
    _closed = true;
    for (final worker in _rxWorkers) {
      worker.dispose();
    }
    _rxWorkers.clear();
    unawaited(disposeAll());
    super.onClose();
  }

  bool _isStale(int cellIndex, int epoch) =>
      _closed || isClosed || cellIndex >= _cellEpochs.length || _cellEpochs[cellIndex] != epoch;

  /// 记录失败种类与原始错误文本；展示文案由 UI 按语言映射，核心层不拼自然语言。
  void _failCell(int cellIndex, int epoch, MultiviewCellErrorKind kind, String detail) {
    if (_isStale(cellIndex, epoch)) return;
    _updateCell(
      cellIndex,
      cells[cellIndex].copyWith(status: MultiviewCellStatus.error, errorKind: kind, errorDetail: detail),
    );
    // 大画面解析/起播失败时其房间状态已不可用，同步弹幕会话
    // （幂等入口：健康同键会话保持，失效则按当前大画面房间按需重连）。
    if (cellIndex == _selectedCellIndex) {
      unawaited(_syncDanmakuSessions());
    }
  }

  void _setOfflineCell(int cellIndex, int epoch, LiveRoom room) {
    if (_isStale(cellIndex, epoch)) return;
    playingFlags[cellIndex] = false;
    _updateCell(
      cellIndex,
      cells[cellIndex].copyWith(
        room: room,
        status: MultiviewCellStatus.offline,
        clearError: true,
        clearVideoController: true,
        clearQuality: true,
      ),
    );
    unawaited(_syncDanmakuSessions());
  }

  /// 统一释放路径：捕获句柄置空 → pause → 销毁播放内核
  /// （渲染控制器原生清理随 player.dispose 的 release 钩子完成）。
  Future<void> _releaseSlot(int cellIndex) async {
    final handle = _captureSlot(cellIndex);
    if (handle != null) await _teardown(handle);
    await Future.wait(_retiringDiscoveries.toList());
  }

  /// 同步捕获并清空一格：句柄置空、纪元推进、状态回到 empty。
  MultiviewCellPlayerHandle? _captureSlot(int cellIndex) {
    final handle = _players[cellIndex];
    _players[cellIndex] = null;
    _advanceCellEpoch(cellIndex);
    _cancelDiscovery(cellIndex);
    _playingSubs[cellIndex]?.cancel();
    _playingSubs[cellIndex] = null;
    if (cellIndex < playingFlags.length) {
      playingFlags[cellIndex] = false;
    }
    // 该格已无房间：断开其弹幕会话并清空渲染残留，避免换房后旧弹幕串场。
    if (cellIndex < _danmakuSessions.length) {
      unawaited(_danmakuSessions[cellIndex].disconnect());
      _barrageControllers[cellIndex].clear();
    }
    _updateCell(cellIndex, MultiviewCellState.empty(cellIndex));
    return handle;
  }

  final Map<MultiviewCellPlayerHandle, Future<void>> _retiringPlayers = Map.identity();

  Future<void> _teardown(MultiviewCellPlayerHandle handle) => _retiringPlayers.putIfAbsent(handle, () {
    Future<void> retire() async {
      try {
        await handle.pause();
      } finally {
        await handle.disposePlayer();
      }
    }

    final work = retire().whenComplete(() {
      _retiringPlayers.remove(handle);
    });
    // removeCell is synchronous. Observe failures from its background cleanup
    // without concealing them from a caller that explicitly awaits teardown.
    unawaited(
      work.catchError((Object error, StackTrace stack) {
        developer.log('Multiview cell cleanup failed', name: 'MultiviewController', error: error, stackTrace: stack);
      }),
    );
    return work;
  });

  /// 第一个播放中的格下标；没有则返回 null。
  int? _findPlayingCell() {
    for (var i = 0; i < cells.length; i++) {
      if (cells[i].status == MultiviewCellStatus.playing && _players[i] != null) {
        return i;
      }
    }
    return null;
  }

  /// 焦点格失效后转移到第一个播放中的格；没有则落到 [fallback]。
  void _refocusToFirstPlaying({required int fallback}) {
    final target = _findPlayingCell();
    if (target != null) {
      setAudioFocus(target);
    } else {
      _audioFocusIndex.value = fallback;
    }
  }

  void _updateCell(int cellIndex, MultiviewCellState state) {
    cells[cellIndex] = state;
  }

  /// 按当前布局把屏幕物理像素均分，得到播放器创建时的初始渲染分辨率。
  Size _resolveRenderTarget(MultiviewLayout l) {
    final screen = _probeScreenMetrics();
    // ponytail: 无窗口树（纯 Dart 测试/极早期调用）退回 720p 基线，
    // 保证分辨率计算可确定性验证。
    final width = ((screen.logical.width * screen.dpr) / l.columns).round().clamp(320, 3840);
    final height = ((screen.logical.height * screen.dpr) / l.rows).round().clamp(180, 2160);
    return Size(width.toDouble(), height.toDouble());
  }

  /// 探测当前窗口的逻辑尺寸与像素密度。
  ///
  /// GetX 的 Get.context 在根路由未挂载时抛出而非返回 null（vendored 实现），
  /// 该场景只出现在无窗口树的纯 Dart 测试或极早期调用，属预期环境状态，
  /// 记录后退回 720p 基线，不视为错误。
  ({Size logical, double dpr}) _probeScreenMetrics() {
    try {
      final context = Get.context;
      if (context == null) {
        return (logical: const Size(1280, 720), dpr: 1.0);
      }
      return (logical: MediaQuery.sizeOf(context), dpr: MediaQuery.devicePixelRatioOf(context));
    } catch (error, stackTrace) {
      developer.log(
        'MultiviewController: window tree unavailable, using baseline render metrics',
        name: 'MultiviewController',
        error: error,
        stackTrace: stackTrace,
      );
      return (logical: const Size(1280, 720), dpr: 1.0);
    }
  }
}

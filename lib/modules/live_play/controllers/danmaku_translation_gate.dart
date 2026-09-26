// 注入的翻译与投放回调保持私有字段，同时对外使用公开的命名参数；命名参数
// 不能以下划线开头，所以初始化列表是这里的唯一写法。
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import 'package:pure_live/common/models/live_message.dart';

/// 把一条已经完成翻译尝试的弹幕交给渲染层。
typedef DanmakuDelivery = void Function(LiveMessage message);

/// 把一批文本送去翻译，并返回等长结果（失败位置为 null）。
typedef DanmakuTranslateBatch = Future<List<String?>> Function(List<String> texts);

/// 弹幕投放前的翻译闸门。
///
/// 翻译是异步的，而弹幕是流式的：直接用 `await` 逐条等待会让延迟随条数累加，
/// 完全不等待又会让飘屏弹幕永远显示原文。这里用"窗口聚合 + 整批一次请求 +
/// 超时降级"解决这个矛盾：
///
/// - 一个窗口内的消息合并成一次翻译请求，延迟是常量而不是累加；
/// - 一批的结果回来后**按原顺序**投放，弹幕次序不会错乱；
/// - 翻译超时或失败时整批按原文投放，链路永远不会被翻译卡住。
class DanmakuTranslationGate {
  DanmakuTranslationGate({
    required DanmakuTranslateBatch translate,
    required DanmakuDelivery deliver,
    this.window = const Duration(milliseconds: 200),
    this.timeout = const Duration(milliseconds: 800),
    this.maxBatchSize = 40,
    this.maxQueueLength = 300,
  }) : _translate = translate,
       _deliver = deliver;

  /// 收集消息的时长。太短起不到合并作用，太长会让弹幕整体变迟钝。
  final Duration window;

  /// 单批翻译的等待上限。超过它就先投放原文，译文随后只影响列表行。
  final Duration timeout;

  /// 单批最多合并多少条，避免一个窗口内的爆发把请求撑爆。
  final int maxBatchSize;

  /// 等待队列上限。超出后最旧的消息直接按原文投放，保证延迟有界。
  final int maxQueueLength;

  final DanmakuTranslateBatch _translate;
  final DanmakuDelivery _deliver;

  final List<LiveMessage> _queue = <LiveMessage>[];

  Timer? _timer;
  bool _busy = false;

  /// 房间切换时会丢弃在途批次，防止上一个房间的弹幕投放到新房间。
  int _generation = 0;

  /// 当前等待投放的消息条数，供测试与诊断使用。
  int get pendingCount => _queue.length;

  /// 提交一条待投放的消息。
  void submit(LiveMessage message) {
    _queue.add(message);
    while (_queue.length > maxQueueLength) {
      // 队列溢出说明翻译明显慢于弹幕速度，此时保住实时性比保住译文优先。
      _deliver(_queue.removeAt(0));
    }
    _timer ??= Timer(window, () => unawaited(_drain()));
  }

  /// 立即结算当前队列。房间关闭或停止弹幕时调用，避免残留消息在之后才出现。
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    return _drain();
  }

  /// 丢弃尚未投放的消息，并作废在途批次。房间切换时使用。
  void clear() {
    _generation++;
    _queue.clear();
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _drain() async {
    // 进入 drain 就说明这个窗口已经到期（或被 flush、被后续排程接手），指针必须
    // 立刻清空。否则下面所有 `_timer ??=` 都会被这个已经失效的 Timer 短路，
    // 再也排不出下一次结算——表现出来就是"开场几秒有几条弹幕，之后彻底安静"：
    // 第一波照常投放，队列随后只进不出，直到房间关闭。
    _timer = null;
    if (_busy) {
      // 上一批还在翻译：让新到的消息继续累积，本批结束后再排一次。
      _timer ??= Timer(window, () => unawaited(_drain()));
      return;
    }
    if (_queue.isEmpty) return;

    final generation = _generation;
    _busy = true;
    final take = _queue.length < maxBatchSize ? _queue.length : maxBatchSize;
    final batch = List<LiveMessage>.of(_queue.take(take), growable: false);
    _queue.removeRange(0, take);

    try {
      final texts = batch.map((message) => message.message).toList(growable: false);
      // 注入进来的实现，运行时返回类型可能比 List<String?> 更窄：一个总是抛
      // 异常的翻译器会被推断成 Future<Never>。在更窄的 future 上直接调用
      // timeout，它的 onTimeout 参数会在运行时协变检查中失败，源 future 的
      // 错误也会因此失去监听者，变成未处理的异步异常。先归一到完整类型，
      // 再套超时——这样任何满足契约的实现都不会把错误漏到 zone 外面。
      final normalized = _translate(texts).then<List<String?>>(
        (value) => value,
        onError: (Object _, StackTrace _) => <String?>[],
      );
      await normalized.timeout(timeout, onTimeout: () => List<String?>.filled(texts.length, null));
    } catch (_) {
      // 翻译失败不是投放失败：下面仍然按原文投放整批。
    } finally {
      _busy = false;
      if (generation == _generation) {
        for (final message in batch) {
          _deliver(message);
        }
      }
      if (_queue.isNotEmpty) {
        _timer ??= Timer(window, () => unawaited(_drain()));
      }
    }
  }
}

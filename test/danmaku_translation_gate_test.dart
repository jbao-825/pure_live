import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/common/models/live_message.dart';
import 'package:pure_live/modules/live_play/controllers/danmaku_translation_gate.dart';

LiveMessage _message(String text) => LiveMessage(
  type: LiveMessageType.chat,
  userName: 'viewer',
  message: text,
  color: LiveMessageColor.white,
);

void main() {
  group('DanmakuTranslationGate', () {
    test('translates one window as a single batch and delivers it in arrival order', () async {
      final batches = <List<String>>[];
      final delivered = <String>[];
      final gate = DanmakuTranslationGate(
        translate: (texts) async {
          batches.add(texts);
          return texts.map((text) => '译:$text').toList();
        },
        deliver: (message) => delivered.add(message.message),
        window: const Duration(milliseconds: 5),
      );

      gate.submit(_message('one'));
      gate.submit(_message('two'));
      gate.submit(_message('three'));
      await gate.flush();

      expect(batches, [
        ['one', 'two', 'three'],
      ]);
      expect(delivered, ['one', 'two', 'three']);
    });

    test('keeps delivering across successive windows without an explicit flush', () async {
      // 这条走的是生产路径：完全依赖窗口计时器自己到期，不调用 flush。
      // flush() 会自己清掉 _timer，所以只要测试用了它，就永远发现不了
      // "计时器触发后指针没清空" 导致的下一次排程失败。
      final delivered = <String>[];
      final gate = DanmakuTranslationGate(
        translate: (texts) async => texts.map((text) => 'T:$text').toList(),
        deliver: (message) => delivered.add(message.message),
        window: const Duration(milliseconds: 10),
      );

      gate.submit(_message('a1'));
      gate.submit(_message('a2'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(delivered, ['a1', 'a2']);

      // 第二波：残留的旧计时器一旦让 _timer ??= 短路，这里就再也排不出结算，
      // 弹幕会在第一批之后永久停住。
      gate.submit(_message('b1'));
      gate.submit(_message('b2'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(delivered, ['a1', 'a2', 'b1', 'b2']);

      // 第三波再确认一次，排除"恰好只差一轮"的巧合。
      gate.submit(_message('c1'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(delivered, ['a1', 'a2', 'b1', 'b2', 'c1']);
    });

    test('still delivers every message when translation itself fails', () async {
      final delivered = <String>[];
      final gate = DanmakuTranslationGate(
        translate: (texts) async => throw StateError('translation down'),
        deliver: (message) => delivered.add(message.message),
        window: const Duration(milliseconds: 5),
      );

      gate.submit(_message('one'));
      gate.submit(_message('two'));
      await gate.flush();

      expect(delivered, ['one', 'two']);
    });

    test('falls back to original text once the batch exceeds its timeout', () async {
      final delivered = <String>[];
      final never = Completer<List<String?>>();
      final gate = DanmakuTranslationGate(
        translate: (texts) => never.future,
        deliver: (message) => delivered.add(message.message),
        window: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 20),
      );

      gate.submit(_message('one'));
      await gate.flush();

      expect(delivered, ['one']);
    });

    test('drops an in-flight batch when the room changes', () async {
      final delivered = <String>[];
      final pending = Completer<List<String?>>();
      final gate = DanmakuTranslationGate(
        translate: (texts) => pending.future,
        deliver: (message) => delivered.add(message.message),
        window: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 30),
      );

      gate.submit(_message('one'));
      // 让窗口到期，使这一批进入"等翻译"的状态，然后模拟切房间。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.clear();
      pending.complete([null]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(delivered, isEmpty);
    });

    test('keeps latency bounded by delivering the oldest queued entries as original text', () async {
      final delivered = <String>[];
      final pending = Completer<List<String?>>();
      final gate = DanmakuTranslationGate(
        translate: (texts) => pending.future,
        deliver: (message) => delivered.add(message.message),
        window: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 30),
        maxBatchSize: 2,
        maxQueueLength: 3,
      );

      gate.submit(_message('m0'));
      gate.submit(_message('m1'));
      // 这两条被取走并在等待翻译，后续消息因此只能在队列里累积。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.submit(_message('m2'));
      gate.submit(_message('m3'));
      gate.submit(_message('m4'));
      gate.submit(_message('m5'));

      // 溢出时先投放最旧的，保证实时性而不是无限等待译文。
      expect(delivered, ['m2']);

      pending.complete([null, null]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(delivered.first, 'm2');
      expect(delivered.skip(1).take(2), ['m0', 'm1']);
    });
  });
}

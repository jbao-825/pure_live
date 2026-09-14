import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/common/services/settings/volume_settings_controller.dart';
import 'package:pure_live/player/core/desktop_volume_policy.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/video_controller.dart';
import 'package:pure_live/modules/live_play/widgets/video_player/volume_control.dart';

/// One wheel notch as the volume card computes it, on a 1080p window.
const double _wheelNotch = 53 / (1080 / 2) * 0.25;

class _FakeController implements VideoController {
  _FakeController(double value) : currentVolume = value.obs;

  @override
  final RxDouble currentVolume;

  @override
  final DesktopVolumeBoostGate desktopVolumeGate = DesktopVolumeBoostGate();

  final writes = <double>[];

  @override
  Future<double?> volume() async => currentVolume.value;

  @override
  Future<void> setVolume(double value) async {
    writes.add(value);
    currentVolume.value = value;
  }

  @override
  DesktopVolumeRequest requestDesktopVolume({required bool startsNewAdjustment, required double target}) =>
      desktopVolumeGate.request(startsNewAdjustment: startsNewAdjustment, target: target);

  @override
  void stopHideController() {}

  @override
  void enableController() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Settings extends SettingsService {
  @override
  final vol = _VolumeSettings();
  @override
  // In-memory fixture; no app services or persistent storage.
  // ignore: must_call_super
  void onInit() {}
}

class _VolumeSettings implements VolumeSettingsController {
  @override
  final defaultMobileVolume = 0.5.obs;
  @override
  final defaultDesktopVolume = 0.9.obs;
  @override
  final globalVolumeMute = false.obs;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _mount(WidgetTester tester, _FakeController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: OverlayVolumeControl(controller: controller))),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the hover bar and performs one complete upward drag gesture.
///
/// One drag gesture is one gate adjustment: releasing and dragging again is what
/// lets the user confirm and enter the boosted range.
Future<void> _dragUp(WidgetTester tester, TestGesture mouse, double distance) async {
  final track = find.byKey(const ValueKey('volume-bar-track'));
  expect(track, findsOneWidget);
  final center = tester.getCenter(track);
  await mouse.moveTo(center);
  await tester.pump();
  await mouse.down(center);
  await tester.pump();
  await mouse.moveBy(Offset(0, -distance));
  await tester.pump();
  await mouse.up();
  // Re-enter the bar so its hover timer cannot hide it during the assertions.
  await mouse.moveTo(tester.getCenter(track));
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, TestGesture mouse) async {
  await mouse.removePointer();
  // Let the risk notice expire so no timer outlives the test.
  await tester.pump(const Duration(seconds: 6));
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void main() {
  group('DesktopVolumeBoostGate', () {
    test('first approach to 100% warns and holds the safe cap', () {
      final gate = DesktopVolumeBoostGate();
      final request = gate.request(startsNewAdjustment: true, target: 1.2);

      expect(request.applied, DesktopVolumePolicy.safeVolume);
      expect(request.riskPrompt, isTrue);
      expect(gate.isBoostUnlocked, isFalse);
      expect(gate.isAwaitingConfirmation, isTrue);
    });

    test('the same adjustment cannot exceed the cap while the user keeps scrolling', () {
      final gate = DesktopVolumeBoostGate();
      // The roll reaches the cap...
      gate.request(startsNewAdjustment: true, target: 1.0);

      // ...and keeps going. Its later notches are still the same adjustment, so
      // they cannot spend the confirmation their own roll just armed.
      final again = gate.request(startsNewAdjustment: false, target: 1.4);

      expect(again.applied, DesktopVolumePolicy.safeVolume);
      expect(again.riskPrompt, isFalse);
      expect(gate.isBoostUnlocked, isFalse);
    });

    test('the next adjustment enters 100%-150% and unlocks the session', () {
      final gate = DesktopVolumeBoostGate();
      gate.request(startsNewAdjustment: true, target: 1.0);

      final boost = gate.request(startsNewAdjustment: true, target: 1.3);

      expect(boost.applied, 1.3);
      expect(boost.riskPrompt, isFalse);
      expect(gate.isBoostUnlocked, isTrue);

      // Once confirmed, the whole 100%-150% range stays reachable for the room.
      expect(gate.request(startsNewAdjustment: true, target: 1.5).applied, 1.5);
      expect(gate.request(startsNewAdjustment: true, target: 0.6).applied, 0.6);
    });

    test('a confirming adjustment stays permitted across all of its notches', () {
      final gate = DesktopVolumeBoostGate();
      expect(gate.request(startsNewAdjustment: true, target: 1.0).applied, DesktopVolumePolicy.safeVolume);

      // The first notch of the confirming roll is only ~2.45%, so it still
      // rounds onto 100%. It must not consume the permission: the second notch,
      // which is the one that actually crosses, runs inside the same adjustment.
      var accumulated = 1.0 + _wheelNotch;
      final opening = gate.request(startsNewAdjustment: true, target: accumulated);
      expect(opening.applied, DesktopVolumePolicy.safeVolume);
      expect(gate.isBoostUnlocked, isFalse);

      accumulated += _wheelNotch;
      final crossing = gate.request(startsNewAdjustment: false, target: accumulated);

      expect(crossing.applied, greaterThan(DesktopVolumePolicy.safeVolume));
      expect(gate.isBoostUnlocked, isTrue);
    });

    test('a warned session that never exceeded asks again after dropping below 100%', () {
      final gate = DesktopVolumeBoostGate();
      gate.request(startsNewAdjustment: true, target: 1.0);

      // The user leaves the cap without ever entering the boosted range.
      gate.request(startsNewAdjustment: true, target: 0.8);
      expect(gate.isAwaitingConfirmation, isFalse);

      final returning = gate.request(startsNewAdjustment: true, target: 1.0);

      expect(returning.applied, DesktopVolumePolicy.safeVolume);
      expect(returning.riskPrompt, isTrue);
      expect(gate.isBoostUnlocked, isFalse);
    });

    test('resetSession re-arms the prompt for a new room', () {
      final gate = DesktopVolumeBoostGate();
      gate.request(startsNewAdjustment: true, target: 1.0);
      gate.request(startsNewAdjustment: true, target: 1.2);
      expect(gate.isBoostUnlocked, isTrue);

      gate.resetSession();
      final next = gate.request(startsNewAdjustment: true, target: 1.2);

      expect(gate.isBoostUnlocked, isFalse);
      expect(next.applied, DesktopVolumePolicy.safeVolume);
      expect(next.riskPrompt, isTrue);
    });

    test('the gate flags exactly the requests it holds at the cap', () {
      final gate = DesktopVolumeBoostGate();

      final warned = gate.request(startsNewAdjustment: true, target: 1.2);
      expect(warned.applied, DesktopVolumePolicy.safeVolume);
      expect(warned.heldAtCap, isTrue);

      // A permitted adjustment is not held, even though its single notch still
      // rounds onto the cap. It must not be flagged, or the control would park
      // its accumulator and never reach the boosted range.
      final permitted = gate.request(startsNewAdjustment: true, target: 1.02);
      expect(permitted.applied, DesktopVolumePolicy.safeVolume);
      expect(permitted.heldAtCap, isFalse);

      // Confirming the boost, and anything after it, is never held.
      final boost = gate.request(startsNewAdjustment: true, target: 1.3);
      expect(boost.applied, 1.3);
      expect(boost.heldAtCap, isFalse);
      expect(gate.request(startsNewAdjustment: false, target: 1.45).heldAtCap, isFalse);

      // Dropping below the cap applies directly and is never held.
      expect(gate.request(startsNewAdjustment: false, target: 0.6).heldAtCap, isFalse);
    });

    test('reaching the cap exactly is applied, not held', () {
      final gate = DesktopVolumeBoostGate();

      final approach = gate.request(startsNewAdjustment: true, target: 1.0);

      expect(approach.applied, DesktopVolumePolicy.safeVolume);
      expect(approach.heldAtCap, isFalse);
      expect(approach.riskPrompt, isTrue);
    });

    test('quantize snaps to the 5% grid and clamps to 0-150%', () {
      expect(DesktopVolumePolicy.quantize(1.02), DesktopVolumePolicy.safeVolume);
      expect(DesktopVolumePolicy.quantize(1.03), 1.05);
      expect(DesktopVolumePolicy.quantize(9.0), DesktopVolumePolicy.maxVolume);
      expect(DesktopVolumePolicy.quantize(-3), 0.0);
      expect(DesktopVolumePolicy.quantize(double.nan), DesktopVolumePolicy.safeVolume);
    });

    test('the persisted clamp never keeps a boosted value', () {
      expect(DesktopVolumePolicy.clampPersisted(1.5), DesktopVolumePolicy.safeVolume);
      expect(DesktopVolumePolicy.clampPersisted(0.7), 0.7);
      expect(DesktopVolumePolicy.clampPersisted(double.infinity), DesktopVolumePolicy.safeVolume);
    });
  });

  group('OverlayVolumeControl desktop boost', () {
    setUp(() {
      Get.testMode = true;
      Get.put<SettingsService>(_Settings());
    });
    tearDown(() {
      Get.reset();
      Get.testMode = false;
    });

    testWidgets('first upward drag warns and holds 100%, the next drag reaches 150%', (tester) async {
      final controller = _FakeController(0.9);
      await _mount(tester, controller);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(IconButton)));
      await tester.pumpAndSettle();

      // First attempt: warn and stay at the safe cap.
      await _dragUp(tester, mouse, 400);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('100%'), findsOneWidget);
      expect(find.byKey(const ValueKey('volume-high-risk-notice')), findsOneWidget);
      expect(controller.writes.last, DesktopVolumePolicy.safeVolume);

      // A separate, new upward adjustment may now enter the boosted range.
      await _dragUp(tester, mouse, 200);
      expect(find.text('150%'), findsOneWidget);
      expect(controller.writes.last, DesktopVolumePolicy.maxVolume);

      await _dispose(tester, mouse);
    });

    testWidgets('mute and unmute restore the temporary boosted volume', (tester) async {
      final controller = _FakeController(1.4);
      await _mount(tester, controller);

      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(controller.writes.last, 0);

      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(controller.writes.last, 1.4);
    });

    testWidgets('a new room resets the confirmation and re-asks for high volume', (tester) async {
      final first = _FakeController(0.9);
      await _mount(tester, first);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.byType(IconButton)));
      await tester.pumpAndSettle();
      await _dragUp(tester, mouse, 400);
      await _dragUp(tester, mouse, 200);
      expect(find.text('150%'), findsOneWidget);
      expect(first.desktopVolumeGate.isBoostUnlocked, isTrue);

      // Switching rooms binds a fresh controller whose gate starts unconfirmed.
      final next = _FakeController(0.9);
      await _mount(tester, next);
      expect(next.desktopVolumeGate.isBoostUnlocked, isFalse);

      final request = next.requestDesktopVolume(startsNewAdjustment: true, target: 1.2);
      expect(request.applied, DesktopVolumePolicy.safeVolume);
      expect(request.riskPrompt, isTrue);

      await _dispose(tester, mouse);
    });
  });
}

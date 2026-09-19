import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/common/services/utils/hive_rx.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/common/utils/settings_overlay_sync.dart';

/// A child window cannot write the primary settings box, so it reports its
/// changes as a patch. These tests pin down both halves: what a child window
/// records, and what the primary window does with it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;
  late Directory overlayDirectory;

  setUpAll(() async {
    Get.testMode = true;
    hiveDirectory = await Directory.systemTemp.createTemp('settings-overlay-hive-');
    Hive.init(hiveDirectory.path);
    await HivePrefUtil.init();
  });

  setUp(() async {
    overlayDirectory = await Directory.systemTemp.createTemp('settings-overlay-patches-');
    resetPrefRxRegistry();
    await HivePrefUtil.clear();
  });

  tearDown(() async {
    await SettingsOverlaySync.stopWatching();
    HivePrefUtil.watchWrites();
    resetPrefRxRegistry();
    if (await overlayDirectory.exists()) await overlayDirectory.delete(recursive: true);
  });

  tearDownAll(() async {
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  File patchFile(String name) => File('${overlayDirectory.path}/$name');

  test('a child window records only the keys it actually changed', () async {
    final collector = SettingsOverlayCollector(patchFile('window_1_1.json'))..start();

    await HivePrefUtil.setDouble('danmakuSpeed', 155.0);
    await HivePrefUtil.setInt('videoFitIndex', 3);
    await collector.flush();
    collector.stop();

    expect(jsonDecode(await patchFile('window_1_1.json').readAsString()), {'danmakuSpeed': 155.0, 'videoFitIndex': 3});
  });

  test('a merged patch restores the changes into primary window storage', () async {
    final collector = SettingsOverlayCollector(patchFile('window_1_1.json'))..start();
    await HivePrefUtil.setDouble('danmakuSpeed', 155.0);
    await HivePrefUtil.setInt('videoFitIndex', 3);
    await collector.flush();
    collector.stop();

    // The child window is gone and the primary window never saw these values.
    await HivePrefUtil.clear();

    expect(await SettingsOverlaySync.applyPending(overlayDirectory), 1);
    expect(HivePrefUtil.getDouble('danmakuSpeed'), 155.0);
    expect(HivePrefUtil.getInt('videoFitIndex'), 3);
    expect(await patchFile('window_1_1.json').exists(), isFalse);
  });

  test('a merged patch also reaches a controller that is already alive', () async {
    final live = hiveDouble('danmakuSpeed', 120.0);
    expect(live.v, 120.0);

    patchFile('window_3_3.json').writeAsStringSync(jsonEncode({'danmakuSpeed': 155.0}));

    expect(await SettingsOverlaySync.applyPending(overlayDirectory), 1);
    expect(live.v, 155.0);
    expect(HivePrefUtil.getDouble('danmakuSpeed'), 155.0);
  });

  test('an integer survives the storage round trip into a double setting', () async {
    final live = hiveDouble('danmakuFontSize', 16.0);
    patchFile('window_4_4.json').writeAsStringSync(jsonEncode({'danmakuFontSize': 20}));

    expect(await SettingsOverlaySync.applyPending(overlayDirectory), 1);
    expect(live.v, 20.0);
    expect(HivePrefUtil.getDouble('danmakuFontSize'), 20.0);
  });

  test('later patches win when two windows changed the same key', () async {
    patchFile('window_1_1.json').writeAsStringSync(jsonEncode({'videoFitIndex': 2}));
    patchFile('window_2_2.json').writeAsStringSync(jsonEncode({'videoFitIndex': 5}));

    expect(await SettingsOverlaySync.applyPending(overlayDirectory), 2);
    expect(HivePrefUtil.getInt('videoFitIndex'), 5);
  });

  test('a malformed patch is kept rather than silently discarded', () async {
    final broken = patchFile('window_9_9.json')..writeAsStringSync('{not json');

    expect(await SettingsOverlaySync.applyPending(overlayDirectory), 0);
    expect(await broken.exists(), isTrue);
  });

  test('a half-written patch is ignored until it is renamed into place', () async {
    patchFile('window_5_5.json.tmp').writeAsStringSync(jsonEncode({'videoFitIndex': 4}));

    expect(await SettingsOverlaySync.applyPending(overlayDirectory), 0);
    expect(HivePrefUtil.getInt('videoFitIndex'), isNull);
  });

  test('without a collector the primary window writes straight to storage', () async {
    await HivePrefUtil.setInt('videoFitIndex', 4);

    expect(HivePrefUtil.getInt('videoFitIndex'), 4);
    expect(overlayDirectory.listSync(), isEmpty);
  });

  test('a merged patch reaches a live hiveObject controller, not just storage', () async {
    final live = hiveObject<List<String>>(
      'favoriteRooms',
      <String>[],
      fromJson: (json) => List<String>.from(json['list'] ?? const <String>[]),
      toJson: (list) => {'list': list},
    );
    expect(live.v, isEmpty);

    // A child window persists the encoded document, not the decoded object.
    patchFile(
      'window_7_7.json',
    ).writeAsStringSync(jsonEncode({'favoriteRooms': jsonEncode({'list': ['room-a', 'room-b']})}));

    expect(await SettingsOverlaySync.applyPending(overlayDirectory), 1);
    expect(live.v, ['room-a', 'room-b']);
    expect(HivePrefUtil.getString('favoriteRooms'), jsonEncode({'list': ['room-a', 'room-b']}));
  });

  test('a malformed hiveObject payload leaves the live value in place', () async {
    final live = hiveObject<List<String>>(
      'favoriteRooms',
      <String>[],
      fromJson: (json) => List<String>.from(json['list'] ?? const <String>[]),
      toJson: (list) => {'list': list},
    );
    live.v = ['kept'];

    patchFile('window_8_8.json').writeAsStringSync(jsonEncode({'favoriteRooms': '{not json'}));

    expect(await SettingsOverlaySync.applyPending(overlayDirectory), 1);
    expect(live.v, ['kept']);
  });

  test('a patch written while the primary window watches is merged on arrival', () async {
    final live = hiveInt('videoFitIndex', 0);
    await SettingsOverlaySync.watchDirectory(overlayDirectory);

    patchFile('window_6_6.json').writeAsStringSync(jsonEncode({'videoFitIndex': 4}));

    // The watch only accelerates an existing merge path, so poll instead of
    // assuming one event loop turn delivers the event.
    for (var attempt = 0; attempt < 80 && live.v != 4; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    expect(live.v, 4);
  });
}

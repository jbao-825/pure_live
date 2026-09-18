import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pure_live/common/services/settings/app_settings_controller.dart';
import 'package:pure_live/common/services/settings/font_settings_controller.dart';
import 'package:pure_live/common/services/settings_service.dart';
import 'package:pure_live/common/utils/hive_pref_util.dart';
import 'package:pure_live/get/get.dart';
import 'package:pure_live/modules/favorite/favorite_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The favourites app bar shortcut is a second entry point for a setting the
/// navigation gate reads directly. A tap here and a tap in Settings must stay
/// interchangeable, so the shortcut has to flip exactly that one value - and
/// must not change the default on its own.
///
/// The widget is pumped directly rather than through [FavoritePage]: the app
/// bar decides whether to mount it (`PlatformUtils.isWindows`), while this test
/// covers the toggle's own contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory hiveDirectory;

  setUpAll(() async {
    hiveDirectory = await Directory.systemTemp.createTemp('pure-live-new-window-toggle-test-');
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
    Hive.init(hiveDirectory.path);
    await HivePrefUtil.init();
  });

  setUp(() async {
    Get.testMode = true;
    Get.reset();
    await HivePrefUtil.clear();
    Get.put<SettingsService>(_ToggleSettingsService(AppSettingsController()));
  });

  tearDown(Get.reset);

  tearDownAll(() async {
    await Hive.close().timeout(const Duration(seconds: 10));
    await hiveDirectory.delete(recursive: true);
  });

  testWidgets('app bar shortcut flips the open-in-new-window setting both ways', (tester) async {
    final app = SettingsService.to.app;
    expect(app.openRoomInNewWindow.value, isFalse, reason: 'the shortcut must not change the default');

    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: const [Locale('zh')],
        path: 'assets/translations',
        fallbackLocale: const Locale('zh'),
        assetLoader: const _ToggleAssetLoader(),
        child: Builder(
          builder: (context) => GetMaterialApp(
            locale: context.locale,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            home: Scaffold(appBar: AppBar(actions: const [OpenInNewWindowToggle()])),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byType(OpenInNewWindowToggle);
    expect(toggle, findsOneWidget);
    expect(find.byTooltip('点直播间默认在新窗口打开'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.openRoomInNewWindow.value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(app.openRoomInNewWindow.value, isFalse);

    expect(tester.takeException(), isNull);
  });
}

class _ToggleAssetLoader extends AssetLoader {
  const _ToggleAssetLoader();

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) async => {
    'open_room_in_new_window_default': '点直播间默认在新窗口打开',
  };
}

// Widget tests own a fake clock. Keep their observable state in memory and skip
// the production controller registrations.
class _ToggleSettingsService extends SettingsService {
  _ToggleSettingsService(this._app) : _font = FontSettingsController();

  final AppSettingsController _app;
  final FontSettingsController _font;

  @override
  AppSettingsController get app => _app;

  @override
  FontSettingsController get font => _font;

  @override
  // ignore: must_call_super
  void onInit() {}
}

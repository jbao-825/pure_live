import 'dart:io';
import 'dart:async';
import 'dart:developer' as developer;

import 'package:pure_live/common/index.dart';
import 'package:pure_live/plugins/utils.dart';
import 'package:pure_live/common/global/initialized.dart';
import 'package:pure_live/core/site/cc/cc_catalog.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pure_live/common/utils/windows_multi_instance_launcher.dart';

/// APP页面跳转封装
/// * 需要参数的页面都应使用此类
/// * 如不需要参数，可以使用Get.toNamed
class AppNavigator {
  static bool _openingLiveRoom = false;
  static bool _openingOfficialCategory = false;

  /// Windows only. True when live rooms should open in their own window and
  /// this process is the primary one. A child window reports a non-empty
  /// instance id, so its own taps stay in place - which is also what keeps a
  /// window from spawning further windows.
  ///
  /// Deliberately independent of `enableNewWindowPlay`: that setting only
  /// controls whether the manual "new window" entries are visible, while this
  /// gate decides whether tapping a room reroutes. Hiding the entries must not
  /// silently disable the reroute - "no manual entry, always auto-open" is a
  /// legitimate combination.
  static bool get _opensLiveRoomInNewWindow =>
      Platform.isWindows &&
      AppInitializer().instanceId.isEmpty &&
      SettingsService.to.app.openRoomInNewWindow.v;

  /// 跳转至分类详情
  static Future<void> toCategoryDetail({required Site site, required LiveArea category}) async {
    if (CCCatalog.isOfficialEntry(category)) {
      if (_openingOfficialCategory) return;
      final uri = site.id == Sites.ccSite ? CCCatalog.officialEntryUri(category) : null;
      if (uri == null) {
        ToastUtil.show(i18n('external_browser_not_opened'));
        return;
      }
      _openingOfficialCategory = true;
      try {
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          ToastUtil.show(i18n('external_browser_not_opened'));
        }
      } catch (_) {
        ToastUtil.show(i18n('external_browser_not_opened'));
      } finally {
        _openingOfficialCategory = false;
      }
      return;
    }
    Get.toNamed(RoutePath.kAreaRooms, arguments: [site, category]);
  }

  /// 跳转至直播间
  static Future<void> toLiveRoomDetail({required LiveRoom liveRoom}) async {
    if (_openingLiveRoom) return;
    final platform = (liveRoom.platform?.trim() ?? '').toLowerCase();
    final roomId = liveRoom.roomId?.trim() ?? '';
    if (platform.isEmpty || roomId.isEmpty || !Sites.isSupported(platform)) {
      ToastUtil.show(i18n('get_room_info_failed_retry'));
      return;
    }
    final normalizedRoom = liveRoom.platform == platform && liveRoom.roomId == roomId
        ? liveRoom
        : liveRoom.copyWith(platform: platform, roomId: roomId);
    // Every entry point (favourites, home, categories, search, history, ...)
    // funnels through here, so this single gate covers all of them and any
    // entry added later inherits the setting without touching the UI layer.
    if (_opensLiveRoomInNewWindow) {
      _openingLiveRoom = true;
      try {
        await WindowsMultiInstanceLauncher.launch(room: normalizedRoom);
      } catch (error, stackTrace) {
        developer.log(
          'Open live room in a new Windows instance failed',
          name: 'AppNavigator',
          error: error,
          stackTrace: stackTrace,
        );
        ToastUtil.show(i18n('open_new_window_failed'));
      } finally {
        _openingLiveRoom = false;
      }
      return;
    }
    _openingLiveRoom = true;
    try {
      final manager = GlobalPlayerService.instance.player;
      if (manager.isAppFloatingActive) {
        if (manager.currentFloatRoom == normalizedRoom) {
          manager.prepareRoomSessionReentry(normalizedRoom);
        } else {
          manager.cancelRoomSessionReentry();
        }
        await manager.closeAppFloating();
      } else {
        manager.cancelRoomSessionReentry();
      }
      await Get.toNamed(RoutePath.kLivePlay, arguments: normalizedRoom, parameters: {"site": platform});
    } finally {
      _openingLiveRoom = false;
    }
  }

  static Future<void> offAndToRoomDetail({required LiveRoom liveRoom}) async {
    final platform = (liveRoom.platform?.trim() ?? '').toLowerCase();
    final roomId = liveRoom.roomId?.trim() ?? '';
    if (platform.isEmpty || roomId.isEmpty || !Sites.isSupported(platform)) {
      ToastUtil.show(i18n('get_room_info_failed_retry'));
      return;
    }
    final normalizedRoom = liveRoom.platform == platform && liveRoom.roomId == roomId
        ? liveRoom
        : liveRoom.copyWith(platform: platform, roomId: roomId);
    await Get.offAndToNamed(RoutePath.kLivePlay, arguments: normalizedRoom, parameters: {"site": platform});
  }

  /// 跳转至多画面同看页面。
  ///
  /// 房间分配由页面内交互完成，无需携带参数。
  static Future<void> toMultiview() async {
    await Get.toNamed(RoutePath.kMultiview);
  }

  /// 跳转至哔哩哔哩登录
  static Future toBiliBiliLogin() async {
    var contents = [i18n("sms_login"), i18n("qrcode_login")];
    if (Platform.isAndroid || Platform.isIOS) {
      var result = await Utils.showOptionDialog(contents, '', title: i18n("select_login_method"));
      if (result == i18n("sms_login")) {
        await Get.toNamed(RoutePath.kBiliBiliWebLogin);
      } else if (result == i18n("qrcode_login")) {
        await Get.toNamed(RoutePath.kBiliBiliQRLogin);
      }
    } else {
      await Get.toNamed(RoutePath.kBiliBiliQRLogin);
    }
  }
}

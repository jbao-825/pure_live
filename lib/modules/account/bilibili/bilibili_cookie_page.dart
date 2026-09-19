import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/account/bilibili/bilibili_cookie_controller.dart';
import 'package:pure_live/modules/account/widgets/account_cookie_editor.dart';

class BilibiliCookiePage extends GetView<BilibiliCookieController> {
  const BilibiliCookiePage({super.key});

  @override
  Widget build(BuildContext context) {
    return AccountCookieEditorPage(
      controller: controller.cookieController,
      hintText: i18n('bilibili_cookie_hint'),
      tipText: i18n('bilibili_cookie_tip'),
      onSave: controller.setCookie,
    );
  }
}

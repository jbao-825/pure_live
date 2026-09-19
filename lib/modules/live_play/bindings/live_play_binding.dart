import 'package:pure_live/common/index.dart';
import 'package:pure_live/modules/live_play/controllers/live_play_controller.dart';

class LivePlayBinding extends Binding {
  @override
  List<Bind> dependencies() {
    // "entryFill" marks a page entry, i.e. a room opened from a list. The room
    // session rebuilds that stay inside the player (switch room, refresh) never
    // come through this route, so they inherit no fill and keep the current
    // layout. See LivePlayController.entryFillWindow.
    return [
      Bind.lazyPut(
        () => LivePlayController(
          room: Get.arguments,
          site: Get.parameters["site"] ?? "",
          entryFillWindow: Get.parameters["entryFill"] == "1",
        ),
      ),
    ];
  }
}

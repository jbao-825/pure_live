import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/player/utils/fullscreen.dart';

void main() {
  test('Windows opens a room in the window-fill presentation', () {
    expect(
      resolveDefaultRoomPresentation(isWindows: true, enableFullScreenDefault: false),
      DefaultRoomPresentation.windowFill,
    );
  });

  test('the automatic fullscreen preference keeps fullscreen and never stacks with the fill', () {
    expect(
      resolveDefaultRoomPresentation(isWindows: true, enableFullScreenDefault: true),
      DefaultRoomPresentation.fullscreen,
    );
    expect(
      resolveDefaultRoomPresentation(isWindows: false, enableFullScreenDefault: true),
      DefaultRoomPresentation.fullscreen,
    );
  });

  test('other platforms keep the ordinary room presentation', () {
    expect(
      resolveDefaultRoomPresentation(isWindows: false, enableFullScreenDefault: false),
      DefaultRoomPresentation.none,
    );
  });
}

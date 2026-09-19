import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/player/utils/fullscreen.dart';

void main() {
  test('a Windows page entry opens the room in the window-fill presentation', () {
    expect(
      resolveDefaultRoomPresentation(isWindows: true, enableFullScreenDefault: false, fillWindowOnEntry: true),
      DefaultRoomPresentation.windowFill,
    );
  });

  test('a Windows session rebuilt without a page entry keeps the ordinary layout', () {
    // Switch room, refresh and floating-window restores reuse the open room
    // session instead of entering the page again, so they must leave the
    // layout the user is already looking at untouched.
    expect(
      resolveDefaultRoomPresentation(isWindows: true, enableFullScreenDefault: false, fillWindowOnEntry: false),
      DefaultRoomPresentation.none,
    );
  });

  test('the automatic fullscreen preference keeps fullscreen and never stacks with the fill', () {
    expect(
      resolveDefaultRoomPresentation(isWindows: true, enableFullScreenDefault: true, fillWindowOnEntry: true),
      DefaultRoomPresentation.fullscreen,
    );
    expect(
      resolveDefaultRoomPresentation(isWindows: false, enableFullScreenDefault: true, fillWindowOnEntry: true),
      DefaultRoomPresentation.fullscreen,
    );
  });

  test('other platforms keep the ordinary room presentation', () {
    expect(
      resolveDefaultRoomPresentation(isWindows: false, enableFullScreenDefault: false, fillWindowOnEntry: true),
      DefaultRoomPresentation.none,
    );
    expect(
      resolveDefaultRoomPresentation(isWindows: false, enableFullScreenDefault: false, fillWindowOnEntry: false),
      DefaultRoomPresentation.none,
    );
  });
}

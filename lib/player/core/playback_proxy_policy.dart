import 'package:pure_live/common/services/settings_service.dart';

/// Media transport settings, deliberately independent of the application/API
/// proxy used by recording's existing HTTP relay.
class PlaybackProxyPolicy {
  const PlaybackProxyPolicy._();

  /// Directive for one media request.
  ///
  /// [siteId] is the platform owning the room when the caller knows it. mpv's
  /// `http-proxy` is an instance-wide property, so the player paths pass
  /// [siteId]; relay transports pass [source] and let the built-in platform
  /// table decide.
  static String directiveFor({String? siteId, Uri? source}) {
    try {
      return SettingsService.to.proxy.directiveForPlayerRequest(siteId: siteId, source: source);
    } catch (_) {
      return 'DIRECT';
    }
  }

  /// Converts a directive into mpv's `http-proxy` value.
  ///
  /// An empty string is the value that clears an already applied proxy, so a
  /// room on an unselected platform returns to a direct connection instead of
  /// reusing the endpoint configured for the previous room.
  static String nativeUrl(String directive, {required bool privateInput}) {
    if (privateInput || !directive.startsWith('PROXY ')) return '';
    return 'http://${directive.substring(6)}';
  }

  static String nativeUrlFor({String? siteId, Uri? source, required bool privateInput}) =>
      nativeUrl(directiveFor(siteId: siteId, source: source), privateInput: privateInput);
}

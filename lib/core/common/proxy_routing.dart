const int defaultProxyPort = 7897;
const int minProxyPort = 1;
const int maxProxyPort = 65535;

bool isValidProxyPort(int port) => port >= minProxyPort && port <= maxProxyPort;

/// Repairs a persisted or imported port instead of passing an invalid socket
/// endpoint into every application, player and recorder proxy consumer.
int normalizeStoredProxyPort(int port) => isValidProxyPort(port) ? port : defaultProxyPort;

/// Normalizes a proxy host entered with desktop or mobile input methods.
///
/// Chinese keyboards commonly turn an ASCII dot into `。` or `．`. Passing
/// that value to `HttpClient.findProxy` makes Android try to resolve the whole
/// string as a DNS name, so an otherwise valid `127.0.0.1` proxy silently
/// breaks every request.
String normalizeProxyHost(String value) {
  return value
      .trim()
      .replaceAll('。', '.')
      .replaceAll('．', '.')
      .replaceAll('：', ':')
      .replaceAll('［', '[')
      .replaceAll('］', ']')
      .replaceAll(RegExp(r'\s+'), '');
}

/// Returns a usable TCP port while an auto-saved settings field is edited.
///
/// An empty, partial or out-of-range value stays in the text field for the
/// user to finish, but must not replace the last working proxy endpoint.
int? parseProxyPortInput(String value) {
  final port = int.tryParse(value.trim());
  if (port == null || !isValidProxyPort(port)) return null;
  return port;
}

/// Builds the directive accepted by `dart:io`'s `HttpClient.findProxy`.
///
/// Invalid or incomplete values deliberately remain direct. This keeps a
/// half-edited settings field from turning all application requests into an
/// invalid proxy lookup.
String buildProxyDirective({required bool enabled, required String host, required int port}) {
  if (host.contains(';') || host.contains('\r') || host.contains('\n')) {
    return 'DIRECT';
  }
  final normalizedHost = normalizeProxyHost(host);
  if (!enabled || normalizedHost.isEmpty || !isValidProxyPort(port)) {
    return 'DIRECT';
  }

  final endpointHost = normalizedHost.contains(':') && !normalizedHost.startsWith('[') && !normalizedHost.endsWith(']')
      ? '[$normalizedHost]'
      : normalizedHost;
  return 'PROXY $endpointHost:$port';
}

/// Which requests a configured proxy endpoint applies to.
///
/// [global] keeps the historical behaviour (every request through the owning
/// transport). [perSite] narrows it to the platforms the user selected, so
/// domestic and unselected platforms keep a direct connection.
enum ProxyScope {
  global('global'),
  perSite('perSite');

  const ProxyScope(this.storageValue);

  final String storageValue;

  /// Missing or unrecognized values keep the historical all-traffic behaviour.
  static ProxyScope fromStorage(String? value) => value == perSite.storageValue ? perSite : global;
}

/// Domains owned by the platforms this app can route through a proxy.
///
/// Only suffixes that appear in this repository's own platform adapters are
/// listed. A selected platform whose media CDN is not listed here stays
/// direct rather than being guessed, which is why [customProxySuffixes]
/// exists.
const Map<String, List<String>> proxiedSiteDomains = {
  'twitch': ['twitch.tv', 'ttvnw.net'],
  'soop': ['sooplive.co.kr', 'sooplive.com'],
  'picarto': ['picarto.tv'],
  'twitcasting': ['twitcasting.tv'],
  'openrec': ['mellow-fan.com'],
  'niconico': ['nicovideo.jp'],
  'ttinglive': ['flextv.co.kr'],
};

/// Platforms pre-selected when per-platform mode is first enabled.
const List<String> defaultProxiedSites = ['twitch', 'soop'];

bool _hostMatchesSuffix(String host, String suffix) => host == suffix || host.endsWith('.$suffix');

String _normalizeDomain(String value) => value.trim().toLowerCase().replaceAll('。', '.');

/// Resolves the platform owning [host], or null when it is not a known
/// proxied-platform domain.
String? siteIdForProxyHost(String host) {
  final target = _normalizeDomain(host);
  if (target.isEmpty) return null;
  for (final entry in proxiedSiteDomains.entries) {
    for (final suffix in entry.value) {
      if (_hostMatchesSuffix(target, suffix)) return entry.key;
    }
  }
  return null;
}

/// Whether a user-supplied suffix list covers [host].
///
/// Entries may be written as `example.com` or `*.example.com`; a leading
/// wildcard is accepted because that is how users describe CDN domains.
bool hostMatchesCustomSuffixes(String host, Iterable<String> suffixes) {
  final target = _normalizeDomain(host);
  if (target.isEmpty) return false;
  for (final raw in suffixes) {
    final suffix = _normalizeDomain(raw).replaceFirst(RegExp(r'^\*\.'), '');
    if (suffix.isEmpty) continue;
    if (_hostMatchesSuffix(target, suffix)) return true;
  }
  return false;
}

/// Builds the directive for a single request under the active scope.
///
/// [siteId] is the platform owning the request when the caller already knows
/// it (a player opening a room). Callers that only have a URL pass
/// [targetHost] and let the built-in table plus [customSuffixes] decide.
String buildScopedProxyDirective({
  required bool enabled,
  required String proxyHost,
  required int proxyPort,
  required ProxyScope scope,
  required Iterable<String> proxiedSites,
  required Iterable<String> customSuffixes,
  required String targetHost,
  String? siteId,
}) {
  if (!enabled) return 'DIRECT';
  final endpoint = buildProxyDirective(enabled: true, host: proxyHost, port: proxyPort);
  if (endpoint == 'DIRECT') return 'DIRECT';
  if (scope == ProxyScope.global) return endpoint;

  final selected = <String>{
    for (final site in proxiedSites)
      if (site.trim().isNotEmpty) site.trim().toLowerCase(),
  };

  final explicitSite = siteId?.trim().toLowerCase();
  final bool allowed;
  if (explicitSite != null && explicitSite.isNotEmpty) {
    allowed = selected.contains(explicitSite);
  } else {
    final resolved = siteIdForProxyHost(targetHost);
    allowed = resolved != null ? selected.contains(resolved) : hostMatchesCustomSuffixes(targetHost, customSuffixes);
  }
  return allowed ? endpoint : 'DIRECT';
}

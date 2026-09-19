import 'package:pure_live/common/index.dart';
import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/core/common/proxy_routing.dart' as proxy_routing;

class ProxySettingsController extends GetxController {
  static const int defaultProxyPort = proxy_routing.defaultProxyPort;

  final RxBool enableProxy = hiveBool('enableProxy', false);
  final RxString proxyHost = hiveString('proxyHost', '');
  final RxInt proxyPort = hiveInt('proxyPort', defaultProxyPort);

  // app proxy settings
  final RxBool enableAppProxy = hiveBool('enableAppProxy', false);
  final RxString appProxyHost = hiveString('appProxyHost', '');
  final RxInt appProxyPort = hiveInt('appProxyPort', defaultProxyPort);

  /// One selection shared by the player and the application transports.
  ///
  /// [proxyScope] keeps `global` by default so an upgraded install (or an
  /// older backup restored into this build) behaves exactly as before.
  final RxString proxyScope = hiveString('proxyScope', proxy_routing.ProxyScope.global.storageValue);
  final RxList<String> proxiedSites = hiveStringList('proxiedSites', proxy_routing.defaultProxiedSites);

  /// Extra domain suffixes the built-in platform table does not know about.
  final RxList<String> customProxySuffixes = hiveStringList('customProxySuffixes', const <String>[]);

  proxy_routing.ProxyScope get scope => proxy_routing.ProxyScope.fromStorage(proxyScope.v);

  @override
  void onInit() {
    super.onInit();

    final normalizedAppHost = proxy_routing.normalizeProxyHost(appProxyHost.v);
    if (normalizedAppHost != appProxyHost.v) appProxyHost.v = normalizedAppHost;
    final normalizedAppPort = proxy_routing.normalizeStoredProxyPort(appProxyPort.v);
    if (normalizedAppPort != appProxyPort.v) appProxyPort.v = normalizedAppPort;
    final normalizedPlayerHost = proxy_routing.normalizeProxyHost(proxyHost.v);
    if (normalizedPlayerHost != proxyHost.v) proxyHost.v = normalizedPlayerHost;
    final normalizedPlayerPort = proxy_routing.normalizeStoredProxyPort(proxyPort.v);
    if (normalizedPlayerPort != proxyPort.v) proxyPort.v = normalizedPlayerPort;

    ever<bool>(enableAppProxy, (_) => _refreshDioConnections());
    ever<String>(appProxyHost, (_) => _refreshDioConnections());
    ever<int>(appProxyPort, (_) => _refreshDioConnections());
    // A scope change only affects connections created afterwards. Every
    // transport re-evaluates the directive per request (and the player per
    // source), so dropping the keep-alive pool is enough to apply the new
    // scope to the next request without restarting the app.
    ever<String>(proxyScope, (_) => _refreshDioConnections());
  }

  void _refreshDioConnections() {
    try {
      HttpClient.instance.rebuildDio();
    } catch (_) {}
  }

  /// Directive for one application/API request.
  ///
  /// Covers the Dio client, the image/avatar cache, danmaku WebSockets and the
  /// recorder relay, which all share the application proxy endpoint.
  String directiveForAppRequest(Uri uri) =>
      _scopedDirective(enabled: enableAppProxy.v, host: appProxyHost.v, port: appProxyPort.v, source: uri);

  /// Directive for one player request.
  ///
  /// [siteId] is the platform owning the room when the caller knows it. The
  /// native mpv property cannot be scoped per URL, so that path passes
  /// [siteId]; relay transports pass [source] instead.
  String directiveForPlayerRequest({Uri? source, String? siteId}) =>
      _scopedDirective(enabled: enableProxy.v, host: proxyHost.v, port: proxyPort.v, source: source, siteId: siteId);

  /// Whether the application proxy covers [siteId].
  ///
  /// Transports that cannot evaluate a per-request directive (Android native
  /// HTTP, the Chromium integrity channel) ask this instead of reading the
  /// raw switch, so per-platform scope reaches them too.
  bool appProxyAppliesToSite(String siteId) =>
      _scopedDirective(
        enabled: enableAppProxy.v,
        host: appProxyHost.v,
        port: appProxyPort.v,
        source: null,
        siteId: siteId,
      ) !=
      'DIRECT';

  String _scopedDirective({
    required bool enabled,
    required String host,
    required int port,
    required Uri? source,
    String? siteId,
  }) {
    return proxy_routing.buildScopedProxyDirective(
      enabled: enabled,
      proxyHost: host,
      proxyPort: port,
      scope: scope,
      proxiedSites: proxiedSites,
      customSuffixes: customProxySuffixes,
      targetHost: source?.host ?? '',
      siteId: siteId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enableProxy': enableProxy.v,
      'proxyHost': proxy_routing.normalizeProxyHost(proxyHost.v),
      'proxyPort': proxy_routing.normalizeStoredProxyPort(proxyPort.v),
      'enableAppProxy': enableAppProxy.v,
      'appProxyHost': proxy_routing.normalizeProxyHost(appProxyHost.v),
      'appProxyPort': proxy_routing.normalizeStoredProxyPort(appProxyPort.v),
      'proxyScope': proxyScope.v,
      'proxiedSites': proxiedSites.toList(),
      'customProxySuffixes': customProxySuffixes.toList(),
    };
  }

  /// Parse the complete section without notifying observers or persisting values.
  static Map<String, dynamic> parseConfig(Map<String, dynamic> json) {
    return {
      'enableProxy': (json['enableProxy'] ?? false) as bool,
      'proxyHost': proxy_routing.normalizeProxyHost((json['proxyHost'] ?? '') as String),
      'proxyPort': proxy_routing.normalizeStoredProxyPort((json['proxyPort'] ?? defaultProxyPort) as int),
      'enableAppProxy': (json['enableAppProxy'] ?? false) as bool,
      'appProxyHost': proxy_routing.normalizeProxyHost((json['appProxyHost'] ?? '') as String),
      'appProxyPort': proxy_routing.normalizeStoredProxyPort((json['appProxyPort'] ?? defaultProxyPort) as int),
      'proxyScope': proxy_routing.ProxyScope.fromStorage(json['proxyScope'] as String?).storageValue,
      'proxiedSites': _parseStringList(json['proxiedSites'], proxy_routing.defaultProxiedSites),
      'customProxySuffixes': _parseStringList(json['customProxySuffixes'], const <String>[]),
    };
  }

  void fromJson(Map<String, dynamic> json) {
    final parsed = parseConfig(json);
    enableProxy.v = parsed['enableProxy'];
    proxyHost.v = parsed['proxyHost'];
    proxyPort.v = parsed['proxyPort'];
    enableAppProxy.v = parsed['enableAppProxy'];
    appProxyHost.v = parsed['appProxyHost'];
    appProxyPort.v = parsed['appProxyPort'];
    proxyScope.v = parsed['proxyScope'];
    proxiedSites.assignAll(parsed['proxiedSites'] as List<String>);
    customProxySuffixes.assignAll(parsed['customProxySuffixes'] as List<String>);
  }

  static Map<String, dynamic> extractConfig(Map<String, dynamic>? rootConfig) {
    final proxy = rootConfig?['proxy'] as Map<String, dynamic>? ?? {};
    return {
      'enableProxy': proxy['enableProxy'] ?? false,
      'proxyHost': proxy_routing.normalizeProxyHost((proxy['proxyHost'] ?? '') as String),
      'proxyPort': proxy_routing.normalizeStoredProxyPort((proxy['proxyPort'] ?? defaultProxyPort) as int),
      'enableAppProxy': proxy['enableAppProxy'] ?? false,
      'appProxyHost': proxy_routing.normalizeProxyHost((proxy['appProxyHost'] ?? '') as String),
      'appProxyPort': proxy_routing.normalizeStoredProxyPort((proxy['appProxyPort'] ?? defaultProxyPort) as int),
      'proxyScope': proxy_routing.ProxyScope.fromStorage(proxy['proxyScope'] as String?).storageValue,
      'proxiedSites': _parseStringList(proxy['proxiedSites'], proxy_routing.defaultProxiedSites),
      'customProxySuffixes': _parseStringList(proxy['customProxySuffixes'], const <String>[]),
    };
  }

  static Map<String, dynamic> mergeConfig(Map<String, dynamic> rootConfig, Map<String, dynamic> updateFields) {
    final proxy = Map<String, dynamic>.from(rootConfig['proxy'] ?? {});
    updateFields.forEach((k, v) => proxy[k] = v);
    rootConfig['proxy'] = proxy;
    return rootConfig;
  }

  /// Accepts only the string lists this section owns; a malformed or missing
  /// entry falls back to [fallback] instead of throwing during a restore.
  static List<String> _parseStringList(dynamic raw, List<String> fallback) {
    if (raw is! List) return List<String>.from(fallback);
    return [
      for (final entry in raw)
        if (entry?.toString().trim().isNotEmpty ?? false) entry.toString().trim(),
    ];
  }
}

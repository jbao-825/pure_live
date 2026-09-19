import 'package:flutter_test/flutter_test.dart';
import 'package:pure_live/core/common/proxy_routing.dart';

void main() {
  group('proxy routing', () {
    test('normalizes punctuation emitted by Chinese input methods', () {
      expect(normalizeProxyHost(' 127。0．0。1 '), '127.0.0.1');
      expect(normalizeProxyHost('［::1］'), '[::1]');
    });

    test('accepts only complete TCP port values', () {
      expect(parseProxyPortInput('1'), 1);
      expect(parseProxyPortInput(' 7897 '), 7897);
      expect(parseProxyPortInput('65535'), 65535);
      expect(parseProxyPortInput(''), isNull);
      expect(parseProxyPortInput('0'), isNull);
      expect(parseProxyPortInput('65536'), isNull);
      expect(parseProxyPortInput('12.5'), isNull);
    });

    test('repairs stored TCP ports with the product default', () {
      expect(normalizeStoredProxyPort(1), 1);
      expect(normalizeStoredProxyPort(65535), 65535);
      expect(normalizeStoredProxyPort(0), defaultProxyPort);
      expect(normalizeStoredProxyPort(65536), defaultProxyPort);
    });

    test('builds direct and proxy directives without invalid half-edited values', () {
      expect(buildProxyDirective(enabled: false, host: '127.0.0.1', port: 7897), 'DIRECT');
      expect(buildProxyDirective(enabled: true, host: '', port: 7897), 'DIRECT');
      expect(buildProxyDirective(enabled: true, host: 'localhost', port: 0), 'DIRECT');
      expect(buildProxyDirective(enabled: true, host: 'localhost', port: 7897), 'PROXY localhost:7897');
      expect(buildProxyDirective(enabled: true, host: '127。0。0。1', port: 7897), 'PROXY 127.0.0.1:7897');
      expect(buildProxyDirective(enabled: true, host: '::1', port: 7897), 'PROXY [::1]:7897');
    });

    test('rejects proxy-directive injection', () {
      expect(buildProxyDirective(enabled: true, host: 'localhost; DIRECT', port: 7897), 'DIRECT');
      expect(buildProxyDirective(enabled: true, host: 'localhost\nDIRECT', port: 7897), 'DIRECT');
    });
  });

  group('platform scoped proxy routing', () {
    const endpoint = 'PROXY 127.0.0.1:7897';

    String scoped({
      bool enabled = true,
      ProxyScope scope = ProxyScope.perSite,
      Iterable<String> sites = const ['twitch', 'soop'],
      Iterable<String> suffixes = const [],
      String targetHost = '',
      String? siteId,
    }) {
      return buildScopedProxyDirective(
        enabled: enabled,
        proxyHost: '127.0.0.1',
        proxyPort: 7897,
        scope: scope,
        proxiedSites: sites,
        customSuffixes: suffixes,
        targetHost: targetHost,
        siteId: siteId,
      );
    }

    test('reads persisted scope values defensively', () {
      expect(ProxyScope.fromStorage('perSite'), ProxyScope.perSite);
      expect(ProxyScope.fromStorage('global'), ProxyScope.global);
      expect(ProxyScope.fromStorage(null), ProxyScope.global);
      expect(ProxyScope.fromStorage('nonsense'), ProxyScope.global);
    });

    test('global scope keeps the historical all-traffic behaviour', () {
      expect(scoped(scope: ProxyScope.global, targetHost: 'live.bilibili.com'), endpoint);
      expect(scoped(scope: ProxyScope.global, targetHost: ''), endpoint);
      expect(scoped(enabled: false, scope: ProxyScope.global, targetHost: 'gql.twitch.tv'), 'DIRECT');
    });

    test('per-platform scope proxies only the selected platforms', () {
      expect(scoped(targetHost: 'gql.twitch.tv'), endpoint);
      expect(scoped(targetHost: 'usher.ttvnw.net'), endpoint);
      expect(scoped(targetHost: 'live.sooplive.co.kr'), endpoint);
      expect(scoped(targetHost: 'live.bilibili.com'), 'DIRECT');
      expect(scoped(targetHost: 'api.douyu.com'), 'DIRECT');
    });

    test('an unselected platform stays direct inside its own domain family', () {
      expect(scoped(targetHost: 'gql.twitch.tv', sites: const ['soop']), 'DIRECT');
      expect(scoped(targetHost: 'live.sooplive.co.kr', sites: const ['twitch']), 'DIRECT');
    });

    test('an explicit platform wins over the host lookup', () {
      // A media CDN the built-in table does not list still follows the room
      // it belongs to, and a host belonging to another platform does not
      // drag that platform through the proxy.
      expect(scoped(targetHost: 'edge.example.net', siteId: 'twitch'), endpoint);
      expect(scoped(targetHost: 'video.ttvnw.net', siteId: 'bilibili'), 'DIRECT');
    });

    test('custom suffixes cover platforms missing from the built-in table', () {
      expect(scoped(targetHost: 'edge.example.net', suffixes: const ['example.net']), endpoint);
      expect(scoped(targetHost: 'edge.example.net', suffixes: const ['*.example.net']), endpoint);
      expect(scoped(targetHost: 'edge.example.net', suffixes: const ['other.net']), 'DIRECT');
    });

    test('an invalid endpoint stays direct even when the platform matches', () {
      expect(
        buildScopedProxyDirective(
          enabled: true,
          proxyHost: '',
          proxyPort: 7897,
          scope: ProxyScope.perSite,
          proxiedSites: const ['twitch'],
          customSuffixes: const [],
          targetHost: 'gql.twitch.tv',
        ),
        'DIRECT',
      );
    });

    test('resolves the platform behind each protected domain', () {
      expect(siteIdForProxyHost('www.twitch.tv'), 'twitch');
      expect(siteIdForProxyHost('WWW.TWITCH.TV'), 'twitch');
      expect(siteIdForProxyHost('notwitch.tv'), isNull);
      expect(siteIdForProxyHost(''), isNull);
      expect(siteIdForProxyHost('live.nicovideo.jp'), 'niconico');
      expect(siteIdForProxyHost('www.flextv.co.kr'), 'ttinglive');
      expect(siteIdForProxyHost('ptvintern.picarto.tv'), 'picarto');
      expect(siteIdForProxyHost('public.mellow-fan.com'), 'openrec');
      expect(siteIdForProxyHost('frontendapi.twitcasting.tv'), 'twitcasting');
    });
  });
}

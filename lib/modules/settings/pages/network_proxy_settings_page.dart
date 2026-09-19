import 'package:flutter/services.dart';
import 'package:remixicon/remixicon.dart';
import 'package:pure_live/common/index.dart';
import 'package:pure_live/core/common/proxy_routing.dart';

final TextInputFormatter _proxyHostInputFormatter = TextInputFormatter.withFunction((oldValue, newValue) {
  final normalized = normalizeProxyHost(newValue.text);
  if (normalized == newValue.text) return newValue;
  return TextEditingValue(
    text: normalized,
    selection: TextSelection.collapsed(offset: normalized.length),
    composing: TextRange.empty,
  );
});

/// Display names for proxied platforms without a `site_<id>` translation
/// entry. Kept in step with `Sites._createSite`.
const Map<String, String> _proxySiteFallbackNames = {
  'picarto': 'Picarto',
  'twitcasting': 'TwitCasting',
  'openrec': 'mellow-fan (OPENREC)',
  'niconico': 'niconico',
  'ttinglive': 'FLEX TV (TTingLive)',
};

String _proxySiteLabel(String siteId) => i18nOr('site_$siteId', _proxySiteFallbackNames[siteId] ?? siteId);

class NetworkProxySettingsPage extends StatefulWidget {
  const NetworkProxySettingsPage({super.key});

  @override
  State<NetworkProxySettingsPage> createState() => _NetworkProxySettingsPageState();
}

class _NetworkProxySettingsPageState extends State<NetworkProxySettingsPage> {
  final proxyCtrl = SettingsService.to.proxy;

  late final TextEditingController _appHostController;
  late final TextEditingController _appPortController;
  late final TextEditingController _playerHostController;
  late final TextEditingController _playerPortController;
  late final TextEditingController _suffixController;
  late final TextEditingController _probeController;
  bool _appPortInvalid = false;
  bool _playerPortInvalid = false;

  @override
  void initState() {
    super.initState();
    _appHostController = TextEditingController(text: proxyCtrl.appProxyHost.v);
    _appPortController = TextEditingController(text: proxyCtrl.appProxyPort.v.toString());
    _playerHostController = TextEditingController(text: proxyCtrl.proxyHost.v);
    _playerPortController = TextEditingController(text: proxyCtrl.proxyPort.v.toString());
    _suffixController = TextEditingController();
    _probeController = TextEditingController();
    _appPortInvalid = parseProxyPortInput(_appPortController.text) == null;
    _playerPortInvalid = parseProxyPortInput(_playerPortController.text) == null;
  }

  @override
  void dispose() {
    _appHostController.dispose();
    _appPortController.dispose();
    _playerHostController.dispose();
    _playerPortController.dispose();
    _suffixController.dispose();
    _probeController.dispose();
    super.dispose();
  }

  void _updatePort(String rawValue, {required bool isAppProxy}) {
    final port = parseProxyPortInput(rawValue);
    final invalid = port == null;
    if (isAppProxy) {
      if (_appPortInvalid != invalid) setState(() => _appPortInvalid = invalid);
      if (port != null) proxyCtrl.appProxyPort.v = port;
      return;
    }
    if (_playerPortInvalid != invalid) setState(() => _playerPortInvalid = invalid);
    if (port != null) proxyCtrl.proxyPort.v = port;
  }

  void _toggleSite(String siteId, bool selected) {
    // Assign the whole list instead of mutating it in place: the value is
    // persisted through the Rx listener, so one write keeps Hive and the
    // observers in step.
    final next = proxyCtrl.proxiedSites.toList();
    if (selected) {
      if (!next.contains(siteId)) next.add(siteId);
    } else {
      next.remove(siteId);
    }
    proxyCtrl.proxiedSites.assignAll(next);
  }

  void _addSuffix() {
    final value = normalizeProxyHost(_suffixController.text).toLowerCase();
    if (value.isEmpty) return;
    final next = proxyCtrl.customProxySuffixes.toList();
    if (!next.contains(value)) next.add(value);
    proxyCtrl.customProxySuffixes.assignAll(next);
    _suffixController.clear();
    setState(() {});
  }

  void _removeSuffix(String value) {
    final next = proxyCtrl.customProxySuffixes.toList()..remove(value);
    proxyCtrl.customProxySuffixes.assignAll(next);
  }

  Widget _buildEndpointFields({
    required String keyPrefix,
    required TextEditingController hostController,
    required TextEditingController portController,
    required bool portInvalid,
    required ValueChanged<String> onHostChanged,
    required ValueChanged<String> onPortChanged,
    required String portHint,
  }) {
    final hostField = TextField(
      key: ValueKey('$keyPrefix-host'),
      controller: hostController,
      keyboardType: TextInputType.url,
      autocorrect: false,
      enableSuggestions: false,
      inputFormatters: [_proxyHostInputFormatter],
      decoration: InputDecoration(
        labelText: i18n('proxy_address_label'),
        hintText: '127.0.0.1',
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onHostChanged,
    );
    final portField = TextField(
      key: ValueKey('$keyPrefix-port'),
      controller: portController,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: i18n('proxy_port_label'),
        hintText: portHint,
        errorText: portInvalid ? i18n('proxy_port_invalid') : null,
        errorMaxLines: 3,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onPortChanged,
    );

    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mediaQuery = MediaQuery.of(context);
          final stackFields = constraints.maxWidth < 420 || mediaQuery.textScaler.scale(13) > 18;
          if (stackFields) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [hostField, const SizedBox(height: 12), portField],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: hostField),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: portField),
            ],
          );
        },
      ),
    );
  }

  /// Both endpoints share this selection, so it is presented once above them.
  Widget _buildScopeCard(ThemeData theme) {
    final perSite = proxyCtrl.scope == ProxyScope.perSite;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        context.buildGroupTitle(i18n('proxy_scope_group_title')),
        context.buildModernCard([
          SwitchListTile(
            secondary: Icon(Remix.global_line, color: theme.colorScheme.primary),
            title: Text(i18n('proxy_scope_per_site')),
            subtitle: Text(i18n('proxy_scope_per_site_desc')),
            value: perSite,
            // SwitchListTile hands over a non-null bool, unlike the tri-state
            // checkbox below, so no null fallback belongs here.
            onChanged: (val) =>
                proxyCtrl.proxyScope.v = val ? ProxyScope.perSite.storageValue : ProxyScope.global.storageValue,
          ),
          if (perSite) ...[
            const Divider(height: 1),
            _buildSitePicker(theme),
            const Divider(height: 1),
            _buildSuffixEditor(theme),
            const Divider(height: 1),
            _buildProbe(theme),
          ],
        ]),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildSitePicker(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(i18n('proxy_sites_desc'), style: theme.textTheme.bodySmall),
        ),
        for (final siteId in proxiedSiteDomains.keys)
          CheckboxListTile(
            key: ValueKey('proxy-site-$siteId'),
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(_proxySiteLabel(siteId)),
            value: proxyCtrl.proxiedSites.contains(siteId),
            onChanged: (val) => _toggleSite(siteId, val ?? false),
          ),
      ],
    );
  }

  Widget _buildSuffixEditor(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(i18n('proxy_custom_suffix_title'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(i18n('proxy_custom_suffix_desc'), style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('proxy-suffix-input'),
                  controller: _suffixController,
                  autocorrect: false,
                  enableSuggestions: false,
                  inputFormatters: [_proxyHostInputFormatter],
                  decoration: const InputDecoration(
                    hintText: 'example.com',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _addSuffix(),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('proxy-suffix-add'),
                onPressed: _addSuffix,
                child: Text(i18n('proxy_custom_suffix_add')),
              ),
            ],
          ),
          if (proxyCtrl.customProxySuffixes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final suffix in proxyCtrl.customProxySuffixes)
                    InputChip(
                      label: Text(suffix),
                      onDeleted: () => _removeSuffix(suffix),
                      deleteIcon: const Icon(Remix.delete_bin_6_line, size: 16),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Answers "I selected this platform, so why is it still direct?" without
  /// asking the user to read the built-in table in the source.
  Widget _buildProbe(ThemeData theme) {
    final raw = _probeController.text.trim();
    final uri = raw.isEmpty ? null : Uri.tryParse(raw.contains('://') ? raw : 'https://$raw/');
    final host = uri?.host ?? '';
    final siteId = host.isEmpty ? null : siteIdForProxyHost(host);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(i18n('proxy_probe_title'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(i18n('proxy_probe_desc'), style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('proxy-probe-input'),
            controller: _probeController,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: 'usher.ttvnw.net',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          if (host.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${i18n('proxy_probe_site')}: ${siteId == null ? i18n('proxy_probe_unknown') : _proxySiteLabel(siteId)}',
              key: const ValueKey('proxy-probe-site'),
              style: theme.textTheme.bodySmall,
            ),
            Text(
              '${i18n('proxy_probe_app')}: '
              '${proxyCtrl.directiveForAppRequest(uri!).startsWith('PROXY ') ? i18n('proxy_probe_proxied') : i18n('proxy_probe_direct')}',
              key: const ValueKey('proxy-probe-app'),
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              '${i18n('proxy_probe_player')}: '
              '${proxyCtrl.directiveForPlayerRequest(source: uri).startsWith('PROXY ') ? i18n('proxy_probe_proxied') : i18n('proxy_probe_direct')}',
              key: const ValueKey('proxy-probe-player'),
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(i18n("network_proxy_settings"))),
      body: Obx(() {
        return ListView(
          physics: const PureLiveScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            _buildScopeCard(theme),

            context.buildGroupTitle(i18n("app_proxy_group_title")),
            context.buildModernCard([
              SwitchListTile(
                secondary: Icon(Remix.apps_line, color: theme.colorScheme.primary),
                title: Text(i18n("enable_app_proxy")),
                subtitle: Text(i18n("enable_app_proxy_desc")),
                value: proxyCtrl.enableAppProxy.v,
                onChanged: (val) => proxyCtrl.enableAppProxy.v = val,
              ),
              if (proxyCtrl.enableAppProxy.v) ...[
                _buildEndpointFields(
                  keyPrefix: 'app-proxy',
                  hostController: _appHostController,
                  portController: _appPortController,
                  portInvalid: _appPortInvalid,
                  onHostChanged: (value) => proxyCtrl.appProxyHost.v = normalizeProxyHost(value),
                  onPortChanged: (value) => _updatePort(value, isAppProxy: true),
                  portHint: '7890',
                ),
              ],
            ]),

            const SizedBox(height: 24),
            context.buildGroupTitle(i18n("player_proxy_group_title")),
            context.buildModernCard([
              SwitchListTile(
                secondary: Icon(Remix.video_line, color: theme.colorScheme.primary),
                title: Text(i18n("enable_player_proxy")),
                subtitle: Text(i18n("enable_player_proxy_desc")),
                value: proxyCtrl.enableProxy.v,
                onChanged: (val) => proxyCtrl.enableProxy.v = val,
              ),
              if (proxyCtrl.enableProxy.v) ...[
                _buildEndpointFields(
                  keyPrefix: 'player-proxy',
                  hostController: _playerHostController,
                  portController: _playerPortController,
                  portInvalid: _playerPortInvalid,
                  onHostChanged: (value) => proxyCtrl.proxyHost.v = normalizeProxyHost(value),
                  onPortChanged: (value) => _updatePort(value, isAppProxy: false),
                  portHint: '1080',
                ),
              ],
            ]),
            const SizedBox(height: 32),
          ],
        );
      }),
    );
  }
}

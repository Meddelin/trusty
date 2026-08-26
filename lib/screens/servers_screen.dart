import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../models/vpn_status.dart';
import '../services/config_service.dart';
import '../services/vpn_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/connection_test.dart';
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';

/// Server management as a LIST, not a dropdown: one click on a card makes
/// that server active, the pencil expands an inline editor. Shared network
/// settings (DNS — identical for every server) live at the bottom.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key});

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  final _formKey = GlobalKey<FormState>();

  late ConfigService _configService;

  List<ServerConfig> _servers = [];
  String _activeId = '';
  bool _isLoading = true;

  /// Server whose inline editor is open (null = all collapsed).
  String? _expandedId;

  /// The loaded entry backing the open editor (source for copyWith on save).
  ServerConfig? _editing;
  bool _dirty = false;
  bool _passwordVisible = false;
  bool _testingEditor = false;

  // Editor fields
  final _name = TextEditingController();
  final _hostname = TextEditingController();
  final _address = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _customSni = TextEditingController();
  final _clientRandomPrefix = TextEditingController();
  bool _hasIpv6 = true;
  bool _skipVerification = false;
  bool _antiDpi = false;
  bool _postQuantumGroupEnabled = true;
  String _upstreamProtocol = 'http2';

  // Shared network settings (DNS, instant apply)
  final _dns = TextEditingController();
  final FocusNode _dnsFocus = FocusNode();
  String? _dnsError;
  bool _dnsApplying = false;

  /// DNS-over-HTTPS presets offered next to the DNS field. Picking one
  /// APPENDS to the comma-separated upstream list, it never replaces it.
  static const List<(String, String)> _dnsPresets = [
    ('AdGuard Default', 'https://dns.adguard-dns.com/dns-query'),
    ('AdGuard Family', 'https://family.adguard-dns.com/dns-query'),
    ('AdGuard Non-filtering', 'https://unfiltered.adguard-dns.com/dns-query'),
    ('Cloudflare', 'https://dns.cloudflare.com/dns-query'),
    ('Google', 'https://dns.google/dns-query'),
  ];

  @override
  void initState() {
    super.initState();
    _configService = context.read<ConfigService>();
    _configService.addListener(_onConfigChanged);
    _dnsFocus.addListener(() {
      if (!_dnsFocus.hasFocus) _applyDns();
    });
    _reload();
  }

  @override
  void dispose() {
    _configService.removeListener(_onConfigChanged);
    _dnsFocus.dispose();
    for (final c in [
      _name, _hostname, _address, _port, _username, _password,
      _customSni, _clientRandomPrefix, _dns,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onConfigChanged() {
    // Never clobber an open, edited form from external notifications.
    if (mounted && !_dirty) _reload();
  }

  Future<void> _reload() async {
    final servers = await _configService.loadServers();
    final activeId = await _configService.getActiveServerId();
    final config = await _configService.loadConfig();
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _activeId = activeId;
      if (!_dnsFocus.hasFocus) {
        _dns.text = config.dns;
        _dnsError = null;
      }
      // Editor for a deleted server closes itself.
      if (_expandedId != null && !servers.any((s) => s.id == _expandedId)) {
        _expandedId = null;
        _editing = null;
        _dirty = false;
      }
      _isLoading = false;
    });
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: const Text(
            'You have unsaved changes to this server. Leaving now will lose them.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true) {
      _dirty = false;
      return true;
    }
    return false;
  }

  Future<void> _openEditor(ServerConfig server) async {
    if (_expandedId == server.id) return;
    if (!await _confirmDiscard()) return;
    final full = await _configService.loadServerEntry(server.id);
    if (full == null || !mounted) return;
    setState(() {
      _expandedId = server.id;
      _editing = full;
      _dirty = false;
      _passwordVisible = false;
      _name.text = full.name;
      _hostname.text = full.hostname;
      _address.text = full.address;
      _port.text = full.port.toString();
      _username.text = full.username;
      _password.text = full.password;
      _customSni.text = full.customSni;
      _clientRandomPrefix.text = full.clientRandomPrefix;
      _hasIpv6 = full.hasIpv6;
      _skipVerification = full.skipVerification;
      _antiDpi = full.antiDpi;
      _postQuantumGroupEnabled = full.postQuantumGroupEnabled;
      _upstreamProtocol = full.upstreamProtocol;
    });
  }

  Future<void> _closeEditor() async {
    if (!await _confirmDiscard()) return;
    setState(() {
      _expandedId = null;
      _editing = null;
    });
  }

  Future<void> _saveEditor() async {
    final base = _editing;
    if (base == null) return;
    if (!_formKey.currentState!.validate()) return;

    final cfg = base.copyWith(
      name: _name.text.trim(),
      hostname: _hostname.text.trim(),
      address: _address.text.trim(),
      port: int.parse(_port.text.trim()),
      hasIpv6: _hasIpv6,
      username: _username.text.trim(),
      password: _password.text,
      skipVerification: _skipVerification,
      upstreamProtocol: _upstreamProtocol,
      antiDpi: _antiDpi,
      postQuantumGroupEnabled: _postQuantumGroupEnabled,
      customSni: _customSni.text.trim(),
      clientRandomPrefix: _clientRandomPrefix.text.trim(),
    );

    try {
      _dirty = false;
      await _configService.saveServerEntry(cfg);
      if (mounted) {
        setState(() => _editing = cfg);
        showAppSnackBar(context, AppLocalizations.of(context)!.settingsSaved,
            kind: SnackKind.success);
      }
      await _reload();
    } catch (e) {
      _dirty = true;
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context)!.settingsSaveError(e.toString()),
          kind: SnackKind.error,
        );
      }
    }
  }

  /// Reachability check on the open editor's address/port/hostname.
  Future<void> _testEditor() async {
    final address = _address.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (InternetAddress.tryParse(address) == null || port == null) {
      showAppSnackBar(context, 'Enter a valid IP address and port first.',
          kind: SnackKind.warning);
      return;
    }
    setState(() => _testingEditor = true);
    final result = await testServerConnection(
      address: address,
      port: port,
      hostname: _hostname.text.trim(),
    );
    if (!mounted) return;
    setState(() => _testingEditor = false);
    showAppSnackBar(
      context,
      result.message,
      kind: !result.ok
          ? SnackKind.error
          : result.certValid
              ? SnackKind.success
              : SnackKind.warning,
    );
  }

  Future<void> _switchTo(ServerConfig server) async {
    if (server.id == _activeId) return;
    await _configService.switchServer(server.id);
    if (_dirty) {
      // The listener skipped the reload; refresh the active marker only.
      final activeId = await _configService.getActiveServerId();
      if (mounted) setState(() => _activeId = activeId);
    }
  }

  Future<void> _addServer() async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    final config = await showDialog<ServerConfig>(
      context: context,
      builder: (ctx) => const AddServerDialog(),
    );
    if (config == null) return;
    final added = await _configService.addServerConfig(config);
    if (mounted) {
      showAppSnackBar(
          context, 'Server "${added.displayLabel}" added and selected',
          kind: SnackKind.success);
    }
  }

  Future<void> _deleteServer(ServerConfig server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete server'),
        content: Text(
          'Delete "${server.displayLabel}" from the list? '
          'Its saved password will be removed as well.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _dirty = false;
      await _configService.deleteServer(server.id);
    }
  }

  /// Apply the (validated) DNS upstreams immediately — shared by all servers.
  Future<void> _applyDns() async {
    if (_dnsApplying) return;
    _dnsApplying = true;
    try {
      final value = _dns.text.trim();
      final error = _validateDnsValue(value);
      if (mounted) setState(() => _dnsError = error);
      if (error != null) return;

      final current = await _configService.loadConfig();
      if (current.dns == value) return;
      await _configService.setGlobalDns(value);
      if (mounted) {
        showAppSnackBar(context, 'DNS updated — applies on the next connect',
            kind: SnackKind.success);
      }
    } finally {
      _dnsApplying = false;
    }
  }

  /// Append a preset upstream to the DNS list (deduplicated) and apply.
  void _addDnsPreset(String url) {
    final parts = _dns.text
        .split(RegExp(r'[\s,]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.contains(url)) {
      showAppSnackBar(
          context, AppLocalizations.of(context)!.settingsDnsPresetDuplicate);
      return;
    }
    parts.add(url);
    _dns.text = parts.join(', ');
    _applyDns();
  }

  String? _validateDnsValue(String value) {
    if (value.isEmpty) return AppLocalizations.of(context)!.settingsDnsError;
    for (final u
        in value.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty)) {
      final ok = RegExp(r'^(tcp|tls|https|quic|sdns)://\S+$').hasMatch(u) ||
          InternetAddress.tryParse(u) != null ||
          RegExp(r'^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$').hasMatch(u);
      if (!ok) return 'Invalid upstream: "$u"';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Selector<VpnService, VpnStatus>(
      selector: (_, vpn) => vpn.status,
      builder: (context, status, child) {
        final isConnected = status.isActive;

        if (_isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isConnected)
                    InfoBanner(
                      severity: BannerSeverity.warning,
                      message: AppLocalizations.of(context)!
                          .settingsWarningConnected,
                      margin: const EdgeInsets.only(bottom: 16),
                    ),
                  Row(
                    children: [
                      Text(
                        'Servers',
                        style:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      const Spacer(),
                      FilledButton.tonalIcon(
                        onPressed: isConnected ? null : _addServer,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Add server'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Click a server to make it active; the pencil edits it.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                  const SizedBox(height: 12),
                  ..._servers.map((s) => _buildServerCard(s, isConnected)),
                  const SizedBox(height: 16),
                  _buildSharedNetworkCard(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildServerCard(ServerConfig server, bool isConnected) {
    final theme = Theme.of(context);
    final isActive = server.id == _activeId;
    final isExpanded = _expandedId == server.id;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              isActive
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color:
                  isActive ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    server.displayLabel.isEmpty
                        ? '(unnamed)'
                        : server.displayLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Active',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            subtitle: Text(
              '${server.name.isNotEmpty ? '${server.hostname} · ' : ''}'
              '${server.address}:${server.port} · ${server.username}',
              overflow: TextOverflow.ellipsis,
            ),
            onTap: (isConnected || isActive) ? null : () => _switchTo(server),
            trailing: IconButton(
              tooltip: isExpanded ? 'Close editor' : 'Edit server',
              icon: Icon(isExpanded ? Icons.expand_less : Icons.edit_outlined,
                  size: 20),
              onPressed: () =>
                  isExpanded ? _closeEditor() : _openEditor(server),
            ),
          ),
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: _buildEditor(isConnected),
            ),
        ],
      ),
    );
  }

  Widget _buildEditor(bool isConnected) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1),
          const SizedBox(height: 16),
          _field(
            controller: _name,
            label: AppLocalizations.of(context)!.settingsServerName,
            icon: Icons.label_outline,
            enabled: !isConnected,
          ),
          const SizedBox(height: 16),
          _field(
            controller: _hostname,
            label: AppLocalizations.of(context)!.settingsHostname,
            icon: Icons.language,
            enabled: !isConnected,
            validator: (value) {
              final v = value?.trim() ?? '';
              if (v.isEmpty) {
                return AppLocalizations.of(context)!.settingsHostnameError;
              }
              if (v == 'vpn.example.com') {
                return 'Replace the placeholder with your server hostname';
              }
              if (v.contains(' ')) return 'Hostname cannot contain spaces';
              return null;
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _field(
                  controller: _address,
                  label: AppLocalizations.of(context)!.settingsAddress,
                  icon: Icons.public,
                  enabled: !isConnected,
                  validator: (value) {
                    final v = value?.trim() ?? '';
                    if (v.isEmpty) {
                      return AppLocalizations.of(context)!.settingsAddressError;
                    }
                    if (InternetAddress.tryParse(v) == null) {
                      return 'Enter a valid IPv4/IPv6 address';
                    }
                    return null;
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _field(
                  controller: _port,
                  label: AppLocalizations.of(context)!.settingsPort,
                  icon: Icons.pin,
                  enabled: !isConnected,
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    if (value?.isEmpty ?? true) {
                      return AppLocalizations.of(context)!
                          .settingsPortErrorEmpty;
                    }
                    final port = int.tryParse(value!);
                    if (port == null || port < 1 || port > 65535) {
                      return AppLocalizations.of(context)!
                          .settingsPortErrorInvalid;
                    }
                    return null;
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _field(
            controller: _username,
            label: AppLocalizations.of(context)!.settingsUsername,
            icon: Icons.person,
            enabled: !isConnected,
            validator: (value) {
              final v = value?.trim() ?? '';
              if (v.isEmpty) {
                return AppLocalizations.of(context)!.settingsUsernameError;
              }
              if (v == 'your-username') {
                return 'Replace the placeholder with your VPN username';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          _field(
            controller: _password,
            label: AppLocalizations.of(context)!.settingsPassword,
            icon: Icons.lock,
            enabled: !isConnected,
            obscureText: !_passwordVisible,
            validator: (value) => value?.isEmpty ?? true
                ? AppLocalizations.of(context)!.settingsPasswordError
                : null,
            suffixIcon: IconButton(
              icon: Icon(
                _passwordVisible ? Icons.visibility_off : Icons.visibility,
              ),
              onPressed: () {
                setState(() => _passwordVisible = !_passwordVisible);
              },
            ),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            title: Text(AppLocalizations.of(context)!.settingsSectionAdvanced),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: [
              _dropdown(
                value: _upstreamProtocol,
                label: AppLocalizations.of(context)!.settingsProtocol,
                icon: Icons.settings_ethernet,
                enabled: !isConnected,
                items: const ['http2', 'http3'],
                onChanged: (value) {
                  _markDirty();
                  setState(() => _upstreamProtocol = value!);
                },
              ),
              const SizedBox(height: 16),
              _field(
                controller: _clientRandomPrefix,
                label: 'Client random prefix (optional)',
                icon: Icons.fingerprint,
                enabled: !isConnected,
                helperText: AppLocalizations.of(context)!.settingsPrefixHelper,
              ),
              const SizedBox(height: 16),
              _field(
                controller: _customSni,
                label: AppLocalizations.of(context)!.settingsCustomSni,
                icon: Icons.security,
                enabled: !isConnected,
              ),
              _switch(
                title: AppLocalizations.of(context)!.settingsIpv6,
                value: _hasIpv6,
                enabled: !isConnected,
                onChanged: (value) {
                  _markDirty();
                  setState(() => _hasIpv6 = value);
                },
              ),
              _switch(
                title: AppLocalizations.of(context)!.settingsSkipVerification,
                value: _skipVerification,
                enabled: !isConnected,
                onChanged: (value) {
                  _markDirty();
                  setState(() => _skipVerification = value);
                },
              ),
              if (_skipVerification)
                const InfoBanner(
                  severity: BannerSeverity.error,
                  message:
                      'Disabling certificate verification accepts any server '
                      'certificate, exposing all tunneled traffic to interception '
                      '(man-in-the-middle). Only enable this for debugging.',
                  margin: EdgeInsets.only(bottom: 8),
                ),
              _switch(
                title: AppLocalizations.of(context)!.settingsAntiDpi,
                value: _antiDpi,
                enabled: !isConnected,
                onChanged: (value) {
                  _markDirty();
                  setState(() => _antiDpi = value);
                },
              ),
              _switch(
                title: AppLocalizations.of(context)!.settingsPostQuantum,
                subtitle: AppLocalizations.of(context)!.settingsPostQuantumHint,
                value: _postQuantumGroupEnabled,
                enabled: !isConnected,
                onChanged: (value) {
                  _markDirty();
                  setState(() => _postQuantumGroupEnabled = value);
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: (isConnected || _servers.length <= 1)
                    ? null
                    : () => _deleteServer(_editing!),
                icon: Icon(Icons.delete_outline,
                    size: 18, color: Theme.of(context).colorScheme.error),
                label: Text(
                  'Delete',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _testingEditor ? null : _testEditor,
                icon: _testingEditor
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: Text(_testingEditor ? 'Testing…' : 'Test'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: (!isConnected && _dirty) ? _saveEditor : null,
                icon: const Icon(Icons.save, size: 18),
                label: Text(_dirty
                    ? AppLocalizations.of(context)!.settingsSave
                    : 'Saved'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSharedNetworkCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.router, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Shared network settings',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Apply to every server · take effect on the next connect',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _dns,
              focusNode: _dnsFocus,
              onFieldSubmitted: (_) => _applyDns(),
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context)!.settingsDns,
                helperText: AppLocalizations.of(context)!.settingsDnsHelper,
                helperMaxLines: 3,
                errorText: _dnsError,
                errorMaxLines: 2,
                prefixIcon: const Icon(Icons.router),
                suffixIcon: PopupMenuButton<String>(
                  tooltip:
                      AppLocalizations.of(context)!.settingsDnsPresetTooltip,
                  icon: const Icon(Icons.playlist_add),
                  onSelected: _addDnsPreset,
                  itemBuilder: (context) => [
                    for (final (name, url) in _dnsPresets)
                      PopupMenuItem<String>(
                        value: url,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(name),
                            Text(
                              url,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color:
                                        Theme.of(context).colorScheme.outline,
                                  ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool enabled = true,
    bool obscureText = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    Widget? suffixIcon,
    String? helperText,
  }) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      onChanged: (_) => _markDirty(),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        helperMaxLines: 3,
        prefixIcon: Icon(icon),
        suffixIcon: suffixIcon,
        isDense: true,
      ),
    );
  }

  Widget _dropdown({
    required String value,
    required String label,
    required IconData icon,
    required List<String> items,
    required void Function(String?) onChanged,
    bool enabled = true,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        isDense: true,
      ),
      items: items
          .map((item) => DropdownMenuItem(value: item, child: Text(item)))
          .toList(),
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _switch({
    required String title,
    String? subtitle,
    required bool value,
    required void Function(bool) onChanged,
    bool enabled = true,
  }) {
    return SwitchListTile(
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: enabled ? onChanged : null,
      contentPadding: EdgeInsets.zero,
      dense: true,
    );
  }
}

/// "Add server" dialog — nothing is committed until the user confirms real
/// values.
class AddServerDialog extends StatefulWidget {
  const AddServerDialog({super.key});

  @override
  State<AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<AddServerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _hostname = TextEditingController();
  final _address = TextEditingController();
  final _port = TextEditingController(text: '443');
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _passwordVisible = false;

  bool _testing = false;
  ConnectionTestResult? _testResult;

  @override
  void dispose() {
    _name.dispose();
    _hostname.dispose();
    _address.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Reachability check on the address/port/hostname — no credentials needed.
  Future<void> _test() async {
    final address = _address.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (InternetAddress.tryParse(address) == null || port == null) {
      setState(() => _testResult = const ConnectionTestResult(
          false, false, 'Enter a valid IP address and port first.'));
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await testServerConnection(
      address: address,
      port: port,
      hostname: _hostname.text.trim(),
    );
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      ServerConfig(
        name: _name.text.trim(),
        hostname: _hostname.text.trim(),
        address: _address.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _username.text.trim(),
        password: _password.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label, {Widget? suffix}) => InputDecoration(
          labelText: label,
          suffixIcon: suffix,
          isDense: true,
        );

    return AlertDialog(
      title: const Text('Add server'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: deco('Name (optional)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _hostname,
                decoration: deco('Hostname'),
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) return 'Enter the server hostname';
                  if (s.contains(' ')) return 'No spaces allowed';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _address,
                      decoration: deco('IP address'),
                      validator: (v) {
                        final s = v?.trim() ?? '';
                        if (s.isEmpty) return 'Enter the IP';
                        if (InternetAddress.tryParse(s) == null) {
                          return 'Invalid IP';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _port,
                      decoration: deco('Port'),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final port = int.tryParse(v?.trim() ?? '');
                        if (port == null || port < 1 || port > 65535) {
                          return '1-65535';
                        }
                        return null;
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _username,
                decoration: deco('VPN username'),
                validator: (v) =>
                    (v?.trim().isEmpty ?? true) ? 'Enter the username' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: !_passwordVisible,
                onFieldSubmitted: (_) => _submit(),
                decoration: deco(
                  'VPN password',
                  suffix: IconButton(
                    icon: Icon(_passwordVisible
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _passwordVisible = !_passwordVisible),
                  ),
                ),
                validator: (v) =>
                    (v?.isEmpty ?? true) ? 'Enter the password' : null,
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(_testing ? 'Testing…' : 'Test connection'),
                ),
              ),
              if (_testResult != null) _buildTestResult(_testResult!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }

  Widget _buildTestResult(ConnectionTestResult r) {
    final scheme = Theme.of(context).colorScheme;
    final (Color color, IconData icon) = !r.ok
        ? (scheme.error, Icons.error_outline)
        : r.certValid
            ? (Colors.green, Icons.check_circle_outline)
            : (Colors.orange, Icons.warning_amber);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              r.message,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

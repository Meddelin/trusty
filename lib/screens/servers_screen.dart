import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/server_config.dart';
import '../models/vpn_status.dart';
import '../services/config_service.dart';
import '../services/vpn_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import '../utils/connection_test.dart';
import '../widgets/app_switch.dart';
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';

/// The mono fallback list, built ONCE. `kMonoFontStack.sublist(1)` allocates a
/// new list on every call, and `_mono` is called dozens of times per build of
/// this screen (every field value, every label, every segment).
final List<String> _monoFallback = kMonoFontStack.sublist(1);

/// Monospaced style for values the user reads as data (hostnames, addresses,
/// ports, prefixes, protocol names). Prose stays in the UI face, and there is
/// no `letterSpacing` knob: tracked mono is not a heading style here.
TextStyle _mono({double size = 12.5, Color? color, FontWeight? weight}) {
  return TextStyle(
    fontFamily: kMonoFontStack.first,
    fontFamilyFallback: _monoFallback,
    fontSize: size,
    color: color,
    fontWeight: weight,
  );
}

/// Section and island headings: sans, sentence case, no tracking. A tiny
/// letter-spaced mono word in caps is the house style of machine-generated
/// dashboards and is harder to read; mono stays reserved for values the user
/// reads as data, where character alignment is the point.
TextStyle _sectionHeading(ThemeData theme) => TextStyle(
  fontSize: 12.5,
  fontWeight: FontWeight.w600,
  color: theme.colorScheme.onSurfaceVariant,
);

/// Server management as a LIST of islands, not a stacked form: the main column
/// holds one card per server (click makes it active, the pencil opens an inline
/// editor laid out as a grid), and a 240px side column holds the app-wide
/// settings shared by every server: the connection mode and the DNS upstreams.
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

  // These four drive ONE control each, so they are notifiers rather than
  // setState fields: flipping them used to rebuild the whole screen — the
  // server ListView, every card and the settings island — to repaint a button
  // label or an eye glyph.
  final ValueNotifier<bool> _dirty = ValueNotifier(false);
  final ValueNotifier<bool> _passwordVisible = ValueNotifier(false);
  final ValueNotifier<bool> _testingEditor = ValueNotifier(false);

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
  final ValueNotifier<String?> _dnsError = ValueNotifier(null);
  bool _dnsApplying = false;

  // App-wide settings that moved off the old Settings tab and joined the
  // shared-settings island: the connection mode with its SOCKS5 port. The
  // close-window behaviour went to the navigation rail's footer instead.
  /// 'tun' (default) or 'socks5'.
  String _connectionMode = 'tun';
  final TextEditingController _socksPort = TextEditingController();
  final ValueNotifier<String?> _socksPortError = ValueNotifier(null);

  /// Persisting the proxy port goes through the keystore-backed config
  /// (read-modify-write plus a listener-driven reload), so a keystroke-per-
  /// write turns typing into a stutter. The settled value is written instead —
  /// and always written: a pending timer is flushed in [dispose].
  Timer? _socksPortWrite;

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
    _flushSocksPort();
    _configService.removeListener(_onConfigChanged);
    _dnsFocus.dispose();
    for (final n in [_dirty, _passwordVisible, _testingEditor]) {
      n.dispose();
    }
    _dnsError.dispose();
    _socksPortError.dispose();
    for (final c in [
      _name,
      _hostname,
      _address,
      _port,
      _username,
      _password,
      _customSni,
      _clientRandomPrefix,
      _dns,
      _socksPort,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onConfigChanged() {
    if (!mounted) return;
    // Never clobber an open, edited form from external notifications — but
    // the app-wide settings beside the list are not part of that form, so they
    // still follow a change made anywhere else.
    if (_dirty.value) {
      _reloadAppSettings();
    } else {
      _reload();
    }
  }

  bool _reloading = false;
  bool _reloadAgain = false;

  /// Coalesced reload. One save notifies its listeners AND is followed by an
  /// explicit `await _reload()`, and a switch/delete notifies more than once —
  /// each pass costs a `loadConfig()`, which is two secure-storage round trips
  /// plus a JSON decode, and ends in a full-screen `setState`. Overlapping
  /// requests now collapse into a single trailing pass.
  Future<void> _reload() async {
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _reloadAgain = false;
        await _loadAll();
      } while (_reloadAgain && mounted);
    } finally {
      _reloading = false;
    }
  }

  Future<void> _loadAll() async {
    final servers = await _configService.loadServers();
    final activeId = await _configService.getActiveServerId();
    final config = await _configService.loadConfig();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _servers = servers;
      _activeId = activeId;
      if (!_dnsFocus.hasFocus) {
        _dns.text = config.dns;
        _dnsError.value = null;
      }
      _applyAppSettings(config, prefs);
      // Editor for a deleted server closes itself.
      if (_expandedId != null && !servers.any((s) => s.id == _expandedId)) {
        _expandedId = null;
        _editing = null;
        _dirty.value = false;
      }
      _isLoading = false;
    });
  }

  /// Re-sync only the app-wide controls (mode, proxy port, close action).
  Future<void> _reloadAppSettings() async {
    final config = await _configService.loadConfig();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _applyAppSettings(config, prefs));
  }

  /// Must be called from inside setState.
  void _applyAppSettings(ServerConfig config, SharedPreferences prefs) {
    _connectionMode = config.connectionMode;
    // Don't fight the user's cursor: only sync the field when the stored
    // port actually differs from what's typed.
    if (int.tryParse(_socksPort.text) != config.socksPort) {
      _socksPort.text = config.socksPort.toString();
      // The rejected text is gone, so the complaint about it goes too —
      // otherwise the stored, valid port shows up under a red error.
      _socksPortError.value = null;
    }
  }

  void _onSocksPortChanged(String value) {
    final port = int.tryParse(value);
    final valid = port != null && port >= 1 && port <= 65535;
    // Error text repaints the field alone — it used to setState the screen.
    _socksPortError.value = valid
        ? null
        : AppLocalizations.of(context)!.settingsSocksPortError;
    _socksPortWrite?.cancel();
    // Only valid values are persisted; the error text stays until fixed.
    if (valid) {
      _socksPortWrite = Timer(
        const Duration(milliseconds: 350),
        () => _configService.setGlobalSocksPort(port),
      );
    }
  }

  /// Write a pending proxy port now, so leaving the screen never loses it.
  /// [ConfigService] outlives this widget, so the write may outlive it too.
  void _flushSocksPort() {
    if (!(_socksPortWrite?.isActive ?? false)) return;
    _socksPortWrite!.cancel();
    final port = int.tryParse(_socksPort.text);
    if (port != null && port >= 1 && port <= 65535) {
      _configService.setGlobalSocksPort(port);
    }
  }

  void _markDirty() => _dirty.value = true;

  Future<bool> _confirmDiscard() async {
    if (!_dirty.value) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard unsaved changes?'),
        content: const Text(
          'You have unsaved changes to this server. Leaving now will lose them.',
        ),
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
      _dirty.value = false;
      return true;
    }
    return false;
  }

  Future<void> _openEditor(ServerConfig server) async {
    if (_expandedId == server.id) return;
    if (!await _confirmDiscard()) return;
    final full = await _configService.loadServerEntry(server.id);
    if (full == null || !mounted) return;
    _dirty.value = false;
    _passwordVisible.value = false;
    // Per-editor transient state never carries over to the next editor.
    _testingEditor.value = false;
    setState(() {
      _expandedId = server.id;
      _editing = full;
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
    _testingEditor.value = false;
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
      _dirty.value = false;
      await _configService.saveServerEntry(cfg);
      if (mounted) {
        setState(() => _editing = cfg);
        showAppSnackBar(
          context,
          AppLocalizations.of(context)!.settingsSaved,
          kind: SnackKind.success,
        );
      }
      await _reload();
    } catch (e) {
      _dirty.value = true;
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
    final probedId = _expandedId;
    final address = _address.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (InternetAddress.tryParse(address) == null || port == null) {
      showAppSnackBar(
        context,
        'Enter a valid IP address and port first.',
        kind: SnackKind.warning,
      );
      return;
    }
    _testingEditor.value = true;
    final result = await testServerConnection(
      address: address,
      port: port,
      hostname: _hostname.text.trim(),
      // A filtering server answers only handshakes carrying this prefix, and
      // the probe cannot send it — so silence is the expected reply, not a
      // fault.
      hasFilteringPrefix: _clientRandomPrefix.text.trim().isNotEmpty,
    );
    if (!mounted) return;
    // The spinner belongs to the editor that started the probe. If that editor
    // was closed or replaced meanwhile it already cleared the flag, and this
    // late reply must not touch the editor now on screen.
    if (_expandedId == probedId) _testingEditor.value = false;
    showAppSnackBar(
      context,
      result.message,
      kind: !result.ok
          ? SnackKind.error
          : result.filtered || result.certValid
          ? SnackKind.success
          : SnackKind.warning,
    );
  }

  Future<void> _switchTo(ServerConfig server) async {
    if (server.id == _activeId) return;
    await _configService.switchServer(server.id);
    if (_dirty.value) {
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
        context,
        'Server "${added.displayLabel}" added and selected',
        kind: SnackKind.success,
      );
    }
  }

  Future<void> _deleteServer(ServerConfig server) async {
    final isLast = _servers.length <= 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete server'),
        content: Text(
          isLast
              // The app always keeps one entry, so the last one is replaced
              // rather than removed — say so instead of implying an empty list.
              ? 'Delete "${server.displayLabel}"? Its saved password will be '
                    'removed, and the list will be reset to a blank server.'
              : 'Delete "${server.displayLabel}" from the list? '
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
      _dirty.value = false;
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
      // Repaints the DNS field, not the screen.
      if (mounted) _dnsError.value = error;
      if (error != null) return;

      final current = await _configService.loadConfig();
      if (current.dns == value) return;
      await _configService.setGlobalDns(value);
      if (mounted) {
        showAppSnackBar(
          context,
          'DNS updated. Applies on the next connect',
          kind: SnackKind.success,
        );
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
        context,
        AppLocalizations.of(context)!.settingsDnsPresetDuplicate,
      );
      return;
    }
    parts.add(url);
    _dns.text = parts.join(', ');
    _applyDns();
  }

  String? _validateDnsValue(String value) {
    if (value.isEmpty) return AppLocalizations.of(context)!.settingsDnsError;
    for (final u in value.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty)) {
      final ok =
          RegExp(r'^(tcp|tls|https|quic|sdns)://\S+$').hasMatch(u) ||
          InternetAddress.tryParse(u) != null ||
          RegExp(r'^\d{1,3}(\.\d{1,3}){3}:\d{1,5}$').hasMatch(u);
      if (!ok) return 'Invalid upstream: "$u"';
    }
    return null;
  }

  // ---------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    // The whole screen depends on ONE bit of VpnService — whether a tunnel is
    // up — so that is what is selected. Selecting the status enum rebuilt the
    // list and both islands on every disconnected→connecting→connected step;
    // the bool changes once per transition.
    return Selector<VpnService, bool>(
      selector: (_, vpn) => vpn.status.isActive,
      builder: (context, isConnected, child) {
        final theme = Theme.of(context);
        final l10n = AppLocalizations.of(context)!;

        if (_isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header island: title left, the one primary action right.
              Row(
                children: [
                  Text(
                    l10n.navServers,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
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
              if (isConnected)
                InfoBanner(
                  severity: BannerSeverity.warning,
                  message: l10n.settingsWarningConnected,
                  margin: const EdgeInsets.only(top: 14),
                ),
              const SizedBox(height: 14),
              // Main column of server islands + the 240px app-settings column.
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: _servers.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 14),
                        itemBuilder: (context, i) =>
                            _buildServerCard(_servers[i], isConnected),
                      ),
                    ),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 240,
                      child: _buildAppSettingsCard(isConnected),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------ server card

  Widget _buildServerCard(ServerConfig server, bool isConnected) {
    final theme = Theme.of(context);
    final isActive = server.id == _activeId;
    final isExpanded = _expandedId == server.id;
    final selectable = !isConnected && !isActive;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Picking a server is the card's own gesture, so the whole header
          // row answers the pointer: a flat tint on hover, stronger while
          // pressed, and the app's focus ring when a keyboard lands on it.
          // The bottom corners follow the card's only while the row IS the
          // card; with the editor open the row's underside is a straight
          // edge against the form below it.
          _PointerSurface(
            onTap: selectable ? () => _switchTo(server) : null,
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(14),
              bottom: Radius.circular(isExpanded ? 0 : 14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    isActive
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isActive
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                server.displayLabel.isEmpty
                                    ? '(unnamed)'
                                    : server.displayLabel,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (isActive) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary.withValues(
                                    alpha: 0.14,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  'Active',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 0.3,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${server.name.isNotEmpty ? '${server.hostname} · ' : ''}'
                          '${server.address}:${server.port} · ${server.username}',
                          overflow: TextOverflow.ellipsis,
                          style: _mono(
                            size: 12,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 28×28 with a 20px glyph, as the artboard draws it — the
                  // box pins the layout size (IconButton's tap target is 48),
                  // the theme supplies padding, radius and colour. Open editor
                  // = the "selected" treatment: tonal fill, brighter glyph.
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      tooltip: isExpanded ? 'Close editor' : 'Edit server',
                      iconSize: 20,
                      // A bare `ButtonStyle`, not `IconButton.styleFrom`:
                      // `styleFrom` derives an `overlayColor` from whatever
                      // `foregroundColor` it is handed (Material's 8/10/10
                      // alphas), which would quietly override the theme's
                      // shared pointer overlay on this one button. Leaving
                      // `overlayColor` and `side` unset lets both fall
                      // through to `iconButtonTheme`.
                      style: isExpanded
                          ? ButtonStyle(
                              backgroundColor: WidgetStatePropertyAll(
                                theme.colorScheme.secondaryContainer,
                              ),
                              foregroundColor: WidgetStatePropertyAll(
                                theme.colorScheme.onSecondaryContainer,
                              ),
                            )
                          : null,
                      icon: Icon(
                        isExpanded ? Icons.expand_less : Icons.edit_outlined,
                      ),
                      onPressed: () =>
                          isExpanded ? _closeEditor() : _openEditor(server),
                    ),
                  ),
                ],
              ),
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

  // ---------------------------------------------------------------- editor

  /// The inline editor. Every cell is a fixed-height label row above its
  /// input, so the inputs sit on one baseline no matter how long the label is.
  Widget _buildEditor(bool isConnected) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final enabled = !isConnected;

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // dividerTheme already supplies colour, thickness and 1px space.
          const Divider(),
          const SizedBox(height: 14),
          _gridRow([
            _cell(
              flex: 100,
              label: l10n.settingsServerName,
              child: _input(controller: _name, enabled: enabled),
            ),
            _cell(
              flex: 125,
              label: l10n.settingsHostname,
              child: _input(
                controller: _hostname,
                enabled: enabled,
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return l10n.settingsHostnameError;
                  if (v == 'vpn.example.com') {
                    return 'Replace the placeholder with your server hostname';
                  }
                  if (v.contains(' ')) return 'Hostname cannot contain spaces';
                  return null;
                },
              ),
            ),
            _cell(
              flex: 95,
              label: l10n.settingsUsername,
              child: _input(
                controller: _username,
                enabled: enabled,
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return l10n.settingsUsernameError;
                  if (v == 'your-username') {
                    return 'Replace the placeholder with your VPN username';
                  }
                  return null;
                },
              ),
            ),
          ]),
          const SizedBox(height: 10),
          _gridRow([
            _cell(
              flex: 100,
              label: l10n.settingsAddress,
              child: _input(
                controller: _address,
                enabled: enabled,
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return l10n.settingsAddressError;
                  if (InternetAddress.tryParse(v) == null) {
                    return 'Enter a valid IPv4/IPv6 address';
                  }
                  return null;
                },
              ),
            ),
            _cell(
              flex: 125,
              label: l10n.settingsPort,
              child: _input(
                controller: _port,
                enabled: enabled,
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value?.isEmpty ?? true) {
                    return l10n.settingsPortErrorEmpty;
                  }
                  final port = int.tryParse(value!);
                  if (port == null || port < 1 || port > 65535) {
                    return l10n.settingsPortErrorInvalid;
                  }
                  return null;
                },
              ),
            ),
            _cell(
              flex: 95,
              label: l10n.settingsPassword,
              // Revealing the password repaints this one field; it used to
              // setState the screen, rebuilding every server card with it.
              child: ValueListenableBuilder<bool>(
                valueListenable: _passwordVisible,
                builder: (context, visible, _) => _input(
                  controller: _password,
                  enabled: enabled,
                  obscureText: !visible,
                  validator: (value) => value?.isEmpty ?? true
                      ? l10n.settingsPasswordError
                      : null,
                  suffixIcon: IconButton(
                    tooltip: visible ? 'Hide password' : 'Show password',
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    icon: Icon(
                      visible ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => _passwordVisible.value = !visible,
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          _gridRow([
            _cell(
              flex: 100,
              label: l10n.settingsProtocol,
              child: SizedBox(
                height: 36,
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  style: _segmentStyle(mono: true),
                  segments: const [
                    ButtonSegment(value: 'http2', label: Text('http2')),
                    ButtonSegment(value: 'http3', label: Text('http3')),
                  ],
                  selected: {_upstreamProtocol},
                  onSelectionChanged: enabled
                      ? (values) {
                          _markDirty();
                          setState(() => _upstreamProtocol = values.first);
                        }
                      : null,
                ),
              ),
            ),
            _cell(
              flex: 125,
              label: 'Filtering prefix (optional)',
              hint: l10n.settingsPrefixHelper,
              child: _input(
                controller: _clientRandomPrefix,
                enabled: enabled,
                // The value lands in the generated TOML — accept only the
                // hex prefix[/mask] format the CLI understands, so a pasted
                // config line or free text is rejected up front.
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty ||
                      RegExp(r'^[0-9a-fA-F]+(/[0-9a-fA-F]+)?$').hasMatch(v)) {
                    return null;
                  }
                  return 'Hex prefix or prefix/mask only (e.g. 24503c49/ffffffff)';
                },
              ),
            ),
            _cell(
              flex: 95,
              label: l10n.settingsCustomSni,
              child: _input(controller: _customSni, enabled: enabled),
            ),
          ]),
          const SizedBox(height: 6),
          _buildAdvanced(enabled),
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                // Deleting the only server is allowed: the service replaces
                // it with a blank entry, which is what "start over" means
                // here. Only an active connection blocks it.
                onPressed: isConnected ? null : () => _deleteServer(_editing!),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(
                    color: theme.colorScheme.error.withValues(alpha: 0.45),
                  ),
                ),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Delete'),
              ),
              const Spacer(),
              // Both of these track one flag each, so each one rebuilds
              // alone: running a reachability test, and the first keystroke
              // that dirties the form, used to rebuild the entire screen.
              ValueListenableBuilder<bool>(
                valueListenable: _testingEditor,
                builder: (context, testing, _) => OutlinedButton.icon(
                  onPressed: testing ? null : _testEditor,
                  icon: testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering, size: 18),
                  label: Text(testing ? 'Testing…' : 'Test'),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: _dirty,
                builder: (context, dirty, _) => FilledButton.icon(
                  onPressed: (!isConnected && dirty) ? _saveEditor : null,
                  icon: Icon(dirty ? Icons.save : Icons.check, size: 18),
                  label: Text(dirty ? l10n.settingsSave : 'Saved'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The four security switches, still an expander, laid out two per row.
  /// The certificate-verification warning stays visible below them whenever
  /// that switch is on — it is state, not explanation.
  Widget _buildAdvanced(bool enabled) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return ExpansionTile(
      title: Text(
        l10n.settingsSectionAdvanced,
        style: _sectionHeading(theme),
      ),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
      visualDensity: VisualDensity.compact,
      iconColor: theme.colorScheme.onSurfaceVariant,
      collapsedIconColor: theme.colorScheme.onSurfaceVariant,
      children: [
        Row(
          children: [
            Expanded(
              child: _switchRow(
                title: l10n.settingsIpv6,
                value: _hasIpv6,
                enabled: enabled,
                onChanged: (value) {
                  _markDirty();
                  setState(() => _hasIpv6 = value);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _switchRow(
                title: l10n.settingsSkipVerification,
                value: _skipVerification,
                enabled: enabled,
                onChanged: (value) {
                  _markDirty();
                  setState(() => _skipVerification = value);
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _switchRow(
                title: l10n.settingsAntiDpi,
                value: _antiDpi,
                enabled: enabled,
                onChanged: (value) {
                  _markDirty();
                  setState(() => _antiDpi = value);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _switchRow(
                title: l10n.settingsPostQuantum,
                hint: l10n.settingsPostQuantumHint,
                value: _postQuantumGroupEnabled,
                enabled: enabled,
                onChanged: (value) {
                  _markDirty();
                  setState(() => _postQuantumGroupEnabled = value);
                },
              ),
            ),
          ],
        ),
        if (_skipVerification)
          const InfoBanner(
            severity: BannerSeverity.error,
            message:
                'Disabling certificate verification accepts any server '
                'certificate, exposing all tunneled traffic to interception '
                '(man-in-the-middle). Only enable this for debugging.',
            margin: EdgeInsets.only(top: 8),
          ),
      ],
    );
  }

  // ------------------------------------------------------ app-wide settings

  /// The 240px side island: the settings every server shares. Connection mode
  /// (with its proxy port), the DNS upstreams, and what the window's X does.
  Widget _buildAppSettingsCard(bool isConnected) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.settingsAppSection, style: _sectionHeading(theme)),
              const SizedBox(height: 6),
              Text(
                l10n.settingsAppSectionSubtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: dimTextOf(theme.colorScheme),
                ),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 14),
              _buildConnectionMode(isConnected),
              const SizedBox(height: 14),
              _buildDns(),
              const SizedBox(height: 14),
              const Divider(),
              const SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }

  /// TUN/SOCKS5 switcher plus the proxy-port field (SOCKS5 only). Both are
  /// locked while a connection is active, exactly as on the old Settings tab.
  /// The per-mode description sits behind the label's hint; the locked notice
  /// is state the user must see, so it stays on screen.
  Widget _buildConnectionMode(bool locked) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _labelRow(
          l10n.settingsConnectionMode,
          hint: _connectionMode == 'socks5'
              ? l10n.settingsConnectionModeSocksHint
              : l10n.settingsConnectionModeTunHint,
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 34,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            style: _segmentStyle(fontSize: 11.5),
            segments: [
              ButtonSegment(
                value: 'tun',
                label: Text(
                  l10n.settingsConnectionModeTun,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ButtonSegment(
                value: 'socks5',
                label: Text(
                  l10n.settingsConnectionModeSocks,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            selected: {_connectionMode},
            onSelectionChanged: locked
                ? null
                : (modes) {
                    final mode = modes.first;
                    setState(() => _connectionMode = mode);
                    // The port field exists in SOCKS5 mode only: leaving the
                    // mode unmounts it, and its validation message must not
                    // outlive the text that earned it.
                    _socksPortError.value = null;
                    _configService.setGlobalConnectionMode(mode);
                  },
          ),
        ),
        if (locked) ...[
          const SizedBox(height: 6),
          Text(
            l10n.settingsConnectionModeLocked,
            style: theme.textTheme.bodySmall?.copyWith(
              color: dimTextOf(theme.colorScheme),
            ),
          ),
        ],
        if (_connectionMode == 'socks5') ...[
          const SizedBox(height: 14),
          _labelRow(l10n.settingsSocksPort, hint: l10n.settingsSocksPortHelper),
          const SizedBox(height: 6),
          ValueListenableBuilder<String?>(
            valueListenable: _socksPortError,
            builder: (context, error, _) => TextField(
              controller: _socksPort,
              enabled: !locked,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: _mono(color: theme.colorScheme.onSurface),
              decoration: InputDecoration(
                errorText: error,
                errorMaxLines: 2,
                errorStyle: const TextStyle(fontSize: 11),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
              ),
              onChanged: _onSocksPortChanged,
            ),
          ),
        ],
      ],
    );
  }

  /// The shared DNS upstream list. The preset picker sits on the label row,
  /// the way the artboard draws it — it appends, it never replaces.
  Widget _buildDns() {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _labelRow(l10n.settingsDns, hint: l10n.settingsDnsHelper),
            ),
            const SizedBox(width: 8),
            // The artboard draws the preset picker as a tonal square with an
            // accent glyph, not a bare icon — it is the island's one action.
            SizedBox(
              width: 28,
              height: 28,
              child: PopupMenuButton<String>(
                tooltip: l10n.settingsDnsPresetTooltip,
                padding: EdgeInsets.zero,
                iconSize: 18,
                // As on the editor's pencil: only the two colours the theme
                // cannot know, so the shared overlay and focus ring survive.
                style: ButtonStyle(
                  backgroundColor: WidgetStatePropertyAll(
                    theme.colorScheme.secondaryContainer,
                  ),
                  foregroundColor: WidgetStatePropertyAll(
                    theme.colorScheme.primary,
                  ),
                ),
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
                            style: _mono(
                              size: 10.5,
                              color: dimTextOf(theme.colorScheme),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ValueListenableBuilder<String?>(
          valueListenable: _dnsError,
          builder: (context, error, _) => TextFormField(
            controller: _dns,
            focusNode: _dnsFocus,
            onFieldSubmitted: (_) => _applyDns(),
            maxLines: 2,
            minLines: 1,
            style: _mono(color: theme.colorScheme.onSurface),
            decoration: InputDecoration(
              errorText: error,
              errorMaxLines: 3,
              errorStyle: const TextStyle(fontSize: 11),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
            ),
          ),
        ),
      ],
    );
  }


  // ------------------------------------------------------------- primitives

  /// One row of grid cells, aligned at the top so a cell carrying a validation
  /// error grows downwards without pushing its neighbours' inputs off-line.
  Widget _gridRow(List<Widget> cells) {
    final children = <Widget>[];
    for (var i = 0; i < cells.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 12));
      children.add(cells[i]);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// A grid cell: a FIXED-HEIGHT label row above the control. The fixed height
  /// is what keeps every input on one baseline whatever the label's length.
  Widget _cell({
    required int flex,
    required String label,
    String? hint,
    required Widget child,
  }) {
    return Expanded(
      flex: flex,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: 18, child: _labelRow(label, hint: hint)),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }

  /// A field label with its explanation tucked behind an info glyph.
  Widget _labelRow(String label, {String? hint}) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: hint,
            child: Icon(
              Icons.info_outline,
              size: 15,
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ],
    );
  }

  /// Editor input: no floating label (the cell carries it), mono value,
  /// inline validation error underneath.
  Widget _input({
    required TextEditingController controller,
    bool enabled = true,
    bool obscureText = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    Widget? suffixIcon,
  }) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      onChanged: (_) => _markDirty(),
      style: _mono(color: Theme.of(context).colorScheme.onSurface),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        suffixIcon: suffixIcon,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 30,
          minHeight: 30,
        ),
        errorMaxLines: 3,
        errorStyle: const TextStyle(fontSize: 11),
      ),
    );
  }

  /// A compact switch row: label (optionally hinted) left, switch right.
  ///
  /// `MergeSemantics` folds the label, its hint and the toggle into ONE
  /// accessible node — the switch is what carries the tap action, and a
  /// tappable node whose name sits in a sibling `Text` has no name at all.
  /// Merging is also what a screen-reader user wants to hear: "Enable IPv6,
  /// on", not two separate items.
  Widget _switchRow({
    required String title,
    String? hint,
    required bool value,
    required void Function(bool) onChanged,
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(width: 6),
                  Tooltip(
                    message: hint,
                    child: Icon(
                      Icons.info_outline,
                      size: 15,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 32×18 with a 14px thumb, against the Material switch's 52×32 —
          // no `materialTapTargetSize` to shrink, because it never claimed a
          // 48px touch target in the first place.
          AppSwitch(value: value, onChanged: enabled ? onChanged : null),
        ],
      ),
    );
  }

  /// Local geometry for the three segmented controls. Shape, borders and the
  /// selected colours all come from `segmentedButtonTheme`; only what the
  /// theme cannot know is set here — the shrunk tap target (Material would
  /// claim 48px and overflow the 34px row), and the tighter horizontal
  /// padding and type that let a three-way control fit the 240px side column.
  /// `mono: true` is the artboard's rule that segment VALUES (http2/http3,
  /// ask/minimize/exit) are data, while the connection mode is prose.
  ButtonStyle _segmentStyle({double fontSize = 12, bool mono = false}) {
    return ButtonStyle(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 6),
      ),
      textStyle: WidgetStatePropertyAll(
        mono
            ? _mono(size: fontSize, weight: FontWeight.w500)
            : TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
      ),
    );
  }
}

/// "Add server" dialog — nothing is committed until the user confirms real
/// values. Grouped into two sections, Server and Credentials, with the label
/// above every field.
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
      setState(
        () => _testResult = const ConnectionTestResult(
          false,
          false,
          'Enter a valid IP address and port first.',
        ),
      );
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
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return AlertDialog(
      title: const Text('Add server'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _section('Server'),
                const SizedBox(height: 10),
                _labeled(
                  'Name (optional)',
                  TextFormField(
                    controller: _name,
                    autofocus: true,
                    style: _mono(color: theme.colorScheme.onSurface),
                    decoration: _deco(),
                  ),
                ),
                const SizedBox(height: 12),
                _labeled(
                  l10n.settingsHostname,
                  TextFormField(
                    controller: _hostname,
                    style: _mono(color: theme.colorScheme.onSurface),
                    decoration: _deco(),
                    validator: (v) {
                      final s = v?.trim() ?? '';
                      if (s.isEmpty) return 'Enter the server hostname';
                      if (s.contains(' ')) return 'No spaces allowed';
                      return null;
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: _labeled(
                        l10n.settingsAddress,
                        TextFormField(
                          controller: _address,
                          style: _mono(color: theme.colorScheme.onSurface),
                          decoration: _deco(),
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
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _labeled(
                        l10n.settingsPort,
                        TextFormField(
                          controller: _port,
                          keyboardType: TextInputType.number,
                          style: _mono(color: theme.colorScheme.onSurface),
                          decoration: _deco(),
                          validator: (v) {
                            final port = int.tryParse(v?.trim() ?? '');
                            if (port == null || port < 1 || port > 65535) {
                              return '1-65535';
                            }
                            return null;
                          },
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _section('Credentials'),
                const SizedBox(height: 10),
                _labeled(
                  'VPN username',
                  TextFormField(
                    controller: _username,
                    style: _mono(color: theme.colorScheme.onSurface),
                    decoration: _deco(),
                    validator: (v) => (v?.trim().isEmpty ?? true)
                        ? 'Enter the username'
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                _labeled(
                  'VPN password',
                  TextFormField(
                    controller: _password,
                    obscureText: !_passwordVisible,
                    onFieldSubmitted: (_) => _submit(),
                    style: _mono(color: theme.colorScheme.onSurface),
                    decoration: _deco(
                      suffix: IconButton(
                        tooltip: _passwordVisible
                            ? 'Hide password'
                            : 'Show password',
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        constraints: const BoxConstraints(
                          minWidth: 34,
                          minHeight: 34,
                        ),
                        icon: Icon(
                          _passwordVisible
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () => setState(
                          () => _passwordVisible = !_passwordVisible,
                        ),
                      ),
                    ),
                    validator: (v) =>
                        (v?.isEmpty ?? true) ? 'Enter the password' : null,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    OutlinedButton.icon(
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
                    const SizedBox(width: 8),
                    Tooltip(
                      message:
                          'Checks the server is reachable and speaks TLS. '
                          'Your username and password are checked when you '
                          'connect.',
                      child: Icon(
                        Icons.info_outline,
                        size: 15,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
                if (_testResult != null) _buildTestResult(_testResult!),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }

  InputDecoration _deco({Widget? suffix}) => InputDecoration(
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    suffixIcon: suffix,
    suffixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    errorStyle: const TextStyle(fontSize: 11),
  );

  Widget _section(String text) =>
      Text(text, style: _sectionHeading(Theme.of(context)));

  Widget _labeled(String label, Widget field) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 18,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 4),
        field,
      ],
    );
  }

  Widget _buildTestResult(ConnectionTestResult r) {
    final scheme = Theme.of(context).colorScheme;
    final status = Theme.of(context).extension<StatusColors>()!;
    final (Color color, IconData icon) = !r.ok
        ? (scheme.error, Icons.error_outline)
        : r.certValid
        ? (status.connected, Icons.check_circle_outline)
        : (status.connecting, Icons.warning_amber);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
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

/// A tappable surface that answers the POINTER, not the touch point.
///
/// This is what replaced the `InkWell` on the server card's header row. The
/// ripple is gone app-wide, and an `InkWell` without one is a surface that
/// reacts to nothing on hover but a colour the framework picks and to a press
/// with Material's 200 ms linear highlight fade — a row that feels dead under
/// a cursor. Here the three pointer states come from the shared
/// [pointerOverlay] (hover 5% / focus 8% / press 12% of `onSurface`) and
/// arrive on [kStateChangeDuration] / [kMotionCurve], the same as every
/// themed button and [AppSwitch].
///
/// What it keeps from `InkWell`: [onTap] null means not interactive AND not
/// focusable; keyboard focus activates with space and enter; the tap action
/// still reaches semantics through the `GestureDetector`, so the row's own
/// text goes on naming it.
class _PointerSurface extends StatefulWidget {
  const _PointerSurface({
    required this.onTap,
    required this.borderRadius,
    required this.child,
  });

  /// Null disables the surface: no tint, no focus, no cursor change.
  final VoidCallback? onTap;

  /// Shape of both the tint and the focus ring.
  final BorderRadius borderRadius;

  final Widget child;

  @override
  State<_PointerSurface> createState() => _PointerSurfaceState();
}

class _PointerSurfaceState extends State<_PointerSurface> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _enabled => widget.onTap != null;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final states = <WidgetState>{
      if (!_enabled) WidgetState.disabled,
      if (_hovered) WidgetState.hovered,
      if (_focused) WidgetState.focused,
      if (_pressed) WidgetState.pressed,
    };
    final overlay = pointerOverlay(scheme.onSurface).resolve(states);

    return FocusableActionDetector(
      enabled: _enabled,
      mouseCursor: _enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onShowHoverHighlight: (value) {
        if (_hovered == value) return;
        setState(() => _hovered = value);
      },
      onShowFocusHighlight: (value) {
        if (_focused == value) return;
        setState(() => _focused = value);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapUp: _enabled ? (_) => _setPressed(false) : null,
        onTapCancel: _enabled ? () => _setPressed(false) : null,
        child: AnimatedContainer(
          duration: kStateChangeDuration,
          curve: kMotionCurve,
          decoration: BoxDecoration(
            // `Colors.transparent` is the absence of a colour, not a palette
            // choice: at rest the card's own ground shows through.
            color: overlay ?? Colors.transparent,
            borderRadius: widget.borderRadius,
          ),
          // The ring is painted OVER the row instead of bordering it, so
          // focusing never inserts 1.5px of layout and shifts the text.
          foregroundDecoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: _focused ? scheme.primary : Colors.transparent,
              width: kFocusRingWidth,
            ),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

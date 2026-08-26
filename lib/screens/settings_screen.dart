import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_status.dart';
import '../services/config_service.dart';
import '../services/vpn_service.dart';
import '../l10n/app_localizations.dart';

/// Application-level settings only — server management lives on the Servers
/// screen. Every control here applies immediately (no Save button).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _logLevel = 'info';
  // App behavior on window close: 'ask' (default), 'minimize', or 'exit'.
  String _closeAction = 'ask';
  // Connection mode: 'tun' (default) or 'socks5' — see the mode switcher.
  String _connectionMode = 'tun';
  final TextEditingController _socksPortController = TextEditingController();
  String? _socksPortError;
  bool _isLoading = true;

  late ConfigService _configService;

  @override
  void initState() {
    super.initState();
    _configService = context.read<ConfigService>();
    _configService.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _configService.removeListener(_reload);
    _socksPortController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final config = await _configService.loadConfig();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _logLevel = config.logLevel;
      _closeAction = prefs.getString('close_action') ?? 'ask';
      _connectionMode = config.connectionMode;
      // Don't fight the user's cursor: only sync the field when the stored
      // port actually differs from what's typed.
      if (int.tryParse(_socksPortController.text) != config.socksPort) {
        _socksPortController.text = config.socksPort.toString();
      }
      _isLoading = false;
    });
  }

  void _onSocksPortChanged(String value) {
    final port = int.tryParse(value);
    final valid = port != null && port >= 1 && port <= 65535;
    setState(() {
      _socksPortError = valid
          ? null
          : AppLocalizations.of(context)!.settingsSocksPortError;
    });
    // Only valid values are persisted; the error text stays until fixed.
    if (valid) {
      _configService.setGlobalSocksPort(port);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // The connection mode is locked while connected (like the server
    // connection fields) — watch the status so the lock follows it live.
    final vpnActive = context.watch<VpnService>().status.isActive;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.tune,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Application',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Applied immediately',
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
                  const SizedBox(height: 20),
                  _buildConnectionMode(context, vpnActive),
                  const SizedBox(height: 16),
                  _dropdown(
                    value: _logLevel,
                    label: AppLocalizations.of(context)!.settingsLogLevel,
                    icon: Icons.bug_report,
                    helperText:
                        'Client log verbosity · takes effect on the next connect',
                    items: const ['error', 'warn', 'info', 'debug', 'trace'],
                    onChanged: (value) async {
                      final v = value ?? 'info';
                      setState(() => _logLevel = v);
                      await _configService.setGlobalLogLevel(v);
                    },
                  ),
                  const SizedBox(height: 16),
                  _dropdown(
                    value: _closeAction,
                    label: 'On window close',
                    icon: Icons.cancel_presentation,
                    helperText: 'Ask each time, minimize to tray, or exit',
                    items: const ['ask', 'minimize', 'exit'],
                    onChanged: (value) async {
                      final v = value ?? 'ask';
                      setState(() => _closeAction = v);
                      final prefs = await SharedPreferences.getInstance();
                      if (v == 'ask') {
                        await prefs.remove('close_action');
                      } else {
                        await prefs.setString('close_action', v);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// TUN/SOCKS5 switcher with an honest one-line description per mode and
  /// the proxy-port field (SOCKS5 only). Locked while a connection is active.
  Widget _buildConnectionMode(BuildContext context, bool locked) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.settingsConnectionMode,
          style: theme.textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: 'tun',
                icon: const Icon(Icons.vpn_lock, size: 18),
                label: Text(l10n.settingsConnectionModeTun),
              ),
              ButtonSegment(
                value: 'socks5',
                icon: const Icon(Icons.lan_outlined, size: 18),
                label: Text(l10n.settingsConnectionModeSocks),
              ),
            ],
            selected: {_connectionMode},
            onSelectionChanged: locked
                ? null
                : (modes) {
                    final mode = modes.first;
                    setState(() => _connectionMode = mode);
                    _configService.setGlobalConnectionMode(mode);
                  },
          ),
        ),
        const SizedBox(height: 6),
        Text(
          locked
              ? l10n.settingsConnectionModeLocked
              : _connectionMode == 'socks5'
                  ? l10n.settingsConnectionModeSocksHint
                  : l10n.settingsConnectionModeTunHint,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        if (_connectionMode == 'socks5') ...[
          const SizedBox(height: 16),
          TextField(
            controller: _socksPortController,
            enabled: !locked,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: l10n.settingsSocksPort,
              helperText: l10n.settingsSocksPortHelper,
              errorText: _socksPortError,
              prefixIcon: const Icon(Icons.settings_ethernet),
            ),
            onChanged: _onSocksPortChanged,
          ),
        ],
      ],
    );
  }

  Widget _dropdown({
    required String value,
    required String label,
    required IconData icon,
    required List<String> items,
    required void Function(String?) onChanged,
    String? helperText,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        prefixIcon: Icon(icon),
      ),
      items: items
          .map((item) => DropdownMenuItem(value: item, child: Text(item)))
          .toList(),
      onChanged: onChanged,
    );
  }
}

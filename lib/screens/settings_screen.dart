import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/config_service.dart';
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
    super.dispose();
  }

  Future<void> _reload() async {
    final config = await _configService.loadConfig();
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _logLevel = config.logLevel;
      _closeAction = prefs.getString('close_action') ?? 'ask';
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

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

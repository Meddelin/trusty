import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../models/vpn_status.dart';
import '../services/config_service.dart';
import '../services/vpn_service.dart';
import '../l10n/app_localizations.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _hostnameController;
  late TextEditingController _addressController;
  late TextEditingController _portController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _dnsController;
  late TextEditingController _customSniController;

  bool _hasIpv6 = true;
  bool _skipVerification = false;
  bool _antiDpi = false;
  String _upstreamProtocol = 'http2';
  String _logLevel = 'info';
  bool _passwordVisible = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _hostnameController = TextEditingController();
    _addressController = TextEditingController();
    _portController = TextEditingController();
    _usernameController = TextEditingController();
    _passwordController = TextEditingController();
    _dnsController = TextEditingController();
    _customSniController = TextEditingController();

    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final configService = context.read<ConfigService>();
    final config = await configService.loadConfig();

    setState(() {
      _hostnameController.text = config.hostname;
      _addressController.text = config.address;
      _portController.text = config.port.toString();
      _usernameController.text = config.username;
      _passwordController.text = config.password;
      _dnsController.text = config.dns;
      _customSniController.text = config.customSni;
      _hasIpv6 = config.hasIpv6;
      _skipVerification = config.skipVerification;
      _antiDpi = config.antiDpi;
      _upstreamProtocol = config.upstreamProtocol;
      _logLevel = config.logLevel;
      _isLoading = false;
    });
  }

  Future<void> _saveConfig() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    try {
      final config = ServerConfig(
        hostname: _hostnameController.text.trim(),
        address: _addressController.text.trim(),
        port: int.parse(_portController.text.trim()),
        hasIpv6: _hasIpv6,
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        skipVerification: _skipVerification,
        upstreamProtocol: _upstreamProtocol,
        antiDpi: _antiDpi,
        dns: _dnsController.text.trim(),
        logLevel: _logLevel,
        customSni: _customSniController.text.trim(),
      );

      final configService = context.read<ConfigService>();
      await configService.saveConfig(config);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.settingsSaved),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.settingsSaveError(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _hostnameController.dispose();
    _addressController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _dnsController.dispose();
    _customSniController.dispose();
    super.dispose();
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
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Warning when connected
                if (isConnected)
                  Container(
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber, color: Colors.orange),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            AppLocalizations.of(context)!.settingsWarningConnected,
                            style: TextStyle(color: Colors.orange),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Server Section
                _buildSectionTitle(AppLocalizations.of(context)!.settingsSectionServer),
                _buildTextField(
                  controller: _hostnameController,
                  label: AppLocalizations.of(context)!.settingsHostname,
                  icon: Icons.dns,
                  enabled: !isConnected,
                  validator: (value) => value?.isEmpty ?? true
                      ? AppLocalizations.of(context)!.settingsHostnameError
                      : null,
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _buildTextField(
                        controller: _addressController,
                        label: AppLocalizations.of(context)!.settingsAddress,
                        icon: Icons.public,
                        enabled: !isConnected,
                        validator: (value) => value?.isEmpty ?? true
                            ? AppLocalizations.of(context)!.settingsAddressError
                            : null,
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: _buildTextField(
                        controller: _portController,
                        label: AppLocalizations.of(context)!.settingsPort,
                        icon: Icons.pin,
                        enabled: !isConnected,
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          if (value?.isEmpty ?? true) return AppLocalizations.of(context)!.settingsPortErrorEmpty;
                          final port = int.tryParse(value!);
                          if (port == null || port < 1 || port > 65535) {
                            return AppLocalizations.of(context)!.settingsPortErrorInvalid;
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),

                SizedBox(height: 24),

                // Authentication Section
                _buildSectionTitle(AppLocalizations.of(context)!.settingsSectionAuth),
                _buildTextField(
                  controller: _usernameController,
                  label: AppLocalizations.of(context)!.settingsUsername,
                  icon: Icons.person,
                  enabled: !isConnected,
                  validator: (value) => value?.isEmpty ?? true
                      ? AppLocalizations.of(context)!.settingsUsernameError
                      : null,
                ),
                SizedBox(height: 16),
                _buildTextField(
                  controller: _passwordController,
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
                      setState(() {
                        _passwordVisible = !_passwordVisible;
                      });
                    },
                  ),
                ),

                SizedBox(height: 24),

                // Network Section
                _buildSectionTitle(AppLocalizations.of(context)!.settingsSectionNetwork),
                _buildTextField(
                  controller: _dnsController,
                  label: AppLocalizations.of(context)!.settingsDns,
                  icon: Icons.router,
                  enabled: !isConnected,
                  validator: (value) => value?.isEmpty ?? true
                      ? AppLocalizations.of(context)!.settingsDnsError
                      : null,
                ),
                SizedBox(height: 16),
                _buildDropdown(
                  value: _upstreamProtocol,
                  label: AppLocalizations.of(context)!.settingsProtocol,
                  icon: Icons.settings_ethernet,
                  enabled: !isConnected,
                  items: const ['http2', 'http3'],
                  onChanged: (value) {
                    setState(() {
                      _upstreamProtocol = value!;
                    });
                  },
                ),
                SizedBox(height: 16),
                _buildDropdown(
                  value: _logLevel,
                  label: AppLocalizations.of(context)!.settingsLogLevel,
                  icon: Icons.bug_report,
                  enabled: !isConnected,
                  items: const ['error', 'warn', 'info', 'debug', 'trace'],
                  onChanged: (value) {
                    setState(() {
                      _logLevel = value!;
                    });
                  },
                ),

                SizedBox(height: 24),

                // Advanced Section
                _buildSectionTitle(AppLocalizations.of(context)!.settingsSectionAdvanced),
                _buildSwitch(
                  title: AppLocalizations.of(context)!.settingsIpv6,
                  value: _hasIpv6,
                  enabled: !isConnected,
                  onChanged: (value) {
                    setState(() {
                      _hasIpv6 = value;
                    });
                  },
                ),
                _buildSwitch(
                  title: AppLocalizations.of(context)!.settingsSkipVerification,
                  value: _skipVerification,
                  enabled: !isConnected,
                  onChanged: (value) {
                    setState(() {
                      _skipVerification = value;
                    });
                  },
                ),
                _buildSwitch(
                  title: AppLocalizations.of(context)!.settingsAntiDpi,
                  value: _antiDpi,
                  enabled: !isConnected,
                  onChanged: (value) {
                    setState(() {
                      _antiDpi = value;
                    });
                  },
                ),
                SizedBox(height: 16),
                _buildTextField(
                  controller: _customSniController,
                  label: 'Custom SNI (optional)',
                  icon: Icons.security,
                  enabled: !isConnected,
                ),

                const SizedBox(height: 32),

                // Save Button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: isConnected ? null : _saveConfig,
                    icon: Icon(Icons.save),
                    label: Text(
                      AppLocalizations.of(context)!.settingsSave,
                      style: TextStyle(fontSize: 16),
                    ),
                    style: ElevatedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
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
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  Widget _buildDropdown({
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
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      items: items.map((item) {
        return DropdownMenuItem(
          value: item,
          child: Text(item),
        );
      }).toList(),
      onChanged: enabled ? onChanged : null,
    );
  }

  Widget _buildSwitch({
    required String title,
    required bool value,
    required void Function(bool) onChanged,
    bool enabled = true,
  }) {
    return SwitchListTile(
      title: Text(title),
      value: value,
      onChanged: enabled ? onChanged : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

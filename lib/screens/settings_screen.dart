import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../models/vpn_status.dart';
import '../services/config_service.dart';
import '../services/vpn_service.dart';

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
      );

      final configService = context.read<ConfigService>();
      await configService.saveConfig(config);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Settings saved'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save error: $e'),
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
                    child: const Row(
                      children: [
                        Icon(Icons.warning_amber, color: Colors.orange),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Disconnect from VPN before changing settings',
                            style: TextStyle(color: Colors.orange),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Server Section
                _buildSectionTitle('Server'),
                _buildTextField(
                  controller: _hostnameController,
                  label: 'Hostname',
                  icon: Icons.dns,
                  enabled: !isConnected,
                  validator: (value) => value?.isEmpty ?? true
                      ? 'Enter hostname'
                      : null,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _buildTextField(
                        controller: _addressController,
                        label: 'IP Address',
                        icon: Icons.public,
                        enabled: !isConnected,
                        validator: (value) => value?.isEmpty ?? true
                            ? 'Enter IP address'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildTextField(
                        controller: _portController,
                        label: 'Port',
                        icon: Icons.pin,
                        enabled: !isConnected,
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          if (value?.isEmpty ?? true) return 'Enter port';
                          final port = int.tryParse(value!);
                          if (port == null || port < 1 || port > 65535) {
                            return 'Invalid port';
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Authentication Section
                _buildSectionTitle('Authentication'),
                _buildTextField(
                  controller: _usernameController,
                  label: 'Username',
                  icon: Icons.person,
                  enabled: !isConnected,
                  validator: (value) => value?.isEmpty ?? true
                      ? 'Enter username'
                      : null,
                ),
                const SizedBox(height: 16),
                _buildTextField(
                  controller: _passwordController,
                  label: 'Password',
                  icon: Icons.lock,
                  enabled: !isConnected,
                  obscureText: !_passwordVisible,
                  validator: (value) => value?.isEmpty ?? true
                      ? 'Enter password'
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

                const SizedBox(height: 24),

                // Network Section
                _buildSectionTitle('Network'),
                _buildTextField(
                  controller: _dnsController,
                  label: 'DNS Server',
                  icon: Icons.router,
                  enabled: !isConnected,
                  validator: (value) => value?.isEmpty ?? true
                      ? 'Enter DNS server'
                      : null,
                ),
                const SizedBox(height: 16),
                _buildDropdown(
                  value: _upstreamProtocol,
                  label: 'Protocol',
                  icon: Icons.settings_ethernet,
                  enabled: !isConnected,
                  items: const ['http2', 'http3'],
                  onChanged: (value) {
                    setState(() {
                      _upstreamProtocol = value!;
                    });
                  },
                ),
                const SizedBox(height: 16),
                _buildDropdown(
                  value: _logLevel,
                  label: 'Log Level',
                  icon: Icons.bug_report,
                  enabled: !isConnected,
                  items: const ['error', 'warn', 'info', 'debug', 'trace'],
                  onChanged: (value) {
                    setState(() {
                      _logLevel = value!;
                    });
                  },
                ),

                const SizedBox(height: 24),

                // Advanced Section
                _buildSectionTitle('Advanced'),
                _buildSwitch(
                  title: 'IPv6 Support',
                  value: _hasIpv6,
                  enabled: !isConnected,
                  onChanged: (value) {
                    setState(() {
                      _hasIpv6 = value;
                    });
                  },
                ),
                _buildSwitch(
                  title: 'Skip Certificate Verification',
                  value: _skipVerification,
                  enabled: !isConnected,
                  onChanged: (value) {
                    setState(() {
                      _skipVerification = value;
                    });
                  },
                ),
                _buildSwitch(
                  title: 'Anti-DPI',
                  value: _antiDpi,
                  enabled: !isConnected,
                  onChanged: (value) {
                    setState(() {
                      _antiDpi = value;
                    });
                  },
                ),

                const SizedBox(height: 32),

                // Save Button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: isConnected ? null : _saveConfig,
                    icon: const Icon(Icons.save),
                    label: const Text(
                      'Save Settings',
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

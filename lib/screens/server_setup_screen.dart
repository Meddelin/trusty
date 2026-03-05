import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/setup_step.dart';
import '../models/server_setup_config.dart';
import '../services/server_setup_service.dart';
import '../services/config_service.dart';
import '../l10n/app_localizations.dart';

class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();

  // SSH
  final _hostController = TextEditingController();
  final _sshPortController = TextEditingController(text: '22');
  final _sshUserController = TextEditingController(text: 'root');
  final _sshPasswordController = TextEditingController();
  final _sshKeyPathController = TextEditingController();
  bool _useKeyAuth = false;
  bool _sshPasswordVisible = false;

  // Server / TLS
  final _domainController = TextEditingController();
  final _emailController = TextEditingController();
  final _listenPortController = TextEditingController(text: '443');

  // VPN account
  final _vpnUsernameController = TextEditingController();
  final _vpnPasswordController = TextEditingController();
  bool _vpnPasswordVisible = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _hostController.dispose();
    _sshPortController.dispose();
    _sshUserController.dispose();
    _sshPasswordController.dispose();
    _sshKeyPathController.dispose();
    _domainController.dispose();
    _emailController.dispose();
    _listenPortController.dispose();
    _vpnUsernameController.dispose();
    _vpnPasswordController.dispose();
    super.dispose();
  }

  String _generatePassword() {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^&*';
    final rng = Random.secure();
    return List.generate(16, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  ServerSetupConfig _buildConfig() {
    return ServerSetupConfig(
      host: _hostController.text.trim(),
      sshPort: int.tryParse(_sshPortController.text.trim()) ?? 22,
      sshUsername: _sshUserController.text.trim(),
      sshPassword: _sshPasswordController.text,
      sshKeyPath:
          _useKeyAuth ? _sshKeyPathController.text.trim() : null,
      useKeyAuth: _useKeyAuth,
      domain: _domainController.text.trim(),
      email: _emailController.text.trim(),
      listenPort: int.tryParse(_listenPortController.text.trim()) ?? 443,
      vpnUsername: _vpnUsernameController.text.trim(),
      vpnPassword: _vpnPasswordController.text,
    );
  }

  Future<void> _startInstallation() async {
    if (!_formKey.currentState!.validate()) return;

    final service = context.read<ServerSetupService>();
    final config = _buildConfig();

    await service.installAndRemember(config);
  }

  Future<void> _applyToClient() async {
    final setupService = context.read<ServerSetupService>();
    final configService = context.read<ConfigService>();

    try {
      await setupService.applyToClientConfig(configService);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.serverSettingsApplied),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.serverError(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ServerSetupService>(
      builder: (context, service, child) {
        final isRunning = service.currentStep.isInProgress;

        return SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Info banner
                _buildInfoBanner(),
                SizedBox(height: 24),

                // SSH Section
                _buildSectionTitle(AppLocalizations.of(context)!.serverSectionSsh),
                _buildTextField(
                  controller: _hostController,
                  label: AppLocalizations.of(context)!.serverVpsIp,
                  icon: Icons.computer,
                  enabled: !isRunning,
                  validator: (v) =>
                      (v?.isEmpty ?? true) ? AppLocalizations.of(context)!.serverVpsIpError : null,
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _buildTextField(
                        controller: _sshUserController,
                        label: AppLocalizations.of(context)!.serverSshUser,
                        icon: Icons.person,
                        enabled: !isRunning,
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: _buildTextField(
                        controller: _sshPortController,
                        label: AppLocalizations.of(context)!.serverSshPort,
                        icon: Icons.pin,
                        enabled: !isRunning,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Auth type toggle
                _buildAuthToggle(isRunning),
                SizedBox(height: 16),

                if (_useKeyAuth)
                  _buildTextField(
                    controller: _sshKeyPathController,
                    label: AppLocalizations.of(context)!.serverSshKeyPath,
                    icon: Icons.key,
                    enabled: !isRunning,
                    hintText: Platform.isWindows ? r'C:\Users\user\.ssh\id_rsa' : '~/.ssh/id_rsa',
                    validator: (v) => _useKeyAuth && (v?.isEmpty ?? true)
                        ? AppLocalizations.of(context)!.serverSshKeyPathError
                        : null,
                  )
                else
                  _buildTextField(
                    controller: _sshPasswordController,
                    label: AppLocalizations.of(context)!.serverSshPassword,
                    icon: Icons.lock,
                    enabled: !isRunning,
                    obscureText: !_sshPasswordVisible,
                    validator: (v) => !_useKeyAuth && (v?.isEmpty ?? true)
                        ? AppLocalizations.of(context)!.serverSshPasswordError
                        : null,
                    suffixIcon: IconButton(
                      icon: Icon(_sshPasswordVisible
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () => setState(
                          () => _sshPasswordVisible = !_sshPasswordVisible),
                    ),
                  ),

                SizedBox(height: 24),

                // Domain & Certificate Section
                _buildSectionTitle(AppLocalizations.of(context)!.serverSectionDomain),
                _buildTextField(
                  controller: _domainController,
                  label: AppLocalizations.of(context)!.serverDomain,
                  icon: Icons.language,
                  enabled: !isRunning,
                  hintText: 'vpn.example.com',
                  validator: (v) =>
                      (v?.isEmpty ?? true) ? AppLocalizations.of(context)!.serverDomainError : null,
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Text(
                    AppLocalizations.of(context)!.serverDomainHint,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _buildTextField(
                        controller: _emailController,
                        label: AppLocalizations.of(context)!.serverEmail,
                        icon: Icons.email,
                        enabled: !isRunning,
                        validator: (v) =>
                            (v?.isEmpty ?? true) ? AppLocalizations.of(context)!.serverEmailError : null,
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: _buildTextField(
                        controller: _listenPortController,
                        label: AppLocalizations.of(context)!.settingsPort,
                        icon: Icons.pin,
                        enabled: !isRunning,
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),

                SizedBox(height: 24),

                // VPN Account Section
                _buildSectionTitle(AppLocalizations.of(context)!.serverSectionVpnAccount),
                _buildTextField(
                  controller: _vpnUsernameController,
                  label: AppLocalizations.of(context)!.serverVpnUsername,
                  icon: Icons.person_outline,
                  enabled: !isRunning,
                  validator: (v) =>
                      (v?.isEmpty ?? true) ? AppLocalizations.of(context)!.serverVpnUsernameError : null,
                ),
                SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _buildTextField(
                        controller: _vpnPasswordController,
                        label: AppLocalizations.of(context)!.serverVpnPassword,
                        icon: Icons.lock_outline,
                        enabled: !isRunning,
                        obscureText: !_vpnPasswordVisible,
                        validator: (v) =>
                            (v?.isEmpty ?? true) ? 'Enter password' : null,
                        suffixIcon: IconButton(
                          icon: Icon(_vpnPasswordVisible
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () => setState(
                              () => _vpnPasswordVisible = !_vpnPasswordVisible),
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    Tooltip(
                      message: AppLocalizations.of(context)!.serverGeneratePassword,
                      child: IconButton.filled(
                        onPressed: isRunning
                            ? null
                            : () {
                                setState(() {
                                  _vpnPasswordController.text =
                                      _generatePassword();
                                  _vpnPasswordVisible = true;
                                });
                              },
                        icon: const Icon(Icons.casino),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 32),

                // Install Button
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton.icon(
                    onPressed: isRunning ? null : _startInstallation,
                    icon: Icon(isRunning ? Icons.hourglass_top : Icons.rocket_launch),
                    label: Text(
                      isRunning ? AppLocalizations.of(context)!.serverInstalling : AppLocalizations.of(context)!.serverInstallButton,
                      style: const TextStyle(fontSize: 16),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          Theme.of(context).colorScheme.primaryContainer,
                      foregroundColor:
                          Theme.of(context).colorScheme.onPrimaryContainer,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),

                // Progress & Logs (shown after start)
                if (service.currentStep != SetupStep.idle) ...[
                  const SizedBox(height: 32),
                  _buildProgressSection(service),
                  const SizedBox(height: 16),
                  _buildLogSection(service),
                ],

                // Success actions
                if (service.currentStep == SetupStep.completed) ...[
                  const SizedBox(height: 16),
                  _buildSuccessActions(),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primaryContainer,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              color: Theme.of(context).colorScheme.primary),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              AppLocalizations.of(context)!.serverInfoBanner,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthToggle(bool disabled) {
    return SegmentedButton<bool>(
      segments: [
        ButtonSegment(
          value: false,
          label: Text(AppLocalizations.of(context)!.serverAuthPassword),
          icon: Icon(Icons.lock),
        ),
        ButtonSegment(
          value: true,
          label: Text(AppLocalizations.of(context)!.serverAuthKey),
          icon: Icon(Icons.key),
        ),
      ],
      selected: {_useKeyAuth},
      onSelectionChanged: disabled
          ? null
          : (values) {
              setState(() => _useKeyAuth = values.first);
            },
    );
  }

  Widget _buildProgressSection(ServerSetupService service) {
    final steps = [
      SetupStep.connecting,
      SetupStep.checkingSystem,
      SetupStep.installing,
      SetupStep.configuringServer,
      SetupStep.obtainingCertificate,
      SetupStep.startingService,
      SetupStep.verifying,
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(service.currentStep.icon,
                    color: service.currentStep.color, size: 28),
                const SizedBox(width: 12),
                Text(
                  service.currentStep.displayText,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: service.currentStep.color,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...steps.map((step) => _buildStepRow(step, service)),
            if (service.errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        service.errorMessage!,
                        style: const TextStyle(
                            color: Colors.red, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStepRow(SetupStep step, ServerSetupService service) {
    final currentIndex = service.currentStep.stepIndex;
    final stepIndex = step.stepIndex;
    final isFailed = service.currentStep == SetupStep.failed;

    IconData icon;
    Color color;

    if (stepIndex < currentIndex || service.currentStep == SetupStep.completed) {
      // Completed step
      icon = Icons.check_circle;
      color = Colors.green;
    } else if (stepIndex == currentIndex) {
      if (isFailed) {
        icon = Icons.error;
        color = Colors.red;
      } else {
        // Current step
        icon = Icons.radio_button_checked;
        color = Colors.orange;
      }
    } else {
      // Future step
      icon = Icons.radio_button_unchecked;
      color = Colors.grey.withValues(alpha: 0.4);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Text(
            step.displayText.replaceAll('...', ''),
            style: TextStyle(
              color: color,
              fontWeight:
                  stepIndex == currentIndex ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogSection(ServerSetupService service) {
    // Auto-scroll to bottom when logs update
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 20),
                SizedBox(width: 8),
                Text(AppLocalizations.of(context)!.serverInstallLog,
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    service.clearLogs();
                  },
                  icon: Icon(Icons.delete_outline, size: 18),
                  label: Text(AppLocalizations.of(context)!.commonClear),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Container(
            height: 300,
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            child: service.logs.isEmpty
                ? Center(
                    child: Text(AppLocalizations.of(context)!.serverLogEmpty,
                        style: TextStyle(color: Colors.grey)))
                : SingleChildScrollView(
                    child: SelectableText(
                      service.logs.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessActions() {
    return Card(
      color: Colors.green.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 28),
                SizedBox(width: 12),
                Text(
                  AppLocalizations.of(context)!.serverInstalled,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            Text(
              AppLocalizations.of(context)!.serverSuccessInfo(_domainController.text, _listenPortController.text, _vpnUsernameController.text),


              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _applyToClient,
                icon: Icon(Icons.settings_suggest),
                label: Text(AppLocalizations.of(context)!.serverApplySettings),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
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
    String? hintText,
  }) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        prefixIcon: Icon(icon),
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/setup_step.dart';
import '../models/server_setup_config.dart';
import '../services/server_setup_service.dart';
import '../services/config_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';

class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  // The log panel scrolls itself; autoscrolling the page controller on every
  // log line yanked the whole form out from under the user.
  final _logScrollController = ScrollController();

  // SSH
  final _hostController = TextEditingController();
  final _sshPortController = TextEditingController(text: '22');
  final _sshUserController = TextEditingController(text: 'root');
  final _sshPasswordController = TextEditingController();
  late final TextEditingController _sshKeyPathController;
  bool _useKeyAuth = false;
  bool _sshPasswordVisible = false;

  @override
  void initState() {
    super.initState();
    final homeDir =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '~';
    final slash = Platform.isWindows ? '\\' : '/';
    _sshKeyPathController = TextEditingController(
      text: '$homeDir$slash.ssh${slash}id_ed25519',
    );
    _restoreSavedForm();
    // Rebuild the "Last deployment" card after an app restart so the
    // generated client_random_prefix is never stranded.
    context.read<ServerSetupService>().loadPersistedResult();
  }

  /// Restore the non-secret form fields saved on the last Install press.
  /// Passwords are never persisted, so those fields stay empty.
  Future<void> _restoreSavedForm() async {
    final saved = await ServerSetupService.loadFormDefaults();
    if (saved == null || !mounted) return;
    setState(() {
      _hostController.text = saved.host;
      _sshPortController.text = saved.sshPort.toString();
      _sshUserController.text = saved.sshUsername;
      _useKeyAuth = saved.useKeyAuth;
      if (saved.sshKeyPath?.isNotEmpty ?? false) {
        _sshKeyPathController.text = saved.sshKeyPath!;
      }
      _domainController.text = saved.domain;
      _emailController.text = saved.email;
      _listenPortController.text = saved.listenPort.toString();
      _vpnUsernameController.text = saved.vpnUsername;
      _generatePrefix = saved.generateClientRandomPrefix;
    });
  }

  // Server / TLS
  final _domainController = TextEditingController();
  final _emailController = TextEditingController();
  final _listenPortController = TextEditingController(text: '443');

  // VPN account
  final _vpnUsernameController = TextEditingController();
  final _vpnPasswordController = TextEditingController();
  bool _vpnPasswordVisible = false;

  // Connection filtering (TLS client_random_prefix)
  bool _generatePrefix = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _logScrollController.dispose();
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

  String? _validatePort(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return null; // falls back to the default port
    final port = int.tryParse(s);
    if (port == null || port < 1 || port > 65535) {
      return 'Port must be 1-65535';
    }
    return null;
  }

  ServerSetupConfig _buildConfig() {
    return ServerSetupConfig(
      host: _hostController.text.trim(),
      sshPort: int.tryParse(_sshPortController.text.trim()) ?? 22,
      sshUsername: _sshUserController.text.trim(),
      sshPassword: _sshPasswordController.text,
      sshKeyPath: _useKeyAuth ? _sshKeyPathController.text.trim() : null,
      useKeyAuth: _useKeyAuth,
      domain: _domainController.text.trim(),
      email: _emailController.text.trim(),
      listenPort: int.tryParse(_listenPortController.text.trim()) ?? 443,
      vpnUsername: _vpnUsernameController.text.trim(),
      vpnPassword: _vpnPasswordController.text,
      generateClientRandomPrefix: _generatePrefix,
    );
  }

  Future<void> _startInstallation() async {
    if (!_formKey.currentState!.validate()) return;

    final service = context.read<ServerSetupService>();
    final config = _buildConfig();

    // Persist the non-secret fields so a restart doesn't force retyping.
    await ServerSetupService.saveFormDefaults(config);

    await service.installAndRemember(config, confirmReplace: _confirmReplace);
  }

  /// Shown when the server already has TrustTunnel installed.
  Future<bool> _confirmReplace() async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('TrustTunnel already installed'),
        content: const Text(
          'An existing TrustTunnel installation was found on this server. '
          'Continuing will stop it and overwrite its configuration '
          '(vpn.toml, credentials, hosts, rules). Replace it?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep existing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _applyToClient() async {
    final setupService = context.read<ServerSetupService>();
    final configService = context.read<ConfigService>();

    try {
      await setupService.applyToClientConfig(configService);
      if (mounted) {
        showAppSnackBar(
            context, AppLocalizations.of(context)!.serverSettingsApplied,
            kind: SnackKind.success);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
            context, AppLocalizations.of(context)!.serverError(e.toString()),
            kind: SnackKind.error);
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
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Info banner
                    _buildInfoBanner(),
                    SizedBox(height: 24),

                    // SSH Section
                    _buildSectionTitle(
                      AppLocalizations.of(context)!.serverSectionSsh,
                    ),
                    _buildTextField(
                      controller: _hostController,
                      label: AppLocalizations.of(context)!.serverVpsIp,
                      icon: Icons.computer,
                      enabled: !isRunning,
                      validator: (v) => (v?.isEmpty ?? true)
                          ? AppLocalizations.of(context)!.serverVpsIpError
                          : null,
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
                            validator: _validatePort,
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
                        hintText: Platform.isWindows
                            ? r'C:\Users\user\.ssh\id_rsa'
                            : '~/.ssh/id_rsa',
                        validator: (v) => _useKeyAuth && (v?.isEmpty ?? true)
                            ? AppLocalizations.of(
                                context,
                              )!.serverSshKeyPathError
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
                            ? AppLocalizations.of(
                                context,
                              )!.serverSshPasswordError
                            : null,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _sshPasswordVisible
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () => setState(
                            () => _sshPasswordVisible = !_sshPasswordVisible,
                          ),
                        ),
                      ),

                    SizedBox(height: 24),

                    // Domain & Certificate Section
                    _buildSectionTitle(
                      AppLocalizations.of(context)!.serverSectionDomain,
                    ),
                    _buildTextField(
                      controller: _domainController,
                      label: AppLocalizations.of(context)!.serverDomain,
                      icon: Icons.language,
                      enabled: !isRunning,
                      hintText: 'vpn.example.com',
                      validator: (v) {
                        final s = v?.trim() ?? '';
                        if (s.isEmpty) {
                          return AppLocalizations.of(
                            context,
                          )!.serverDomainError;
                        }
                        if (!RegExp(
                          r'^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$',
                        ).hasMatch(s)) {
                          return 'Enter a valid domain name (e.g. vpn.example.com)';
                        }
                        return null;
                      },
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
                            validator: (v) {
                              final s = v?.trim() ?? '';
                              if (s.isEmpty) {
                                return AppLocalizations.of(
                                  context,
                                )!.serverEmailError;
                              }
                              if (!RegExp(
                                r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                              ).hasMatch(s)) {
                                return 'Enter a valid email address';
                              }
                              return null;
                            },
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
                            validator: _validatePort,
                          ),
                        ),
                      ],
                    ),

                    SizedBox(height: 24),

                    // VPN Account Section
                    _buildSectionTitle(
                      AppLocalizations.of(context)!.serverSectionVpnAccount,
                    ),
                    _buildTextField(
                      controller: _vpnUsernameController,
                      label: AppLocalizations.of(context)!.serverVpnUsername,
                      icon: Icons.person_outline,
                      enabled: !isRunning,
                      validator: (v) => (v?.isEmpty ?? true)
                          ? AppLocalizations.of(context)!.serverVpnUsernameError
                          : null,
                    ),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _buildTextField(
                            controller: _vpnPasswordController,
                            label: AppLocalizations.of(
                              context,
                            )!.serverVpnPassword,
                            icon: Icons.lock_outline,
                            enabled: !isRunning,
                            obscureText: !_vpnPasswordVisible,
                            validator: (v) =>
                                (v?.isEmpty ?? true) ? 'Enter password' : null,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _vpnPasswordVisible
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () => setState(
                                () =>
                                    _vpnPasswordVisible = !_vpnPasswordVisible,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 8),
                        Tooltip(
                          message: AppLocalizations.of(
                            context,
                          )!.serverGeneratePassword,
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

                    SizedBox(height: 24),

                    // Security Section
                    _buildSectionTitle('Security'),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enable connection filtering'),
                      subtitle: const Text(
                        'Generates a secret TLS client random prefix so the server '
                        'answers only this client and ignores probes/scanners. '
                        'Auto-filled into your client settings on "Apply".',
                      ),
                      value: _generatePrefix,
                      onChanged: isRunning
                          ? null
                          : (v) => setState(() => _generatePrefix = v),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Install Button (+ Cancel while running)
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 50,
                            child: ElevatedButton.icon(
                              onPressed: isRunning ? null : _startInstallation,
                              icon: Icon(
                                isRunning
                                    ? Icons.hourglass_top
                                    : Icons.rocket_launch,
                              ),
                              label: Text(
                                isRunning
                                    ? AppLocalizations.of(
                                        context,
                                      )!.serverInstalling
                                    : AppLocalizations.of(
                                        context,
                                      )!.serverInstallButton,
                                style: const TextStyle(fontSize: 16),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.primaryContainer,
                                foregroundColor: Theme.of(
                                  context,
                                ).colorScheme.onPrimaryContainer,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (isRunning) ...[
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 50,
                            child: OutlinedButton.icon(
                              onPressed: service.cancelInstallation,
                              icon: const Icon(Icons.cancel_outlined),
                              label: const Text('Cancel'),
                              style: OutlinedButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
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
                      _buildSuccessActions(service),
                    ],

                    // After an app restart the step is idle but a persisted
                    // result may exist — offer the same Apply action so the
                    // deploy (and its generated prefix) isn't stranded.
                    if (service.currentStep == SetupStep.idle &&
                        service.lastResult != null) ...[
                      const SizedBox(height: 32),
                      _buildLastDeploymentCard(service),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildInfoBanner() {
    return InfoBanner(
      severity: BannerSeverity.info,
      message: AppLocalizations.of(context)!.serverInfoBanner,
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
                Icon(
                  service.currentStep.icon,
                  color: service.currentStep.color,
                  size: 28,
                ),
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
              InfoBanner(
                severity: BannerSeverity.error,
                title: 'Installation failed',
                message: service.errorMessage!,
              ),
              // Recovery path for a legitimate host-key change (rebuilt VPS):
              // forget the stored fingerprint and immediately retry the install.
              if (service.hostKeyMismatch) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.key_off, size: 18),
                    label: const Text('Trust new host key & retry'),
                    onPressed: () async {
                      await service.trustNewHostKey();
                      await _startInstallation();
                    },
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStepRow(SetupStep step, ServerSetupService service) {
    final isFailed = service.currentStep == SetupStep.failed;
    // On failure the checklist marks the step that actually broke (failed
    // itself has index -1, which would grey out the whole list).
    final currentIndex = isFailed
        ? (service.lastAttemptedStep?.stepIndex ?? -1)
        : service.currentStep.stepIndex;
    final stepIndex = step.stepIndex;

    IconData icon;
    Color color;

    if (stepIndex < currentIndex ||
        service.currentStep == SetupStep.completed) {
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
              fontWeight: stepIndex == currentIndex
                  ? FontWeight.bold
                  : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogSection(ServerSetupService service) {
    // Auto-scroll the log panel (never the page), and only when the user is
    // already near the bottom — scrolling up to read must not be fought.
    // Proximity is captured BEFORE the new lines are laid out: checking it
    // inside the post-frame callback compares against the already-grown
    // maxScrollExtent, so any multi-line burst would permanently stop the
    // autoscroll.
    final wasNearBottom = !_logScrollController.hasClients ||
        _logScrollController.position.maxScrollExtent -
                _logScrollController.position.pixels <=
            150;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!wasNearBottom || !_logScrollController.hasClients) return;
      // jumpTo, not animateTo: an in-flight animation lags behind fast log
      // streams and would break the near-bottom check on the next line.
      _logScrollController.jumpTo(
          _logScrollController.position.maxScrollExtent);
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
                Text(
                  AppLocalizations.of(context)!.serverInstallLog,
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
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
                    child: Text(
                      AppLocalizations.of(context)!.serverLogEmpty,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : SingleChildScrollView(
                    controller: _logScrollController,
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

  Widget _buildSuccessActions(ServerSetupService service) {
    // Render from what was actually deployed (the installer may have picked
    // another port when the requested one was busy), never from the raw
    // text controllers.
    final result = service.lastResult;
    if (result == null) return const SizedBox.shrink();
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle,
                    color: Theme.of(context).extension<StatusColors>()!.connected, size: 28),
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
              AppLocalizations.of(context)!.serverSuccessInfo(
                result.domain,
                result.listenPort.toString(),
                result.vpnUsername,
              ),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
            if (result.clientRandomPrefix.isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildPrefixRow(result.clientRandomPrefix),
            ],
            const SizedBox(height: 16),
            _buildApplyButton(),
          ],
        ),
      ),
    );
  }

  /// Compact card shown when the app was restarted after a successful deploy:
  /// the in-memory config is gone, but the persisted result still lets the
  /// user apply the server (crucially, with the generated prefix intact).
  Widget _buildLastDeploymentCard(ServerSetupService service) {
    final result = service.lastResult!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.history,
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Last deployment',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${result.domain} (${result.host}:${result.listenPort}), '
              'user ${result.vpnUsername}',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
            if (result.clientRandomPrefix.isNotEmpty) ...[
              const SizedBox(height: 8),
              _buildPrefixRow(result.clientRandomPrefix),
            ],
            const SizedBox(height: 8),
            Text(
              'The VPN password is never stored. If it is missing after '
              'applying, re-enter it in Settings.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            _buildApplyButton(),
          ],
        ),
      ),
    );
  }

  /// The generated TLS client_random_prefix with a copy button — without
  /// this exact value the server ignores the client, so make it easy to
  /// save somewhere safe.
  Widget _buildPrefixRow(String prefix) {
    return Row(
      children: [
        const Icon(Icons.shield_outlined, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            'Filtering prefix: $prefix',
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
          ),
        ),
        IconButton(
          tooltip: 'Copy prefix',
          icon: const Icon(Icons.copy, size: 18),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: prefix));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Prefix copied to clipboard')),
            );
          },
        ),
      ],
    );
  }

  Widget _buildApplyButton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _applyToClient,
            icon: const Icon(Icons.settings_suggest),
            label: const Text('Add server & switch to it'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Adds this server to your list and makes it active. '
          'Your other servers are untouched.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
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
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

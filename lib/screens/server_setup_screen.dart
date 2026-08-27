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
import '../widgets/app_switch.dart';
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';

/// `kMonoFontStack.sublist(1)` allocated once, at import, instead of on every
/// `_mono()` call. Every field label, locked value and the whole install log
/// asks for a mono style on each rebuild, and each of those was copying the
/// fallback list.
final List<String> _kMonoFallback = kMonoFontStack.sublist(1);

/// Deploy, composed as islands rather than one long form column.
///
/// Three compositions, one per phase of a deployment:
///
///  * **idle / failed** — the form phase. Four islands (SSH Connection, Domain
///    and Certificate, VPN Account, Security) in a two-column grid, plus a
///    240px side column carrying the persisted "last deployment" card and its
///    Apply action. On a failure the checklist and the install log join the
///    body above the grid — the reason, and the trust-and-retry recovery, at
///    the top of the checklist island — so the outcome lands where the user
///    is looking and the form stays underneath, editable, for the retry.
///  * **running** — the form islands collapse into a locked, read-only summary
///    strip; the checklist and the streaming log take the rest of the window.
///  * **completed** — the checklist sits beside the result island (deployed
///    values, the filtering prefix with its copy control, Apply), with the log
///    across the bottom.
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

  /// The seven real installer steps, in order.
  static const List<SetupStep> _steps = [
    SetupStep.connecting,
    SetupStep.checkingSystem,
    SetupStep.installing,
    SetupStep.configuringServer,
    SetupStep.obtainingCertificate,
    SetupStep.startingService,
    SetupStep.verifying,
  ];

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

  /// `ServerSetupService` never leaves `SetupStep.completed` once an install
  /// succeeds, so the completed composition would otherwise be a dead end for
  /// the rest of the session — before the redesign the form stayed on screen
  /// in every phase, and a second VPS could be deployed without restarting the
  /// app. Set by the header action on the completed screen to put the form
  /// back, and cleared the moment an install starts.
  bool _editAfterCompletion = false;

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

  /// The SSH host: an IP address (v4 or v6) or a hostname.
  ///
  /// Nothing downstream checks this. `_stepConnect` hands the raw string to
  /// `SSHSocket.connect` and `ServerSetupConfig.validateForInstall` only
  /// covers `domain`/`email`, so a typo like "999.999.999.999" was accepted,
  /// saved as a form default, and spent the 15s connect timeout in a name
  /// lookup before coming back as a raw SocketException on the checklist's
  /// first step. Every other field on this form says so before the install
  /// starts; this one now does too.
  String? _validateHost(String? v) {
    final l10n = AppLocalizations.of(context)!;
    final s = v?.trim() ?? '';
    if (s.isEmpty) return l10n.serverVpsIpError;
    // Covers both families and rejects out-of-range octets.
    if (InternetAddress.tryParse(s) != null) return null;
    // A VPS reached by name is legitimate, so accept the same hostname shape
    // the domain field accepts rather than forcing a literal address.
    if (RegExp(
      r'^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$',
    ).hasMatch(s)) {
      return null;
    }
    return 'Enter a valid IP address or hostname (e.g. 203.0.113.10)';
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
    // The form islands are only mounted in the idle/failed composition. When
    // they are not (a re-deploy pressed straight from the completed screen)
    // the controllers still hold the values that passed validation on the
    // previous run, so a missing FormState is a pass, never a crash.
    if (!(_formKey.currentState?.validate() ?? true)) return;

    _editAfterCompletion = false;
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
          context,
          AppLocalizations.of(context)!.serverSettingsApplied,
          kind: SnackKind.success,
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context)!.serverError(e.toString()),
          kind: SnackKind.error,
        );
      }
    }
  }

  // ---------------------------------------------------------------------
  // Shell
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Only the phase drives this shell, so only the phase may rebuild it.
    // This was a Consumer over the entire screen: `ServerSetupService`
    // notifies on every appended log line, so a running deployment rebuilt the
    // header, the banner, every form island and every TextFormField dozens of
    // times a second. A Selector on the step alone rebuilds it seven times per
    // install instead.
    return Selector<ServerSetupService, SetupStep>(
      selector: (_, service) => service.currentStep,
      builder: (context, step, _) {
        final isRunning = step.isInProgress;
        final isDone = step == SetupStep.completed && !_editAfterCompletion;

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(isRunning, isDone),
              const SizedBox(height: 14),
              // The intro banner is the only standing prose on this screen and
              // it only earns its place before anything has been attempted.
              if (step == SetupStep.idle) ...[
                InfoBanner(
                  severity: BannerSeverity.info,
                  message: AppLocalizations.of(context)!.serverInfoBanner,
                ),
                const SizedBox(height: 14),
              ],
              Expanded(
                child: isRunning
                    ? _buildRunningBody()
                    : isDone
                    ? _buildCompletedBody()
                    : _buildFormBody(step),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Screen title on the left, the install action (and Cancel while an install
  /// runs) on the right.
  Widget _buildHeader(bool isRunning, bool isDone) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(
          child: Text(
            l10n.navServer,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: 16),
        // The one 50px / radius-12 control in the app: the artboard's install
        // action. Everything else on this screen takes the themed 34px.
        FilledButton.icon(
          // On the completed screen the form is not mounted, so pressing
          // Install would silently re-run the previous deployment with
          // values the user cannot see. It brings the form back instead;
          // the next press deploys, validated as usual.
          onPressed: isRunning
              ? null
              : isDone
              ? () => setState(() => _editAfterCompletion = true)
              : _startInstallation,
          icon: Icon(
            isRunning ? Icons.hourglass_top : Icons.rocket_launch,
            size: 18,
          ),
          label: Text(
            isRunning ? l10n.serverInstalling : l10n.serverInstallButton,
          ),
          style: FilledButton.styleFrom(
            minimumSize: const Size(172, 50),
            padding: const EdgeInsets.symmetric(horizontal: 24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
            // The one implicit animation left on this screen that was still
            // running on framework defaults. A button's fill, shape and border
            // are animated by the `Material` inside `ButtonStyleButton`, over
            // `ButtonStyle.animationDuration` -- which the M3 defaults set to
            // `kThemeChangeDuration`, 200ms, on `Curves.fastOutSlowIn`. This
            // button changes ground twice per deployment (enabled primary ->
            // disabled surface and back), so that Material ease was visible
            // every time. The curve is hard-coded inside `Material`; the
            // duration is not, and at 120ms the slow-in tail no longer reads.
            animationDuration: kStateChangeDuration,
          ),
        ),
        if (isRunning) ...[
          const SizedBox(width: 12),
          // Matches the install action's height so the pair reads as one
          // header control group; the label keeps the themed 13/500.
          OutlinedButton.icon(
            onPressed: context.read<ServerSetupService>().cancelInstallation,
            icon: const Icon(Icons.cancel_outlined, size: 18),
            label: Text(l10n.commonCancel),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(128, 50),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              // Same default, same fix: the two sit side by side in the
              // header, so they must settle on the same clock.
              animationDuration: kStateChangeDuration,
            ),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Phase 1 — the form (idle, and after a failure so the user can fix and
  // retry exactly as before)
  // ---------------------------------------------------------------------

  Widget _buildFormBody(SetupStep step) {
    final failed = step == SetupStep.failed;
    // Same condition as before the redesign: a persisted result with no live
    // deployment in flight still offers Apply, so a restart never strands the
    // generated prefix. Re-opening the form from the completed screen counts
    // as idle here — otherwise Apply would vanish for the deployment that has
    // just finished. The `lastResult != null` half of the old condition moved
    // into the side column's own Selector: `loadPersistedResult()` notifies
    // without changing the step, and only that column needs to hear it.
    final canShowLast = step == SetupStep.idle || _editAfterCompletion;

    return SingleChildScrollView(
      controller: _scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A failure keeps the form editable — fix a field and press Install
          // again — but the outcome is what the user pressed Install to see,
          // so it takes the top of the body, where the running and completed
          // compositions also put the checklist. Underneath the form it was a
          // full window below the fold: the install failed and the visible
          // screen did not change.
          if (failed) ...[
            SizedBox(
              height: 330,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 300, child: _buildProgressIsland()),
                  const SizedBox(width: 14),
                  Expanded(child: _buildLogIsland()),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          // One Form over the whole grid: every field in every island must be
          // reachable from _formKey.currentState.validate().
          Form(
            key: _formKey,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSshIsland(),
                      const SizedBox(height: 14),
                      _buildVpnAccountIsland(),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDomainIsland(),
                      const SizedBox(height: 14),
                      _buildSecurityIsland(),
                    ],
                  ),
                ),
                if (canShowLast)
                  Selector<ServerSetupService, ServerSetupResult?>(
                    selector: (_, service) => service.lastResult,
                    builder: (context, result, _) => result == null
                        ? const SizedBox.shrink()
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(width: 14),
                              SizedBox(
                                width: 240,
                                child: _buildLastDeploymentIsland(result),
                              ),
                            ],
                          ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSshIsland() {
    final l10n = AppLocalizations.of(context)!;
    return _island(
      label: l10n.serverSectionSsh,
      icon: Icons.lock_outline,
      hint: l10n.serverSshSecretsHint,
      children: [
        _field(
          controller: _hostController,
          label: l10n.serverVpsIp,
          validator: _validateHost,
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: _field(
                controller: _sshUserController,
                label: l10n.serverSshUser,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _field(
                controller: _sshPortController,
                label: l10n.serverSshPort,
                keyboardType: TextInputType.number,
                validator: _validatePort,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        _buildAuthToggle(),
        const SizedBox(height: 10),
        if (_useKeyAuth)
          _field(
            controller: _sshKeyPathController,
            label: l10n.serverSshKeyPath,
            hintText: Platform.isWindows
                ? r'C:\Users\user\.ssh\id_rsa'
                : '~/.ssh/id_rsa',
            validator: (v) => _useKeyAuth && (v?.isEmpty ?? true)
                ? l10n.serverSshKeyPathError
                : null,
          )
        else
          _field(
            controller: _sshPasswordController,
            label: l10n.serverSshPassword,
            obscureText: !_sshPasswordVisible,
            validator: (v) => !_useKeyAuth && (v?.isEmpty ?? true)
                ? l10n.serverSshPasswordError
                : null,
            suffixIcon: _eyeButton(
              visible: _sshPasswordVisible,
              onPressed: () =>
                  setState(() => _sshPasswordVisible = !_sshPasswordVisible),
            ),
          ),
      ],
    );
  }

  Widget _buildDomainIsland() {
    final l10n = AppLocalizations.of(context)!;
    return _island(
      label: l10n.serverSectionDomain,
      icon: Icons.public,
      children: [
        _field(
          controller: _domainController,
          label: l10n.serverDomain,
          // The A-record requirement used to be a standing grey paragraph
          // under the field; it is an explanation, so it moved behind the
          // label's hint.
          hint: l10n.serverDomainHint,
          hintText: 'vpn.example.com',
          validator: (v) {
            final s = v?.trim() ?? '';
            if (s.isEmpty) {
              return l10n.serverDomainError;
            }
            if (!RegExp(
              r'^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$',
            ).hasMatch(s)) {
              return 'Enter a valid domain name (e.g. vpn.example.com)';
            }
            return null;
          },
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: _field(
                controller: _emailController,
                label: l10n.serverEmail,
                hint:
                    'Gets a free certificate during setup. '
                    'Renewal is left to the server.',
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) {
                    return l10n.serverEmailError;
                  }
                  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s)) {
                    return 'Enter a valid email address';
                  }
                  return null;
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _field(
                controller: _listenPortController,
                label: l10n.settingsPort,
                hint:
                    "Uses the port you choose, "
                    "or the next free one if it's taken.",
                keyboardType: TextInputType.number,
                validator: _validatePort,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVpnAccountIsland() {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return _island(
      label: l10n.serverSectionVpnAccount,
      icon: Icons.shield_outlined,
      children: [
        _field(
          controller: _vpnUsernameController,
          label: l10n.serverVpnUsername,
          validator: (v) =>
              (v?.isEmpty ?? true) ? l10n.serverVpnUsernameError : null,
        ),
        const SizedBox(height: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _fieldLabel(l10n.serverVpnPassword),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: _input(
                    controller: _vpnPasswordController,
                    obscureText: !_vpnPasswordVisible,
                    validator: (v) => (v?.isEmpty ?? true)
                        ? l10n.serverVpnPasswordError
                        : null,
                    suffixIcon: _eyeButton(
                      visible: _vpnPasswordVisible,
                      onPressed: () => setState(
                        () => _vpnPasswordVisible = !_vpnPasswordVisible,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // The artboard's generator: a 34px primary-tinted disc, the
                // same height as the field it sits beside. `filledTonal` came
                // out 38px tall in secondaryContainer with the theme's 8px
                // rounded rect over it, so it neither lined up nor matched.
                // The name rides on the button itself, not on a Tooltip
                // wrapped around it: an ancestor Tooltip annotates its own
                // semantics node, so the button's node stayed unnamed for a
                // screen reader. `tooltip:` puts the message inside the
                // button's node and keeps the hover text identical.
                IconButton(
                  tooltip: l10n.serverGeneratePassword,
                  onPressed: () {
                    setState(() {
                      _vpnPasswordController.text = _generatePassword();
                      _vpnPasswordVisible = true;
                    });
                  },
                  icon: const Icon(Icons.casino, size: 18),
                  style:
                      IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary.withValues(
                          alpha: 0.14,
                        ),
                        foregroundColor: theme.colorScheme.primary,
                        fixedSize: const Size.square(34),
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ).copyWith(
                        // `IconButton.styleFrom` synthesises an `overlayColor`
                        // from `foregroundColor` whenever one is passed —
                        // Material's own 8% hover / 10% press / 10% focus in
                        // that colour, with hover and press at effectively the
                        // same strength. A widget-level style outranks
                        // `iconButtonTheme`, so this disc was the one control
                        // on the screen still answering the pointer with
                        // Material's overlay after the theme replaced everyone
                        // else's. Restated as the app's shared tint, which
                        // does separate hover from pressed.
                        overlayColor: pointerOverlay(
                          theme.colorScheme.onSurface,
                        ),
                      ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSecurityIsland() {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    return _island(
      // No ARB key exists for this island's label.
      label: 'Security',
      icon: Icons.verified_user_outlined,
      children: [
        Row(
          children: [
            Expanded(
              child: _hintedText(
                // No ARB key exists for this switch's label.
                'Connection filtering',
                l10n.serverFilteringHint,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 10),
            // The kit's 32×18 toggle. Material's `Switch` was 52×32 with an
            // oversized thumb and a ripple halo behind it — three times the
            // area of anything else in this island, and the loudest Material
            // object left on the screen.
            //
            // The label beside it is a sibling `Text`, a separate semantics
            // node, so it does not name the control. The switch carries its
            // own accessible name instead, which also puts the label and the
            // on/off state on one node for a screen reader.
            AppSwitch(
              // No ARB key exists for this switch's label; this is the same
              // string the row already shows.
              semanticLabel: 'Connection filtering',
              value: _generatePrefix,
              onChanged: (v) => setState(() => _generatePrefix = v),
            ),
          ],
        ),
        // A consequence the user must read BEFORE deploying, and only while
        // the switch is on — so it stays on the screen rather than in a hint.
        //
        // It reflows now instead of appearing between two frames: the switch
        // above it answers the pointer in 120ms, and a panel that changes
        // height under a control that is itself moving has to move too. The
        // width is pinned to the island in both states, so only the height
        // animates and the text never re-wraps mid-flight.
        AnimatedSize(
          duration: kSurfaceChangeDuration,
          curve: kMotionCurve,
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: double.infinity,
            child: _generatePrefix
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      l10n.serverFilteringWarning,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: theme.extension<StatusColors>()!.connecting,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  /// Password / SSH key switch — the same two segments and the same state.
  Widget _buildAuthToggle() {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(
            value: false,
            label: Text(l10n.serverAuthPassword),
            icon: const Icon(Icons.lock, size: 16),
          ),
          ButtonSegment(
            value: true,
            label: Text(l10n.serverAuthKey),
            icon: const Icon(Icons.key, size: 16),
          ),
        ],
        selected: {_useKeyAuth},
        onSelectionChanged: (values) {
          setState(() => _useKeyAuth = values.first);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Phase 2 — an install is running
  // ---------------------------------------------------------------------

  Widget _buildRunningBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLockedSummary(),
        const SizedBox(height: 14),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 300, child: _buildProgressIsland()),
              const SizedBox(width: 14),
              Expanded(child: _buildLogIsland()),
            ],
          ),
        ),
      ],
    );
  }

  /// The form islands, read-only and dimmed, while the install owns the
  /// values. Nothing here is editable — the live fields are simply not in the
  /// tree, so their controllers keep exactly what was submitted.
  Widget _buildLockedSummary() {
    final l10n = AppLocalizations.of(context)!;
    final pw = _vpnPasswordController.text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _island(
            label: l10n.serverSectionSsh,
            icon: Icons.lock_outline,
            children: [
              _lockedValue(l10n.serverVpsIp, _hostController.text),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _lockedValue(
                      l10n.serverSshUser,
                      _sshUserController.text,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _lockedValue(
                      l10n.serverSshPort,
                      _sshPortController.text,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _island(
            label: l10n.serverSectionDomain,
            icon: Icons.public,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: _lockedValue(
                      l10n.serverDomain,
                      _domainController.text,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _lockedValue(
                      l10n.settingsPort,
                      _listenPortController.text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _lockedValue(l10n.serverEmail, _emailController.text),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _island(
            label: l10n.serverSectionVpnAccount,
            icon: Icons.shield_outlined,
            children: [
              _lockedValue(l10n.serverVpnUsername, _vpnUsernameController.text),
              const SizedBox(height: 10),
              _lockedValue(
                l10n.serverVpnPassword,
                '\u2022' * (pw.length > 24 ? 24 : pw.length),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Phase 3 — the install finished
  // ---------------------------------------------------------------------

  Widget _buildCompletedBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 288, child: _buildProgressIsland()),
              const SizedBox(width: 14),
              // The deployed values change once, when the install records its
              // result — not on the log lines that keep arriving behind it.
              Expanded(
                child: Selector<ServerSetupService, ServerSetupResult?>(
                  selector: (_, service) => service.lastResult,
                  builder: (context, result, _) => result == null
                      ? const SizedBox.shrink()
                      : _buildResultIsland(result),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(height: 176, child: _buildLogIsland()),
      ],
    );
  }

  /// What was actually deployed. Rendered from the recorded result, never from
  /// the raw text controllers — the installer may have moved to another port.
  Widget _buildResultIsland(ServerSetupResult result) {
    final theme = Theme.of(context);
    final status = theme.extension<StatusColors>()!;
    final l10n = AppLocalizations.of(context)!;

    return _island(
      // No ARB key exists for this island's label.
      label: 'Result',
      hint: l10n.serverApplyHint,
      fill: true,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, size: 20, color: status.connected),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.serverInstalled,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: status.connected,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _readOnlyField(l10n.serverDomain, result.domain),
                const SizedBox(height: 8),
                _readOnlyField(l10n.settingsPort, result.listenPort.toString()),
                const SizedBox(height: 8),
                _readOnlyField(l10n.serverVpnUsername, result.vpnUsername),
                if (result.clientRandomPrefix.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _buildPrefixRow(result.clientRandomPrefix),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildApplyButton(),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Checklist + log
  // ---------------------------------------------------------------------

  /// The seven real steps, the current one in the connecting colour and any
  /// failed one in the error colour, under a tinted state pill.
  Widget _buildProgressIsland() {
    // The checklist is a pure function of four values, and none of them is the
    // log. It used to be rebuilt by the screen-wide Consumer, so all seven
    // rows recomputed their icon, colour and weight on every streamed line;
    // now it redraws only when the step, the failed step, the error text or
    // the host-key flag actually moves.
    return Selector<ServerSetupService, (SetupStep, SetupStep?, String?, bool)>(
      selector: (_, service) => (
        service.currentStep,
        service.lastAttemptedStep,
        service.errorMessage,
        service.hostKeyMismatch,
      ),
      builder: (context, data, _) {
        final (step, lastAttempted, errorMessage, hostKeyMismatch) = data;
        final theme = Theme.of(context);
        final status = theme.extension<StatusColors>()!;
        final tone = _stateColor(step, status);
        final isFailed = step == SetupStep.failed;
        final allDone = step == SetupStep.completed;
        // On failure the checklist marks the step that actually broke (failed
        // itself has index -1, which would grey out the whole list).
        final currentIndex = isFailed
            ? (lastAttempted?.stepIndex ?? -1)
            : step.stepIndex;

        return _island(
          // No ARB key exists for this island's label.
          label: 'Progress',
          fill: true,
          children: [
            // The state pill is the live half of this island, and its tone
            // moves up to four times in a deployment (idle → connecting →
            // connected, or → error). It used to change between two frames.
            // One tween now drives the fill, the hairline, the glyph and the
            // label together on the shared state duration, so the pill reads
            // as one object changing state rather than as a new pill.
            //
            // The checklist rows underneath are deliberately left instant: a
            // step's glyph changes identity (pending → current → done), and a
            // checklist ticking is not a control answering a pointer.
            TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: tone),
              duration: kStateChangeDuration,
              curve: kMotionCurve,
              builder: (context, animatedTone, _) {
                final pill = animatedTone ?? tone;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: pill.withValues(alpha: 0.10),
                    border: Border.all(color: pill.withValues(alpha: 0.28)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(step.icon, size: 18, color: pill),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          step.displayText,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: pill,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The reason comes before the checklist, not after it:
                    // seven rows are taller than this island, so a banner
                    // underneath them sat clipped below the island's own
                    // scroll and the user never saw why the install stopped.
                    // The steps scroll under it instead.
                    if (errorMessage != null) ...[
                      // The state pill above already says "Installation
                      // failed", so the banner carries only what is new: the
                      // reason.
                      InfoBanner(
                        severity: BannerSeverity.error,
                        message: errorMessage,
                      ),
                      // Recovery path for a legitimate host-key change
                      // (rebuilt VPS): forget the stored fingerprint and retry.
                      if (hostKeyMismatch) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.key_off, size: 18),
                            label: const Text('Trust new host key & retry'),
                            onPressed: () async {
                              await context
                                  .read<ServerSetupService>()
                                  .trustNewHostKey();
                              await _startInstallation();
                            },
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                    ],
                    for (var i = 0; i < _steps.length; i++)
                      _buildStepRow(
                        _steps[i],
                        theme: theme,
                        status: status,
                        currentIndex: currentIndex,
                        isFailed: isFailed,
                        allDone: allDone,
                        first: i == 0,
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildStepRow(
    SetupStep step, {
    required ThemeData theme,
    required StatusColors status,
    required int currentIndex,
    required bool isFailed,
    required bool allDone,
    required bool first,
  }) {
    final stepIndex = step.stepIndex;

    IconData icon;
    Color iconColor;
    Color textColor;
    FontWeight weight = FontWeight.normal;

    if (stepIndex < currentIndex || allDone) {
      icon = Icons.check_circle;
      iconColor = status.connected;
      textColor = theme.colorScheme.onSurface.withValues(alpha: 0.85);
    } else if (stepIndex == currentIndex) {
      if (isFailed) {
        icon = Icons.error;
        iconColor = status.error;
        textColor = status.error;
      } else {
        icon = Icons.radio_button_checked;
        iconColor = status.connecting;
        textColor = theme.colorScheme.onSurface;
      }
      weight = FontWeight.w600;
    } else {
      icon = Icons.radio_button_unchecked;
      iconColor = status.idle.withValues(alpha: 0.5);
      textColor = _dim(theme);
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: first
          ? null
          : BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              step.displayText.replaceAll('...', ''),
              style: TextStyle(
                fontSize: 13,
                color: textColor,
                fontWeight: weight,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogIsland() {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return _island(
      label: l10n.serverInstallLog,
      icon: Icons.terminal,
      fill: true,
      // A quiet control inside a 20px island header: the themed 34px would
      // push the header open, and the themed primary foreground would compete
      // with the section label. Height, padding and colour are the local
      // intent; the 8px radius still comes from the theme.
      trailing: TextButton.icon(
        onPressed: context.read<ServerSetupService>().clearLogs,
        icon: const Icon(Icons.delete_outline, size: 16),
        label: Text(l10n.commonClear),
        style:
            TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              textStyle: const TextStyle(fontSize: 12.5),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ).copyWith(
              // `TextButton.styleFrom` derives an overlay from
              // `foregroundColor` for the same reason `IconButton` does, and
              // shadows `textButtonTheme` the same way. Without this, the only
              // control in the log island's header hovered in
              // `onSurfaceVariant` at Material's alphas while every other
              // button on the screen hovered in the shared tint.
              overlayColor: pointerOverlay(theme.colorScheme.onSurface),
            ),
      ),
      children: [
        // Everything above is fixed for the life of the phase; only the well
        // below follows the stream. `logs` returns a fresh list every call, so
        // a list-valued selector would never compare equal and would rebuild
        // on every notification — including the step changes that leave the
        // log untouched. A fingerprint does compare: below the 1000-line cap
        // an append moves the length, and at the cap the buffer drops from the
        // front, so the first line moves instead.
        Expanded(
          child: Selector<ServerSetupService, (int, String, String)>(
            selector: (_, service) {
              final logs = service.logs;
              return logs.isEmpty
                  ? (0, '', '')
                  : (logs.length, logs.first, logs.last);
            },
            builder: (context, _, _) => _buildLogWell(
              theme,
              l10n,
              context.read<ServerSetupService>().logs,
            ),
          ),
        ),
      ],
    );
  }

  /// [logs] is passed in, not read twice: `ServerSetupService.logs` is
  /// `List.unmodifiable(...)`, which copies the whole 1000-line buffer on
  /// every access.
  Widget _buildLogWell(
    ThemeData theme,
    AppLocalizations l10n,
    List<String> logs,
  ) {
    // Auto-scroll the log panel (never the page), and only when the user is
    // already near the bottom — scrolling up to read must not be fought.
    // Proximity is captured BEFORE the new lines are laid out: checking it
    // inside the post-frame callback compares against the already-grown
    // maxScrollExtent, so any multi-line burst would permanently stop the
    // autoscroll. Scheduling now costs one callback per log change instead of
    // one per notification, which is what the screen-wide Consumer produced.
    final wasNearBottom =
        !_logScrollController.hasClients ||
        _logScrollController.position.maxScrollExtent -
                _logScrollController.position.pixels <=
            150;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!wasNearBottom || !_logScrollController.hasClients) return;
      // jumpTo, not animateTo: an in-flight animation lags behind fast log
      // streams and would break the near-bottom check on the next line.
      _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
    });

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: _insetDecoration(theme),
      child: logs.isEmpty
          ? Center(
              child: Text(
                l10n.serverLogEmpty,
                style: TextStyle(fontSize: 12.5, color: _dim(theme)),
              ),
            )
          : SingleChildScrollView(
              controller: _logScrollController,
              child: SelectableText(
                logs.join('\n'),
                style: _mono(
                  size: 11.5,
                  height: 1.75,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
    );
  }

  // ---------------------------------------------------------------------
  // Last deployment (side column) + apply
  // ---------------------------------------------------------------------

  /// Shown when the app was restarted after a successful deploy: the in-memory
  /// config is gone, but the persisted result still lets the user apply the
  /// server (crucially, with the generated prefix intact).
  Widget _buildLastDeploymentIsland(ServerSetupResult result) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;

    return _island(
      // No ARB key exists for this island's label.
      label: 'Last deployment',
      icon: Icons.history,
      hint: l10n.serverApplyHint,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: _insetDecoration(theme),
          child: SelectableText(
            '${result.domain} (${result.host}:${result.listenPort}), '
            'user ${result.vpnUsername}',
            style: _mono(
              size: 11.5,
              height: 1.6,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        if (result.clientRandomPrefix.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildPrefixRow(result.clientRandomPrefix),
        ],
        const SizedBox(height: 10),
        Text(
          l10n.serverRestoredNote,
          style: TextStyle(fontSize: 11.5, height: 1.55, color: _dim(theme)),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.only(top: 12),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: _buildApplyButton(),
        ),
      ],
    );
  }

  /// The generated TLS client_random_prefix with a copy button — without this
  /// exact value the server ignores the client, so make it easy to save
  /// somewhere safe.
  Widget _buildPrefixRow(String prefix) {
    final theme = Theme.of(context);
    final status = theme.extension<StatusColors>()!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: status.connected.withValues(alpha: 0.10),
        border: Border.all(color: status.connected.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 18, color: status.connected),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              'Filtering prefix: $prefix',
              style: _mono(
                size: 11.5,
                height: 1.6,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          // 28×28 glyph, radius 8, onSurfaceVariant — all of it themed now;
          // the local `color:` said what iconButtonTheme already says.
          IconButton(
            tooltip: 'Copy prefix',
            icon: const Icon(Icons.copy, size: 16),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: prefix));
              showAppSnackBar(
                context,
                'Prefix copied to clipboard',
                kind: SnackKind.success,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildApplyButton() {
    // The artboard's 34px / radius-8 primary — which is exactly the theme's
    // filled button. The old styleFrom forced 38px and restated the radius,
    // and the label restated the themed 13/600 text style.
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _applyToClient,
        icon: const Icon(Icons.tune, size: 18),
        label: Text(AppLocalizations.of(context)!.serverApplySettings),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Island / field vocabulary
  // ---------------------------------------------------------------------

  /// One island: a flat card with a hairline outline, a single sentence-case
  /// section heading and one job. [fill] makes its content column fill the
  /// island (for the ones that own an Expanded child).
  Widget _island({
    required String label,
    required List<Widget> children,
    IconData? icon,
    String? hint,
    Widget? trailing,
    bool fill = false,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: _dim(theme)),
                  const SizedBox(width: 8),
                ],
                // The label group owns the free space so [trailing] sits hard
                // against the right edge. A loose Flexible beside a Spacer
                // would split that space between them and leave the trailing
                // control floating short of the edge.
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          overflow: TextOverflow.ellipsis,
                          // Sans, sentence case, no tracking. A tiny
                          // letter-spaced mono word in caps is the house style
                          // of generated dashboards and is harder to read than
                          // the sentence-case sans it replaced; mono is kept
                          // for values where character alignment is the point.
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
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
                            color: _dim(theme),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  /// A field label, with its format explanation tucked behind an info glyph.
  Widget _fieldLabel(String label, {String? hint}) {
    final theme = Theme.of(context);
    final style = TextStyle(
      fontSize: 11,
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (hint == null) {
      return Text(label, style: style, overflow: TextOverflow.ellipsis);
    }
    return _hintedText(label, hint, style: style);
  }

  Widget _hintedText(String label, String hint, {required TextStyle style}) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Flexible(
          child: Text(label, style: style, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: hint,
          child: Icon(Icons.info_outline, size: 15, color: _dim(theme)),
        ),
      ],
    );
  }

  /// Label above, inset well below — the artboard's field recipe.
  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool obscureText = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    Widget? suffixIcon,
    String? hintText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _fieldLabel(label, hint: hint),
        const SizedBox(height: 5),
        _input(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          validator: validator,
          suffixIcon: suffixIcon,
          hintText: hintText,
        ),
      ],
    );
  }

  Widget _input({
    required TextEditingController controller,
    bool obscureText = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    Widget? suffixIcon,
    String? hintText,
  }) {
    final theme = Theme.of(context);
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      style: _mono(size: 12.5, color: theme.colorScheme.onSurface),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 11,
        ),
        hintText: hintText,
        hintStyle: _mono(size: 12.5, color: _dim(theme)),
        errorStyle: const TextStyle(fontSize: 11.5),
        errorMaxLines: 2,
        suffixIcon: suffixIcon,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 34,
          minHeight: 34,
        ),
      ),
    );
  }

  /// The reveal glyph inside a password field's suffix slot. Sized to the
  /// 34px field so the input keeps its height; the colour and the 8px radius
  /// are the theme's. The tooltip is also its accessible name — the glyph is
  /// all a sighted user gets, and a screen reader got nothing at all.
  Widget _eyeButton({required bool visible, required VoidCallback onPressed}) {
    return IconButton(
      tooltip: visible ? 'Hide password' : 'Show password',
      icon: Icon(visible ? Icons.visibility_off : Icons.visibility, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      onPressed: onPressed,
    );
  }

  /// A value the user can read but not edit — the deployed result.
  Widget _readOnlyField(String label, String value) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _fieldLabel(label),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: _insetDecoration(theme),
          child: SelectableText(
            value,
            style: _mono(size: 12.5, color: theme.colorScheme.onSurface),
          ),
        ),
      ],
    );
  }

  /// A value locked by a running install: the same well, dimmed.
  ///
  /// The wash is applied to the colours, not with an `Opacity` widget. Six of
  /// these sit in the summary strip, and each `Opacity` was a `saveLayer` in
  /// the one phase where the window repaints continuously.
  Widget _lockedValue(String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            // Was `onSurfaceVariant` at 55%: 2.7:1 dark, 2.5:1 light — the
            // locked phase dimmed its labels out of legibility. The dim tone
            // keeps them a step under the value beside them and readable.
            color: dimTextOf(scheme),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          height: 34,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.55),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _mono(
              size: 12.5,
              // 72%, not the old 60%: the value must stay clearly stronger
              // than its now-readable label, and 60% left the light theme at
              // 4.8:1 — over the floor by a hair. Still visibly locked.
              color: scheme.onSurface.withValues(alpha: 0.72),
            ),
          ),
        ),
      ],
    );
  }

  BoxDecoration _insetDecoration(ThemeData theme) => BoxDecoration(
    color: theme.colorScheme.surfaceContainerLowest,
    border: Border.all(color: theme.colorScheme.outlineVariant),
    borderRadius: BorderRadius.circular(12),
  );

  /// Section labels, captions and placeholders sit one step quieter than
  /// secondary text — but still readable. This used to fade
  /// `onSurfaceVariant` to 72%, which landed at 3.7:1 on the dark card and
  /// 3.5:1 on the light one, under the 4.5:1 floor; the theme's dim tone is
  /// the same step in the hierarchy and clears it on every surface here.
  Color _dim(ThemeData theme) => dimTextOf(theme.colorScheme);

  /// The status colour for a step, from StatusColors — the enum's own
  /// `color` getter still returns raw Material constants.
  Color _stateColor(SetupStep step, StatusColors status) => switch (step) {
    SetupStep.idle => status.idle,
    SetupStep.completed => status.connected,
    SetupStep.failed => status.error,
    _ => status.connecting,
  };

  /// Values the user reads as data: hostnames, ports, prefixes, log lines.
  TextStyle _mono({
    double size = 12.5,
    Color? color,
    FontWeight? weight,
    double? height,
    double? spacing,
  }) {
    return TextStyle(
      fontFamily: kMonoFontStack.first,
      fontFamilyFallback: _kMonoFallback,
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: height,
      letterSpacing: spacing,
    );
  }
}

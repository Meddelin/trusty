import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/vpn_status.dart';
import '../services/vpn_service.dart';
import '../services/config_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<VpnService, (VpnStatus, String?)>(
      selector: (_, vpn) => (vpn.status, vpn.errorMessage),
      builder: (context, record, child) {
        final vpnService = context.read<VpnService>();
        final status = record.$1;

        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Update banner
                _buildUpdateBanner(context),

                // Status hero: breathing ring while connected, rotating
                // icon while connecting.
                _StatusHero(status: status),

                const SizedBox(height: 32),

                // Status Text
                Text(
                  status.displayText,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: status.colorOf(context),
                        fontWeight: FontWeight.bold,
                      ),
                ),

                if (status == VpnStatus.connected &&
                    vpnService.connectedAt != null) ...[
                  const SizedBox(height: 4),
                  _ConnectionTimer(since: vpnService.connectedAt!),
                ],

                const SizedBox(height: 32),

                // Quick server switcher (hidden when only one server is saved)
                _buildServerSwitcher(context, status),

                const SizedBox(height: 16),

                // Connect/Disconnect Button
                _buildMainButton(context, vpnService, status),

                const SizedBox(height: 24),

                // Error Message
                if (status == VpnStatus.error && vpnService.errorMessage != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: InfoBanner(
                      severity: BannerSeverity.error,
                      title: 'Connection failed',
                      message: vpnService.errorMessage!,
                    ),
                  ),

                // Info Card
                if (status == VpnStatus.disconnected) ...[
                  const SizedBox(height: 24),
                  _buildInfoCard(context),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildUpdateBanner(BuildContext context) {
    return Consumer<UpdateService>(
      builder: (context, updates, _) {
        if (!updates.updateAvailable) return const SizedBox.shrink();
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: InfoBanner(
            // Keyed by version so a NEW release rebuilds the banner even if
            // the widget stays alive in the IndexedStack.
            key: ValueKey(updates.latestVersion),
            severity: BannerSeverity.info,
            message: AppLocalizations.of(context)!
                .homeUpdateAvailable(updates.latestVersion!),
            margin: const EdgeInsets.only(bottom: 24),
            actions: [
              TextButton(
                onPressed: updates.openReleasePage,
                child: Text(AppLocalizations.of(context)!.homeUpdateDownload),
              ),
            ],
            onDismiss: updates.dismiss,
          ),
        );
      },
    );
  }

  /// Dropdown to switch the active server without opening Settings; with a
  /// single saved server it shows a static tile naming it. Reads the
  /// synchronous server cache — no per-rebuild futures.
  Widget _buildServerSwitcher(BuildContext context, VpnStatus status) {
    return Consumer<ConfigService>(
      builder: (context, configService, _) {
        final servers = configService.serversCache;
        final activeId = configService.activeServerIdCache;
        if (servers.isEmpty) {
          // Kick the one-time initial load; the cache fill notifies and
          // this Consumer rebuilds.
          configService.loadServers();
          return const SizedBox.shrink();
        }
        final hasActive = servers.any((s) => s.id == activeId);

        // Single server: show WHICH server this is, without a dropdown.
        if (servers.length < 2) {
          final s = servers.first;
          return Container(
            width: 280,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.dns,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    s.displayLabel.isEmpty ? '(unnamed)' : s.displayLabel,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          );
        }

        return Container(
          width: 280,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: DropdownButton<String>(
            value: hasActive ? activeId : null,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(12),
            items: servers
                .map(
                  (s) => DropdownMenuItem(
                    value: s.id,
                    child: Row(
                      children: [
                        Icon(
                          Icons.dns,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            s.displayLabel.isEmpty
                                ? '(unnamed)'
                                : s.displayLabel,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                .toList(),
            onChanged: status.isActive
                ? null
                : (id) {
                    if (id != null && id != activeId) {
                      configService.switchServer(id);
                    }
                  },
          ),
        );
      },
    );
  }

  Widget _buildMainButton(
    BuildContext context,
    VpnService vpnService,
    VpnStatus status,
  ) {
    final isLoading = status == VpnStatus.connecting ||
        status == VpnStatus.disconnecting;

    // Connect is the green CTA; Disconnect is a calm tonal button (red is
    // reserved for errors). Colors come from the theme's status tokens.
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).extension<StatusColors>() ??
        StatusColors.light;
    final isConnectedish =
        status == VpnStatus.connected || status == VpnStatus.disconnecting;
    final buttonColor =
        isConnectedish ? scheme.secondaryContainer : tokens.connected;
    final onButtonColor =
        isConnectedish ? scheme.onSecondaryContainer : Colors.white;

    return SizedBox(
      width: 280,
      height: 64,
      child: ElevatedButton(
        onPressed: isLoading
            ? null
            : () => _handleButtonPress(context, vpnService, status),
        style: ElevatedButton.styleFrom(
          backgroundColor: buttonColor,
          foregroundColor: onButtonColor,
          // Keep the accent color while disabled (connecting/disconnecting)
          // instead of flashing the default grey between states.
          disabledBackgroundColor: buttonColor.withValues(alpha: 0.7),
          disabledForegroundColor: onButtonColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(32),
          ),
          elevation: 0,
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: isLoading
              ? Row(
                  key: const ValueKey('loading'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(onButtonColor),
                      ),
                    ),
                    SizedBox(width: 12),
                    Text(
                      AppLocalizations.of(context)!.homePleaseWait,
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ],
                )
              : Row(
                  key: ValueKey(status == VpnStatus.connected),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      status == VpnStatus.connected
                          ? Icons.stop_circle_outlined
                          : Icons.play_circle_outline,
                      size: 28,
                    ),
                    SizedBox(width: 12),
                    Text(
                      status == VpnStatus.connected
                          ? AppLocalizations.of(context)!.homeDisconnect
                          : AppLocalizations.of(context)!.homeConnect,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context) {
    // First-run onboarding: dismissible, stays hidden forever once closed.
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: InfoBanner(
        severity: BannerSeverity.info,
        title: AppLocalizations.of(context)!.homeInfoTitle,
        message:
            '• ${AppLocalizations.of(context)!.homeInfoLine1}\n'
            '• ${Platform.isWindows ? AppLocalizations.of(context)!.homeInfoLineClientWindows : AppLocalizations.of(context)!.homeInfoLineClientOther}\n'
            '• ${AppLocalizations.of(context)!.homeInfoLine3}',
        dismissKey: 'home_intro',
      ),
    );
  }

  Future<void> _handleButtonPress(
    BuildContext context,
    VpnService vpnService,
    VpnStatus status,
  ) async {
    if (status == VpnStatus.connected) {
      await vpnService.disconnect();
      return;
    }

    final configService = context.read<ConfigService>();
    final config = await configService.loadConfig();

    // Refuse to "connect" to the factory placeholder — it would look green
    // while tunneling nothing.
    if (config.isPlaceholder) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          'Add your server details in Settings before connecting',
          kind: SnackKind.warning,
        );
      }
      return;
    }

    // Errors surface via VpnStatus.error + the error card on this screen.
    await vpnService.connect(config);
  }
}

/// The 160px status circle with motion where it matters: a breathing outer
/// ring while connected, a rotating sync icon while connecting, and an
/// animated icon/color switch on every state change. No packages — one
/// AnimationController.
class _StatusHero extends StatefulWidget {
  final VpnStatus status;

  const _StatusHero({required this.status});

  @override
  State<_StatusHero> createState() => _StatusHeroState();
}

class _StatusHeroState extends State<_StatusHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _StatusHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _syncAnimation();
  }

  void _syncAnimation() {
    switch (widget.status) {
      case VpnStatus.connected:
        _controller.repeat(reverse: true); // breathing ring
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        _controller.repeat(); // rotation
      case VpnStatus.disconnected:
      case VpnStatus.error:
        _controller.stop();
        _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.status.colorOf(context);
    final spinning = widget.status == VpnStatus.connecting ||
        widget.status == VpnStatus.disconnecting;
    final breathing = widget.status == VpnStatus.connected;

    Widget icon = Icon(
      widget.status.icon,
      key: ValueKey(widget.status.icon),
      size: 80,
      color: color,
    );
    if (spinning) {
      icon = RotationTransition(turns: _controller, child: icon);
    }

    return SizedBox(
      width: 190,
      height: 190,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (breathing)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = _controller.value;
                return Container(
                  width: 160 + 24 * t,
                  height: 160 + 24 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color.withValues(alpha: 0.35 * (1 - t)),
                      width: 3,
                    ),
                  ),
                );
              },
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.1),
              border: Border.all(color: color, width: 4),
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: icon,
            ),
          ),
        ],
      ),
    );
  }
}

/// Ticking "how long have I been connected" line.
class _ConnectionTimer extends StatefulWidget {
  final DateTime since;

  const _ConnectionTimer({required this.since});

  @override
  State<_ConnectionTimer> createState() => _ConnectionTimerState();
}

class _ConnectionTimerState extends State<_ConnectionTimer> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.since);
    String two(int n) => n.toString().padLeft(2, '0');
    final text = d.inHours > 0
        ? '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}'
        : '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
    return Text(
      text,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.outline,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/routing_list.dart';
import '../models/server_config.dart';
import '../models/vpn_status.dart';
import '../services/vpn_service.dart';
import '../services/config_service.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import '../utils/log_level.dart';
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';

// --- shared text styles ---------------------------------------------------

/// The fallback stack, resolved once. `kMonoFontStack.sublist(1)` allocates a
/// new list on every call, and [_mono] is called three times per visible log
/// line — that copy used to run on every ~10fps log notification.
final List<String> _kMonoFallback = kMonoFontStack.sublist(1);

/// Values the user reads as data: hosts, addresses, ports, counts, timers,
/// log lines.
TextStyle _mono({
  required double size,
  Color? color,
  FontWeight? weight,
  double? letterSpacing,
  bool tabular = false,
}) {
  return TextStyle(
    fontFamily: kMonoFontStack.first,
    fontFamilyFallback: _kMonoFallback,
    fontSize: size,
    color: color,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );
}

/// Home — the control panel. A status strip across the top (state, active
/// server, endpoint, uptime, the primary action), three read-only state
/// islands (tunnel / security / DNS) and the tail of the live log.
///
/// Everything below the strip is a summary of state the app already holds:
/// no island navigates anywhere and none of them can change a setting.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final ConfigService _configService;

  /// Active config (DNS, split-tunnel mode and lists, security flags). Null
  /// until the first async load lands; the strip falls back to the server
  /// cache so the first frame is never empty.
  ServerConfig? _config;
  List<RoutingList> _routingLists = const [];

  /// Reload coalescing: a burst of saves must not queue a stack of loads.
  bool _loading = false;
  bool _reloadQueued = false;

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
    if (_loading) {
      _reloadQueued = true;
      return;
    }
    _loading = true;
    try {
      do {
        _reloadQueued = false;
        final config = await _configService.loadConfig();
        final lists = await _configService.loadRoutingLists();
        if (!mounted) return;
        setState(() {
          _config = config;
          _routingLists = lists;
        });
      } while (_reloadQueued);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Selector<VpnService, (VpnStatus, String?)>(
      selector: (_, vpn) => (vpn.status, vpn.errorMessage),
      builder: (context, record, child) {
        final vpnService = context.read<VpnService>();
        final status = record.$1;
        final errorMessage = record.$2;

        // The banner is the authoritative error surface: it carries the title
        // and the full reason. The tail of the live log carries the same
        // failure verbatim, so while the banner is up the log island stands
        // down and the islands take its height — the user reads the error
        // once. Every other state keeps the live console.
        final showError = status == VpnStatus.error && errorMessage != null;

        // The intro line names the Servers tab, so it is only true while the
        // factory placeholder is still in place. Dismissal is permanent.
        final showIntro =
            status == VpnStatus.disconnected &&
            (_config?.isPlaceholder ?? false);

        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // const: neither the update banner nor the log island reads
              // anything from this build, so a config reload (setState) or a
              // status change skips both subtrees entirely.
              const _UpdateBanner(),
              _buildStatusStrip(context, vpnService, status),
              const SizedBox(height: 14),
              if (showError)
                InfoBanner(
                  severity: BannerSeverity.error,
                  title: 'Connection failed',
                  message: errorMessage,
                  margin: const EdgeInsets.only(bottom: 14),
                ),
              if (showIntro)
                InfoBanner(
                  severity: BannerSeverity.info,
                  message: AppLocalizations.of(context)!.homeInfoLine1,
                  dismissKey: 'home_intro',
                  margin: const EdgeInsets.only(bottom: 14),
                ),
              // Three state islands edge to edge, then the log filling the
              // rest. The islands want 194px but must yield on a short
              // window, so the split is measured here rather than left to
              // the Column: a loose Flexible sharing a Column with an
              // Expanded gets half the free space each, which would strand
              // the log short of the bottom on any tall window.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final islands = _buildIslandsRow(context);
                    // Error state: no log island, so the islands own the
                    // whole remaining column.
                    if (showError) return islands;
                    final free = constraints.maxHeight - 14;
                    final islandsHeight = free <= 0
                        ? 0.0
                        : math.min(194.0, free / 2);
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(height: islandsHeight, child: islands),
                        const SizedBox(height: 14),
                        const Expanded(child: _LogIsland()),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildIslandsRow(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _buildTunnelIsland(context)),
        const SizedBox(width: 14),
        Expanded(child: _buildSecurityIsland(context)),
        const SizedBox(width: 14),
        Expanded(child: _buildDnsIsland(context)),
      ],
    );
  }

  // --- status strip -------------------------------------------------------

  Widget _buildStatusStrip(
    BuildContext context,
    VpnService vpnService,
    VpnStatus status,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = status.colorOf(context);
    final showUptime =
        status == VpnStatus.connected && vpnService.connectedAt != null;
    final socksAddress = status == VpnStatus.connected
        ? vpnService.socksAddress
        : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          _StatusDot(status: status),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // The state word: the loudest thing on the screen, so it
                    // reads as a word — sans, sentence case, no tracking.
                    // Colour animates with the state.
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      // AnimatedDefaultTextStyle REPLACES the inherited
                      // style, so the family must be named here too.
                      style: TextStyle(
                        fontFamily: kUiFont,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                      child: Text(status.displayText),
                    ),
                    const SizedBox(width: 14),
                    Container(width: 1, height: 14, color: scheme.outline),
                    const SizedBox(width: 14),
                    Flexible(child: _buildServerSwitcher(context, status)),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  _endpointLine(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _mono(size: 12, color: scheme.onSurfaceVariant),
                ),
                // SOCKS5 mode: there is no system-wide tunnel — show the
                // proxy address apps must be pointed at.
                if (socksAddress != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    AppLocalizations.of(context)!.homeSocksProxy(socksAddress),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _mono(size: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          if (showUptime) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The bare timer would read as a wall clock, so the label
                // stays — as a sentence-case sans heading, not a tracked tag.
                Text(
                  'Uptime',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                _ConnectionTimer(since: vpnService.connectedAt!),
              ],
            ),
            const SizedBox(width: 20),
          ],
          _buildMainButton(context, vpnService, status),
        ],
      ),
    );
  }

  /// `host · ip:port · protocol · mode` — everything the connection is,
  /// in one mono line. Falls back to the active server-list entry until the
  /// first config load lands.
  String _endpointLine(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final config = _config;
    ServerConfig? entry;
    for (final s in _configService.serversCache) {
      if (s.id == _configService.activeServerIdCache) entry = s;
    }
    final source = config ?? entry;
    if (source == null) return '';

    final protocol = switch (source.upstreamProtocol) {
      'http2' => 'HTTP/2',
      'http3' => 'HTTP/3',
      final p => p.toUpperCase(),
    };
    final mode =
        (config?.connectionMode ?? _configService.connectionModeCache) ==
            'socks5'
        ? l10n.settingsConnectionModeSocks
        : l10n.settingsConnectionModeTun;

    return '${source.hostname} · ${source.address}:${source.port} · '
        '$protocol · $mode';
  }

  /// Inline switcher for the active server; with a single saved server it
  /// shows a static label naming it. Reads the synchronous server cache —
  /// no per-rebuild futures.
  Widget _buildServerSwitcher(BuildContext context, VpnStatus status) {
    return Consumer<ConfigService>(
      builder: (context, configService, _) {
        final scheme = Theme.of(context).colorScheme;
        final servers = configService.serversCache;
        final activeId = configService.activeServerIdCache;
        if (servers.isEmpty) {
          // Kick the one-time initial load; the cache fill notifies and
          // this Consumer rebuilds.
          configService.loadServers();
          return const SizedBox.shrink();
        }
        final hasActive = servers.any((s) => s.id == activeId);

        Widget label(ServerConfig s, {bool dim = false, bool chevron = false}) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.dns, size: 15, color: dimTextOf(scheme)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  s.displayLabel.isEmpty ? '(unnamed)' : s.displayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: dim ? dimTextOf(scheme) : scheme.onSurface,
                  ),
                ),
              ),
              if (chevron) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.expand_more,
                  size: 14,
                  color: dim ? dimTextOf(scheme) : scheme.onSurfaceVariant,
                ),
              ],
            ],
          );
        }

        // Single server: show WHICH server this is, without a dropdown.
        if (servers.length < 2) return label(servers.first);

        final active = hasActive
            ? servers.firstWhere((s) => s.id == activeId)
            : servers.first;

        return DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: hasActive ? activeId : null,
            isDense: true,
            icon: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(12),
            dropdownColor: scheme.surfaceContainerHigh,
            // The strip draws its own compact row; the menu keeps full rows.
            selectedItemBuilder: (context) =>
                servers.map((s) => label(s, chevron: true)).toList(),
            disabledHint: label(active, dim: true, chevron: true),
            items: servers
                .map((s) => DropdownMenuItem(value: s.id, child: label(s)))
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
    final isLoading =
        status == VpnStatus.connecting || status == VpnStatus.disconnecting;

    // Connect is the green CTA; Disconnect is a calm tonal button (red is
    // reserved for errors). Colors come from the theme's status tokens.
    final scheme = Theme.of(context).colorScheme;
    final tokens =
        Theme.of(context).extension<StatusColors>() ?? StatusColors.light;
    final isConnectedish =
        status == VpnStatus.connected || status == VpnStatus.disconnecting;
    final buttonColor = isConnectedish
        ? scheme.secondaryContainer
        : tokens.connected;
    final onButtonColor = isConnectedish
        ? scheme.onSecondaryContainer
        : scheme.onPrimary;

    // The one control on this screen that is deliberately not the themed
    // 34px button: the artboard's status-strip action is 44px tall with a
    // 10px radius and a 150px floor, so only those three things plus the
    // status colouring are restated here.
    return FilledButton(
      onPressed: isLoading
          ? null
          : () => _handleButtonPress(context, vpnService, status),
      style: FilledButton.styleFrom(
        backgroundColor: buttonColor,
        foregroundColor: onButtonColor,
        // Keep the accent color while disabled (connecting/disconnecting)
        // instead of flashing the default grey between states.
        disabledBackgroundColor: buttonColor.withValues(alpha: 0.7),
        disabledForegroundColor: onButtonColor,
        minimumSize: const Size(150, 44),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(
          fontFamily: kUiFont,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: isLoading
            ? Row(
                key: const ValueKey('loading'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(onButtonColor),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Text(AppLocalizations.of(context)!.homePleaseWait),
                ],
              )
            : Row(
                key: ValueKey(status == VpnStatus.connected),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    status == VpnStatus.connected
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    size: 18,
                  ),
                  const SizedBox(width: 9),
                  Text(
                    status == VpnStatus.connected
                        ? AppLocalizations.of(context)!.homeDisconnect
                        : AppLocalizations.of(context)!.homeConnect,
                  ),
                ],
              ),
      ),
    );
  }

  // --- islands ------------------------------------------------------------

  /// Split-tunnel mode and how much is on the list. Read-only: the rules
  /// themselves live on the Split Tunnel tab.
  Widget _buildTunnelIsland(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final config = _config;
    final selective = config?.vpnMode == VpnMode.selective;
    final proxy =
        (config?.connectionMode ?? _configService.connectionModeCache) ==
        'socks5';

    final title = selective
        ? l10n.splitTunnelModeSelectiveTitle
        : l10n.splitTunnelModeGeneralTitle;
    final subtitle = selective
        ? (proxy
              ? l10n.splitTunnelModeSelectiveSubtitleProxy
              : l10n.splitTunnelModeSelectiveSubtitle)
        : (proxy
              ? l10n.splitTunnelModeGeneralSubtitleProxy
              : l10n.splitTunnelModeGeneralSubtitle);

    final enabledLists = _routingLists.where((l) => l.enabled).length;

    return _Island(
      label: 'Tunnel',
      // The readouts are pinned to the bottom with a Spacer, so this column
      // has a hard minimum height. When banners squeeze the islands row below
      // it (a long connection error plus an update notice on a short window)
      // the island scrolls instead of painting over its own border — the
      // other two islands already scroll for the same reason.
      body: _fillOrScroll(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const Spacer(),
            _ReadoutRow('Domains', '${config?.splitTunnelDomains.length ?? 0}'),
            const SizedBox(height: 8),
            _ReadoutRow('Apps', '${config?.splitTunnelApps.length ?? 0}'),
            const SizedBox(height: 8),
            _ReadoutRow(
              'Routing lists',
              '$enabledLists of ${_routingLists.length}',
            ),
          ],
        ),
      ),
    );
  }

  /// Fills the available height when there is room (so a `Spacer` inside
  /// [child] still pins content to the bottom) and scrolls when there is not.
  Widget _fillOrScroll(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: IntrinsicHeight(child: child),
        ),
      ),
    );
  }

  /// The active server's protocol flags, as they will be written into the
  /// client config on the next connect. Never green — green is reserved for
  /// connected and success.
  Widget _buildSecurityIsland(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final config = _config;

    Widget flag(String label, bool on) =>
        _ReadoutRow(label, on ? 'on' : 'off', dim: !on);

    final hasPrefix = (config?.clientRandomPrefix ?? '').isNotEmpty;

    return _Island(
      label: 'Security',
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            flag(l10n.settingsAntiDpi, config?.antiDpi ?? false),
            const SizedBox(height: 10),
            flag(
              l10n.settingsPostQuantum,
              config?.postQuantumGroupEnabled ?? false,
            ),
            const SizedBox(height: 10),
            flag(l10n.settingsIpv6, config?.hasIpv6 ?? false),
            const SizedBox(height: 10),
            _ReadoutRow(
              'Client random prefix',
              hasPrefix ? 'set' : 'not set',
              dim: !hasPrefix,
            ),
            const SizedBox(height: 10),
            flag(
              l10n.settingsSkipVerification,
              config?.skipVerification ?? false,
            ),
          ],
        ),
      ),
    );
  }

  /// The shared DNS upstreams, one inset well each.
  Widget _buildDnsIsland(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final upstreams = _config?.dnsUpstreamList ?? const <String>[];

    return _Island(
      label: 'DNS',
      body: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: upstreams.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Text(
            upstreams[index],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _mono(size: 11.5, color: scheme.onSurface),
          ),
        ),
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
          AppLocalizations.of(context)!.homeInfoLine1,
          kind: SnackKind.warning,
        );
      }
      return;
    }

    // Errors surface via VpnStatus.error + the error banner on this screen.
    await vpnService.connect(config);

    // Soft limit on merged exclusions: warn (never block) when routing
    // lists inflated the config enough to slow tunnel setup down.
    final merged = configService.lastMergedExclusionCount;
    if (context.mounted && merged > ConfigService.mergedExclusionsSoftLimit) {
      showAppSnackBar(
        context,
        AppLocalizations.of(context)!.splitTunnelExclusionLimitWarning(
          merged,
          ConfigService.mergedExclusionsSoftLimit,
        ),
        kind: SnackKind.warning,
      );
    }
  }
}

// --- island chrome --------------------------------------------------------

/// The label that names an island (`Tunnel`, `Security`, …). Sans, sentence
/// case, no tracking: mono is reserved for values the user reads as data.
class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// A flat card with a hairline outline — the island.
class _Island extends StatelessWidget {
  final String label;
  final Widget body;

  const _Island({required this.label, required this.body});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(label),
          const SizedBox(height: 12),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// `label ………… value` — the readout row every island is built from.
class _ReadoutRow extends StatelessWidget {
  final String label;
  final String value;
  final bool dim;

  const _ReadoutRow(this.label, this.value, {this.dim = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          value,
          style: _mono(
            size: 12,
            color: dim ? dimTextOf(scheme) : scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

// --- update banner --------------------------------------------------------

/// Const so a Home rebuild (config reload, status change) never walks into
/// it; only UpdateService can.
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context) {
    return Consumer<UpdateService>(
      builder: (context, updates, _) {
        if (!updates.updateAvailable) return const SizedBox.shrink();
        return InfoBanner(
          // Keyed by version so a NEW release rebuilds the banner even if
          // the widget stays alive in the IndexedStack.
          key: ValueKey(updates.latestVersion),
          severity: BannerSeverity.info,
          message: AppLocalizations.of(
            context,
          )!.homeUpdateAvailable(updates.latestVersion!),
          margin: const EdgeInsets.only(bottom: 14),
          actions: [
            TextButton(
              onPressed: updates.openReleasePage,
              child: Text(AppLocalizations.of(context)!.homeUpdateDownload),
            ),
          ],
          onDismiss: updates.dismiss,
        );
      },
    );
  }
}

// --- live log -------------------------------------------------------------

/// A raw log line split into the parts the row draws. Everything here is
/// theme-independent, so one parse serves both brightnesses and every
/// rebuild.
class _ParsedLine {
  final String time;
  final String message;
  final LogLevel level;

  const _ParsedLine(this.time, this.message, this.level);
}

/// The tail of the same buffer the Logs tab renders, level-coloured.
///
/// Const-constructed and self-subscribing: a Home rebuild skips it, and a log
/// notification (~10fps while the client talks) rebuilds nothing above it.
class _LogIsland extends StatefulWidget {
  const _LogIsland();

  @override
  State<_LogIsland> createState() => _LogIslandState();
}

class _LogIslandState extends State<_LogIsland> {
  /// Parse results keyed by the raw line. Splitting the timestamp, dropping
  /// the level token and classifying the level used to happen for every
  /// visible row on every log notification; a line's text never changes, so
  /// it is parsed once and reused.
  final Map<String, _ParsedLine> _cache = {};

  _ParsedLine _parse(String line) {
    final hit = _cache[line];
    if (hit != null) return hit;

    // Stored lines look like "[HH:MM:SS] <LEVEL> message", the level token
    // present only on the lines that carry one.
    var time = '';
    var message = line;
    if (line.length > 11 && line.startsWith('[') && line[9] == ']') {
      time = line.substring(1, 9);
      message = line.substring(11);
    }
    // The level lives in its own column now, so drop the leading token the
    // service prefixes for the plain-text log.
    message = withoutLevelToken(message).trim();
    if (message.isEmpty) message = line;

    final parsed = _ParsedLine(
      time,
      message,
      logLevelOf(line),
    );
    // The buffer holds 500 lines and duplicate collapsing rewrites the last
    // one, so bound the cache rather than let it grow with the session.
    if (_cache.length >= 600) _cache.clear();
    _cache[line] = parsed;
    return parsed;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnService>(
      builder: (context, vpnService, _) {
        final logs = vpnService.logs;
        // Only the tail is on screen; rendering the whole 500-line buffer
        // on every ~10fps log notification would be pure waste.
        const window = 120;
        final tail = logs.length > window
            ? logs.sublist(logs.length - window)
            : logs;

        return _Island(
          label: 'Live log',
          body: tail.isEmpty
              ? const _LogEmptyState()
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  reverse: true,
                  itemCount: tail.length,
                  itemBuilder: (context, index) =>
                      _LogLine(line: _parse(tail[tail.length - 1 - index])),
                ),
        );
      },
    );
  }
}

class _LogEmptyState extends StatelessWidget {
  const _LogEmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.article_outlined, size: 44, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            AppLocalizations.of(context)!.logsEmpty,
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  final _ParsedLine line;

  const _LogLine({required this.line});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens =
        Theme.of(context).extension<StatusColors>() ?? StatusColors.light;

    final (
      String levelText,
      Color levelColor,
      Color messageColor,
    ) = switch (line.level) {
      LogLevel.error => ('ERROR', tokens.error, tokens.error),
      LogLevel.warning => ('WARN', tokens.connecting, tokens.connecting),
      LogLevel.debug => ('DEBUG', dimTextOf(scheme), dimTextOf(scheme)),
      LogLevel.info => (
        'INFO',
        dimTextOf(scheme),
        scheme.onSurfaceVariant,
      ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // "14:02:03" is eight glyphs; Chivo Mono's advance is 0.612em, so
            // at 11.5px the column needs 56.3px. It used to be 56, and the
            // third of a pixel it was short by wrapped the stamp onto a second
            // line. Sized with slack for the JetBrains fallback, and told never
            // to wrap: clipping a timestamp beats breaking the row.
            width: 64,
            child: Text(
              line.time,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: _mono(size: 11.5, color: dimTextOf(scheme)),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 44,
            child: Text(levelText, style: _mono(size: 11.5, color: levelColor)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              line.message,
              style: _mono(size: 11.5, color: messageColor),
            ),
          ),
        ],
      ),
    );
  }
}

// --- status dot -----------------------------------------------------------

/// The 10px state dot: a soft glow while connected, a slow pulse while a
/// connection is being made or torn down, flat otherwise. One
/// AnimationController, no packages.
class _StatusDot extends StatefulWidget {
  final VpnStatus status;

  const _StatusDot({required this.status});

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) _syncAnimation();
  }

  void _syncAnimation() {
    switch (widget.status) {
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        _controller.repeat(reverse: true);
      case VpnStatus.connected:
      case VpnStatus.disconnected:
      case VpnStatus.error:
        _controller.stop();
        _controller.value = 1;
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
    final glowing = widget.status == VpnStatus.connected;

    // The colour crossfade is the implicit animation (it only runs on a state
    // change); the pulse drives a plain DecoratedBox. Nesting an
    // AnimatedContainer inside the pulse's AnimatedBuilder — as this did —
    // re-targeted a 300ms implicit animation on every one of the pulse's
    // frames, which both damped the pulse and rebuilt an implicitly animated
    // widget 60 times a second.
    return TweenAnimationBuilder<Color?>(
      duration: const Duration(milliseconds: 300),
      tween: ColorTween(end: color),
      builder: (context, tinted, _) {
        final base = tinted ?? color;
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = 0.4 + 0.6 * _controller.value;
            return SizedBox(
              width: 10,
              height: 10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: base.withValues(alpha: t),
                  boxShadow: glowing
                      ? [
                          BoxShadow(
                            color: base.withValues(alpha: 0.7),
                            blurRadius: 10,
                          ),
                        ]
                      : null,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// --- uptime ---------------------------------------------------------------

/// Ticking "how long have I been connected" value. The one-second timer lives
/// here, on the leaf that shows the number, so it can never rebuild the strip.
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
      style: _mono(
        size: 16,
        color: Theme.of(context).colorScheme.onSurface,
        tabular: true,
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_selector/file_selector.dart';
import '../models/routing_list.dart';
import '../models/server_config.dart';
import '../models/domain_group.dart';
import '../models/vpn_status.dart';
import '../services/config_service.dart';
import '../services/vpn_service.dart';
import '../services/domain_discovery_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/exclusion_parser.dart';
import '../widgets/app_switch.dart';
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// `kMonoFontStack.sublist(1)` allocated a fresh list on every mono TextStyle
/// built — several times per list row — so the tail is computed once here.
final List<String> _monoFallback = kMonoFontStack.sublist(1);

class SplitTunnelScreen extends StatefulWidget {
  const SplitTunnelScreen({super.key});

  @override
  State<SplitTunnelScreen> createState() => _SplitTunnelScreenState();
}

class _SplitTunnelScreenState extends State<SplitTunnelScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  VpnMode _vpnMode = VpnMode.general;
  List<DomainGroup> _groups = [];
  List<String> _standaloneDomains = [];
  List<String> _apps = [];
  bool _isLoading = true;

  // Ready-made routing lists (built-in preset + user URL/file lists)
  List<RoutingList> _routingLists = [];
  final Set<String> _busyLists = {};

  final TextEditingController _domainController = TextEditingController();
  final TextEditingController _appSearchController = TextEditingController();
  List<InstalledApp> _installedApps = [];
  bool _isLoadingApps = false;
  // Whether app discovery has already run (Fix #2: lazy + cached).
  bool _appsLoaded = false;
  String _appSearchQuery = '';

  // Memoized Apps-tab rows. TabBarView builds BOTH tabs on every screen
  // rebuild (domain edits, log-suggestion flushes, ConfigService notifies),
  // so the filter + double sort used to rerun constantly — with a linear
  // _apps.contains inside the sort comparator. _appsRevision is bumped on
  // every _apps/_installedApps mutation to invalidate the memo.
  int _appsRevision = 0;
  String? _appsViewKey;
  List<String> _manualAppsView = const [];
  List<InstalledApp> _filteredAppsView = const [];
  Set<String> _selectedAppsView = const {};

  // Search keys built once per scan, parallel to [_installedApps] (which is
  // kept alphabetical by displayName so the per-query pass never sorts).
  // Recomputing them per keystroke meant four string allocations per
  // installed app on every character typed, plus an N·logN sort whose
  // comparator called toLowerCase() twice per comparison.
  List<_AppSearchKey> _appKeys = const [];
  Set<String> _installedNamesLower = const {};

  // Extracted app icons live on disk; keep one ImageProvider per path so the
  // image cache key is stable across rebuilds and the PNG is decoded once,
  // downscaled to the 26px the row actually draws.
  final Map<String, ImageProvider> _iconProviders = {};

  final DomainDiscoveryService _discoveryService = DomainDiscoveryService();

  // Suggestions from log monitoring
  final List<String> _suggestions = [];

  // Fix #3: cached lower-cased set of current domains, rebuilt only when the
  // domain data actually changes (not per log line), plus a debounce buffer.
  Set<String> _currentDomainsCache = <String>{};
  final List<String> _pendingLogLines = [];
  Timer? _logDebounceTimer;

  @override
  void initState() {
    super.initState();
    // The tab body is a surface reflowing, so it moves on the surface
    // duration rather than on `kTabScrollDuration`, the framework default
    // nothing in the app had ever chosen.
    _tabController = TabController(
      length: 2,
      vsync: this,
      animationDuration: kSurfaceChangeDuration,
    );
    // Fix #2: lazily load installed apps the first time the Apps tab is opened.
    _tabController.addListener(_onTabChanged);
    _loadConfig();
  }

  void _onTabChanged() {
    // index 1 == Apps tab. Trigger discovery on first switch only.
    if (_tabController.index == 1 && !_appsLoaded && !_isLoadingApps) {
      _loadInstalledApps();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _domainController.dispose();
    _appSearchController.dispose();
    _logDebounceTimer?.cancel();
    _stopLogMonitoring();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final configService = context.read<ConfigService>();
    final config = await configService.loadConfig();

    // Migrate and load domain groups
    final groupsData = await configService.migrateFlatDomainsToGroups();

    // The routing lists are fetched alongside, not in front of, the rest: on
    // first launch their loader migrates the legacy cache file, and holding
    // the whole screen behind that filesystem walk left the boot spinner
    // (and a screen reader) with nothing to read for as long as it took.
    final routingListsFuture = configService.loadRoutingLists();
    if (!mounted) return;

    setState(() {
      _vpnMode = config.vpnMode;
      _groups = List.from(groupsData.groups);
      _standaloneDomains = List.from(groupsData.standaloneDomains);
      _apps = List.from(config.splitTunnelApps);
      _appsRevision++;
      _isLoading = false;
    });

    _rebuildDomainsCache();
    _startLogMonitoring();

    final routingLists = await routingListsFuture;
    if (!mounted) return;
    setState(() {
      _routingLists = routingLists;
    });
  }

  void _startLogMonitoring() {
    final vpnService = context.read<VpnService>();
    vpnService.addLogObserver(_onLogLine);
  }

  void _stopLogMonitoring() {
    try {
      final vpnService = context.read<VpnService>();
      vpnService.removeLogObserver(_onLogLine);
    } catch (_) {}
  }

  /// Fix #3: buffer log lines and process them on a debounce timer instead of
  /// running a regex + Set rebuild synchronously on every single line.
  void _onLogLine(String line) {
    _pendingLogLines.add(line);
    _logDebounceTimer ??= Timer(
      const Duration(milliseconds: 500),
      _flushLogLines,
    );
  }

  void _flushLogLines() {
    _logDebounceTimer = null;
    if (_pendingLogLines.isEmpty) return;

    final lines = List<String>.from(_pendingLogLines);
    _pendingLogLines.clear();

    // Use the cached current-domains Set (rebuilt only on data mutation).
    final newSuggestions = extractDomainSuggestions(
      lines,
      existingDomains: _currentDomainsCache,
      existingSuggestions: _suggestions,
      remainingSlots: 20 - _suggestions.length,
    );

    if (newSuggestions.isNotEmpty && mounted) {
      setState(() {
        _suggestions.addAll(newSuggestions);
      });
    }
  }

  /// Rebuild the cached lower-cased set of all current domains. Call this only
  /// when the underlying domain data changes (add/remove/import/save), not per
  /// log line.
  void _rebuildDomainsCache() {
    _currentDomainsCache = _getAllCurrentDomains();
  }

  Set<String> _getAllCurrentDomains() {
    final all = <String>{};
    for (final group in _groups) {
      all.addAll(group.domains.map((d) => d.toLowerCase()));
    }
    all.addAll(_standaloneDomains.map((d) => d.toLowerCase()));
    return all;
  }

  int get _totalDomainCount {
    int count = _standaloneDomains.length;
    for (final group in _groups) {
      count += group.domains.length;
    }
    return count;
  }

  /// Sort the scan alphabetically and precompute its search keys — once per
  /// scan, so filtering a query is a pair of allocation-free O(n) passes.
  void _indexInstalledApps() {
    final indexed = [
      for (final app in _installedApps) (app, _AppSearchKey(app)),
    ]..sort((a, b) => a.$2.displayLower.compareTo(b.$2.displayLower));
    _installedApps = [for (final e in indexed) e.$1];
    _appKeys = [for (final e in indexed) e.$2];
    _installedNamesLower = {for (final k in _appKeys) k.nameLower};
  }

  Future<void> _loadInstalledApps() async {
    setState(() {
      _isLoadingApps = true;
    });

    try {
      // Fix #2: run the heavy filesystem walk off the UI isolate.
      final apps = await Isolate.run(_discoverInstalledApps);
      if (!mounted) return;
      setState(() {
        _installedApps = apps;
        _indexInstalledApps();
        _appsRevision++;
        _isLoadingApps = false;
        _appsLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingApps = false;
        // Mark as loaded so we don't keep retrying a failing scan on every
        // tab switch; the user can still search the (empty) list.
        _appsLoaded = true;
      });
    }
  }

  Future<void> _saveConfig() async {
    // Fix #3: keep the cached current-domains Set in sync whenever the domain
    // data changes (every add/remove/import/save funnels through here).
    _rebuildDomainsCache();
    try {
      final configService = context.read<ConfigService>();

      // Save domain groups
      final groupsData = DomainGroupsData(
        groups: _groups,
        standaloneDomains: _standaloneDomains,
      );
      await configService.saveDomainGroups(groupsData);

      // Flatten domains for TOML config
      final flatDomains = groupsData.flattenDomains();

      final currentConfig = await configService.loadConfig();
      final updatedConfig = currentConfig.copyWith(
        vpnMode: _vpnMode,
        splitTunnelDomains: flatDomains,
        splitTunnelApps: _apps,
      );

      await configService.saveConfig(updatedConfig);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context)!.splitTunnelSaveError(e.toString()),
          kind: SnackKind.error,
        );
      }
    }
  }

  /// Add whatever is in the input — a site (bare domain or a pasted URL),
  /// an IP or a CIDR range. The entry is normalized, validated and lands in
  /// the list immediately; for plain domains a snackbar offers the
  /// related-domains discovery as an optional follow-up instead of forcing
  /// a blocking dialog on every add.
  void _addEntry() {
    final raw = _domainController.text;
    if (raw.trim().isEmpty) return;

    final entry = normalizeExclusion(raw);
    if (entry == null) {
      showAppSnackBar(
        context,
        'Not a valid domain, IP or CIDR: "${raw.trim()}"',
        kind: SnackKind.error,
      );
      return;
    }

    if (_currentDomainsCache.contains(entry)) {
      showAppSnackBar(
        context,
        AppLocalizations.of(context)!.splitTunnelDomainAlreadyAdded,
      );
      return;
    }

    setState(() {
      _standaloneDomains.add(entry);
    });
    _domainController.clear();
    _saveConfig();

    // Discovery only makes sense for real domains (not IPs/CIDRs/wildcards).
    if (classifyExclusion(entry) == ExclusionKind.domain &&
        !entry.startsWith('*.')) {
      showAppSnackBar(
        context,
        'Added $entry',
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'Find related',
          onPressed: () => _runDiscoveryFor(entry),
        ),
      );
    }
  }

  /// Optional related-domain discovery. When the user picks related domains,
  /// the standalone entry is upgraded to a group.
  Future<void> _runDiscoveryFor(String domain) async {
    final result = await showDialog<_DiscoveryDialogResult>(
      context: context,
      builder: (context) =>
          _DiscoveryDialog(domain: domain, discoveryService: _discoveryService),
    );
    if (result == null) return;

    // The cache is kept current by every mutation; the `d != domain` filter
    // below already excludes the primary domain itself.
    final existing = _currentDomainsCache;
    final related = result.selectedDomains
        .map((d) => d.toLowerCase())
        .where((d) => d != domain && !existing.contains(d))
        .toList();
    if (related.isEmpty) return;

    setState(() {
      if (result.createGroup) {
        _standaloneDomains.remove(domain);
        _groups.add(
          DomainGroup(
            id: '${domain.replaceAll('.', '-')}-${DateTime.now().millisecondsSinceEpoch}',
            name: result.groupName,
            primaryDomain: domain,
            domains: [domain, ...related],
          ),
        );
      } else {
        // "Without group": the checked related domains still get added,
        // just as standalone entries.
        _standaloneDomains.addAll(related);
      }
    });
    _saveConfig();
  }

  /// Bulk-import a pasted list of domains/IPs/CIDRs straight into the
  /// standalone list, skipping the per-domain discovery dialog.
  Future<void> _importDomainList() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: 'Paste list',
        caption:
            'One domain, IP or CIDR per line (commas and spaces also work):',
        hint: '92.255.112.0/20\nalfa.bank\nvk.com\nya.ru',
        confirmLabel: AppLocalizations.of(context)!.commonAdd,
        width: 420,
        minLines: 6,
        maxLines: 14,
        // The pasted text is split line by line, so it is taken verbatim.
        trimResult: false,
      ),
    );

    if (raw == null) return;

    final (toAdd, invalid) = importExclusionList(raw, _currentDomainsCache);

    if (toAdd.isEmpty) {
      if (mounted) {
        showAppSnackBar(
          context,
          invalid > 0
              ? 'Nothing new to add ($invalid invalid entries skipped)'
              : 'Nothing new to add',
          kind: invalid > 0 ? SnackKind.warning : SnackKind.info,
        );
      }
      return;
    }

    setState(() {
      _standaloneDomains.addAll(toAdd);
    });
    _saveConfig();

    if (mounted) {
      showAppSnackBar(
        context,
        invalid > 0
            ? 'Added ${toAdd.length} entries ($invalid invalid skipped)'
            : 'Added ${toAdd.length} entries',
        kind: invalid > 0 ? SnackKind.warning : SnackKind.success,
      );
    }
  }

  void _addDomainToGroup(DomainGroup group) async {
    final result = await showDialog<String>(
      context: context,
      // One vocabulary: the confirming action of a dialog is a FilledButton,
      // as in the paste-list and add-routing-list dialogs.
      builder: (context) => _TextPromptDialog(
        title: AppLocalizations.of(context)!.splitTunnelAddToGroup(group.name),
        hint: AppLocalizations.of(context)!.splitTunnelEnterDomain,
        confirmLabel: AppLocalizations.of(context)!.commonAdd,
        prefixIcon: const Icon(Icons.add_link, size: 20),
      ),
    );

    if (result == null || result.isEmpty || !mounted) return;

    final entry = normalizeExclusion(result);
    if (entry == null) {
      showAppSnackBar(
        context,
        'Not a valid domain, IP or CIDR: "$result"',
        kind: SnackKind.error,
      );
      return;
    }
    // Dedupe across ALL containers, not just this group.
    if (_currentDomainsCache.contains(entry)) {
      showAppSnackBar(
        context,
        AppLocalizations.of(context)!.splitTunnelDomainAlreadyAdded,
      );
      return;
    }

    final idx = _groups.indexWhere((g) => g.id == group.id);
    if (idx == -1) return;
    setState(() {
      final updated = List<String>.from(_groups[idx].domains)..add(entry);
      _groups[idx] = _groups[idx].copyWith(domains: updated);
    });
    _saveConfig();
  }

  void _removeDomainFromGroup(DomainGroup group, String domain) {
    final idx = _groups.indexWhere((g) => g.id == group.id);
    if (idx == -1) return;

    setState(() {
      final updated = List<String>.from(_groups[idx].domains)..remove(domain);
      if (updated.isEmpty) {
        _groups.removeAt(idx);
      } else {
        _groups[idx] = _groups[idx].copyWith(domains: updated);
      }
    });
    _saveConfig();
  }

  void _deleteGroup(DomainGroup group) {
    setState(() {
      _groups.removeWhere((g) => g.id == group.id);
    });
    _saveConfig();
  }

  void _renameGroup(DomainGroup group) async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _TextPromptDialog(
        title: AppLocalizations.of(context)!.splitTunnelRenameGroup,
        hint: AppLocalizations.of(context)!.splitTunnelGroupName,
        confirmLabel: AppLocalizations.of(context)!.commonSave,
        initialText: group.name,
      ),
    );

    if (result != null && result.isNotEmpty) {
      final idx = _groups.indexWhere((g) => g.id == group.id);
      if (idx != -1) {
        setState(() {
          _groups[idx] = _groups[idx].copyWith(name: result);
        });
        _saveConfig();
      }
    }
  }

  void _removeStandaloneDomain(String domain) {
    setState(() {
      _standaloneDomains.remove(domain);
    });
    _saveConfig();
  }

  void _addSuggestionToStandalone(String domain) {
    setState(() {
      _suggestions.remove(domain);
      _standaloneDomains.add(domain);
    });
    _saveConfig();
  }

  void _addSuggestionToGroup(String domain, DomainGroup group) {
    final idx = _groups.indexWhere((g) => g.id == group.id);
    if (idx == -1) return;

    setState(() {
      _suggestions.remove(domain);
      final updated = List<String>.from(_groups[idx].domains)..add(domain);
      _groups[idx] = _groups[idx].copyWith(domains: updated);
    });
    _saveConfig();
  }

  void _dismissSuggestion(String domain) {
    setState(() {
      _suggestions.remove(domain);
    });
  }

  /// Real app icon when discovery extracted one, generic icon otherwise.
  ///
  /// The provider is memoized per path: `Image.file` built a fresh FileImage
  /// on every row build, and the ResizeImage wrapper caps the decode at the
  /// 26px the row draws instead of whatever the extractor wrote out.
  Widget _appIcon(InstalledApp app) {
    if (app.iconPath.isNotEmpty) {
      final provider = _iconProviders.putIfAbsent(
        app.iconPath,
        () => ResizeImage(
          FileImage(File(app.iconPath)),
          width: 64,
          height: 64,
          policy: ResizeImagePolicy.fit,
        ),
      );
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image(
          image: provider,
          width: 26,
          height: 26,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, e, s) =>
              Icon(Icons.apps, size: 20, color: _scheme.onSurfaceVariant),
        ),
      );
    }
    return Icon(
      app.running ? Icons.play_circle_outline : Icons.apps,
      size: 20,
      color: _scheme.onSurfaceVariant,
    );
  }

  /// The process name the current search query would add.
  /// On Windows a bare name gets ".exe" appended — that's what the
  /// client's process filter matches; macOS process names are used as-is.
  String _manualAppName() {
    var name = _appSearchQuery.trim();
    if (Platform.isWindows && name.isNotEmpty && !name.contains('.')) {
      name = '$name.exe';
    }
    return name;
  }

  /// Add an app by process name — for apps the scanner didn't find
  /// (portable builds, games, custom install dirs).
  void _addManualApp() {
    final name = _manualAppName();
    if (name.isEmpty) return;
    if (_apps.any((a) => a.toLowerCase() == name.toLowerCase())) {
      showAppSnackBar(context, '"$name" is already in the list');
      return;
    }
    setState(() {
      _apps.add(name);
      _appsRevision++;
      _appSearchQuery = '';
    });
    _appSearchController.clear();
    _saveConfig();
  }

  void _toggleApp(String appName) {
    setState(() {
      if (_apps.contains(appName)) {
        _apps.remove(appName);
      } else {
        _apps.add(appName);
      }
      _appsRevision++;
    });
    _saveConfig();
  }

  void _setVpnMode(VpnMode mode) {
    setState(() {
      _vpnMode = mode;
    });
    _saveConfig();
  }

  // ── «Пульт» composition helpers ───────────────────────────────────────
  //
  // Every colour comes from the ColorScheme or StatusColors; anything the
  // user reads as data (domains, IPs, process names, entry counts) is mono.

  /// KIT §3: input 34, button 34. Also the height of a single-entry row.
  static const double _kControlHeight = 34;

  /// Row height + the 4px gap between rows — the fixed extent the domain list
  /// scrolls by when every item is a plain entry row.
  static const double _kDomainRowExtent = _kControlHeight + 4;

  /// App row: 50px of content + the 6px gap the artboard puts between rows.
  static const double _kAppRowHeight = 50;
  static const double _kAppRowExtent = _kAppRowHeight + 6;

  // Theme reads are resolved once per dependency change instead of on every
  // call: the getters below used to run Theme.of(context) (and rebuild a
  // BoxDecoration with a fresh Border) for each of the hundreds of rows a
  // long domain or app list builds.
  late ColorScheme _scheme;
  late TextTheme _textTheme;
  late StatusColors _statusColors;

  /// The kit's `dim`: section labels, placeholders, secondary mono values.
  /// The quietest of the three text tones, and still above the AA floor on
  /// every surface — see `dimTextOf` in the theme.
  late Color _dim;

  /// Inset well at card radius: group cards and routing-list tiles.
  late BoxDecoration _insetDecoration;

  /// Inset well at row radius (artboard: 10) for single-entry rows.
  late BoxDecoration _insetRowDecoration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = Theme.of(context);
    _scheme = theme.colorScheme;
    _textTheme = theme.textTheme;
    _statusColors = theme.extension<StatusColors>()!;
    _dim = dimTextOf(_scheme);
    _insetDecoration = BoxDecoration(
      color: _scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _scheme.outlineVariant),
    );
    _insetRowDecoration = BoxDecoration(
      color: _scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _scheme.outlineVariant),
    );
  }

  TextStyle _mono({
    double size = 12.5,
    Color? color,
    FontWeight? weight,
    double? height,
  }) {
    return TextStyle(
      fontFamily: kMonoFontStack.first,
      fontFamilyFallback: _monoFallback,
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: height,
    );
  }

  /// KIT §2 "section label": sans, sentence case, no tracking. A tracked
  /// uppercase mono word is the house style of a generated dashboard and is
  /// harder to read than the words it replaced; mono is kept for values.
  TextStyle get _sectionLabelStyle => TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    color: _scheme.onSurfaceVariant,
  );

  /// The section label every island carries, with its explanation tucked
  /// behind an info glyph instead of standing on the screen.
  Widget _sectionLabel(String label, {String? hint}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: _sectionLabelStyle),
        if (hint != null) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: hint,
            child: Icon(Icons.info_outline, size: 15, color: _dim),
          ),
        ],
      ],
    );
  }

  /// `Section │ what this island is` — the tab island's one-line header.
  Widget _islandHeader({
    required String label,
    required String subtitle,
    String? hint,
  }) {
    return Row(
      children: [
        _sectionLabel(label),
        const SizedBox(width: 10),
        Container(width: 1, height: 12, color: _scheme.outline),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            subtitle,
            overflow: TextOverflow.ellipsis,
            style: _textTheme.bodySmall?.copyWith(
              color: _scheme.onSurfaceVariant,
            ),
          ),
        ),
        if (hint != null) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: hint,
            child: Icon(Icons.info_outline, size: 15, color: _dim),
          ),
        ],
      ],
    );
  }

  /// The 34×34 add / paste / rescan control that sits beside an input.
  static Widget _squareIconButton({required Widget child}) =>
      SizedBox(width: _kControlHeight, height: _kControlHeight, child: child);

  Widget _emptyState(IconData icon, String message, {Widget? action}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 44, color: _scheme.outline),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: _textTheme.bodyMedium?.copyWith(
                color: _scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(height: 12), action],
        ],
      ),
    );
  }

  // ── Screen ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final l10n = AppLocalizations.of(context)!;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Everything stays editable while connected — changes are saved
          // immediately and picked up on the next connect. The banner just
          // says so instead of locking the whole screen.
          //
          // Only this banner reads the VPN status, so the selector stops
          // here: VpnService notifies on every batch of log lines, and the
          // screen-wide Selector this replaces re-ran the whole tree builder
          // (both tab bodies included) on every connect/disconnect.
          Selector<VpnService, bool>(
            selector: (_, vpn) => vpn.status.isActive,
            builder: (context, isConnected, child) => isConnected
                ? InfoBanner(
                    severity: BannerSeverity.info,
                    message: l10n.splitTunnelWarningConnected,
                    margin: const EdgeInsets.only(bottom: 14),
                  )
                : const SizedBox.shrink(),
          ),
          // In SOCKS5 mode the client core still applies these rules, but only
          // to traffic that actually reaches the local proxy — say so honestly.
          //
          // ConfigService notifies on every settings write, and _saveConfig()
          // writes on every domain add/remove, group edit, app toggle and mode
          // switch. The context.watch this replaces therefore rebuilt the
          // entire screen a second time after every single edit; the selector
          // yields the same bool, so nothing rebuilds.
          Selector<ConfigService, bool>(
            selector: (_, config) => config.connectionModeCache == 'socks5',
            builder: (context, socksMode, child) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (socksMode)
                  InfoBanner(
                    severity: BannerSeverity.info,
                    message: l10n.splitTunnelSocksModeBanner,
                    margin: const EdgeInsets.only(bottom: 14),
                  ),
                _buildModeIsland(socksMode),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _buildTabbedIsland()),
                const SizedBox(width: 14),
                SizedBox(width: 240, child: _buildRoutingListsIsland()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The top island: the mode switcher and the one honest sentence that says
  /// what the mode does. Which list is which, and when the change lands, sit
  /// behind the label's hint.
  Widget _buildModeIsland(bool socksMode) {
    final l10n = AppLocalizations.of(context)!;
    final subtitle = _vpnMode == VpnMode.general
        ? (socksMode
              ? l10n.splitTunnelModeGeneralSubtitleProxy
              : l10n.splitTunnelModeGeneralSubtitle)
        : (socksMode
              ? l10n.splitTunnelModeSelectiveSubtitleProxy
              : l10n.splitTunnelModeSelectiveSubtitle);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionLabel(
              l10n.splitTunnelVpnMode,
              hint:
                  '${l10n.splitTunnelModeSameList}\n'
                  '${l10n.splitTunnelAutoSave}',
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<VpnMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: VpnMode.general,
                    icon: const Icon(Icons.shield_outlined, size: 18),
                    label: Text(l10n.splitTunnelModeGeneralTitle),
                  ),
                  ButtonSegment(
                    value: VpnMode.selective,
                    icon: const Icon(Icons.tune, size: 18),
                    label: Text(l10n.splitTunnelModeSelectiveTitle),
                  ),
                ],
                selected: {_vpnMode},
                onSelectionChanged: (modes) => _setVpnMode(modes.first),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: _textTheme.bodySmall?.copyWith(
                color: _scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The main column: the tab bar with its live counts, then one island
  /// holding whichever tab is open.
  Widget _buildTabbedIsland() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorSize: TabBarIndicatorSize.tab,
            indicatorColor: _scheme.primary,
            dividerColor: _scheme.outlineVariant,
            // M3's tab overlay is its own scale (hover 8%, press 10%, focus
            // 10%) — brighter than the app's on hover and, since press and
            // hover are nearly equal, it never reads as "pressed". The shared
            // 5 / 8 / 12 ramp puts a tab on the same footing as a button.
            overlayColor: pointerOverlay(_scheme.onSurface),
            labelColor: _scheme.onSurface,
            unselectedLabelColor: _scheme.onSurfaceVariant,
            labelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: const TextStyle(fontSize: 13),
            tabs: [
              _tabLabel(
                Icons.language,
                l10n.splitTunnelDomainsTab(_totalDomainCount),
              ),
              _tabLabel(Icons.apps, l10n.splitTunnelAppsTab(_apps.length)),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: TabBarView(
                controller: _tabController,
                children: [_buildDomainsTab(), _buildAppsTab()],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tabLabel(IconData icon, String text) {
    return Tab(
      height: 38,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 18), const SizedBox(width: 8), Text(text)],
      ),
    );
  }

  // ── Ready-made routing lists ──────────────────────────────────────────

  Future<void> _reloadRoutingLists() async {
    final lists = await context.read<ConfigService>().loadRoutingLists();
    if (mounted) setState(() => _routingLists = lists);
  }

  /// The 240px side column. One tile per list (built-in preset + user lists)
  /// with its enable switch, refresh, per-mode applicability and delete.
  /// Entries are merged into the exclusions at connect time; they never
  /// clutter the domain list.
  Widget _buildRoutingListsIsland() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _sectionLabel('Routing lists', hint: _routingListsHint),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: _routingLists.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _buildRoutingListTile(_routingLists[index]),
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Themed geometry (34px, radius 8, outline side) — no styleFrom.
            OutlinedButton.icon(
              onPressed: _addRoutingList,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add list'),
            ),
          ],
        ),
      ),
    );
  }

  /// No ARB key for this one yet — see the report.
  static const String _routingListsHint =
      'A ready-made set of domains and IP ranges, merged with your rules on '
      'connect. Routing lists stay separate from your own entries.';

  Widget _buildRoutingListTile(RoutingList list) {
    final scheme = _scheme;
    final statusColors = _statusColors;
    final busy = _busyLists.contains(list.id);
    final activeInMode = list.enabled && list.matchesMode(_vpnMode);
    final hasError = list.lastError.isNotEmpty;
    // A partial refresh DID update the cache, so it must not read as a flat
    // failure — amber, not red (COPY §5).
    final partial = hasError && list.lastError.startsWith('Partially updated');

    final parts = <String>[];
    if (list.entryCount > 0) {
      parts.add('${list.entryCount} entries');
      if (list.lastUpdated != null) {
        parts.add(
          MaterialLocalizations.of(context).formatShortDate(list.lastUpdated!),
        );
      }
    } else {
      parts.add(
        list.isBuiltin ? 'downloads on first enable' : 'not downloaded yet',
      );
    }
    if (hasError) parts.add(partial ? 'partly updated' : 'update failed');
    if (list.enabled && !list.matchesMode(_vpnMode)) {
      parts.add('inactive in ${_vpnMode.name} mode');
    }

    final statusColor = hasError
        ? (partial ? statusColors.connecting : statusColors.error)
        : _dim;

    return Container(
      decoration: _insetDecoration,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: busy
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : Icon(
                        hasError
                            ? Icons.sync_problem
                            : list.type == 'file'
                            ? Icons.description_outlined
                            : Icons.alt_route,
                        size: 18,
                        color: hasError
                            ? statusColor
                            : activeInMode
                            ? scheme.primary
                            : _dim,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  list.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // KIT §Toggle at its own size: no SizedBox + FittedBox needed
              // to shrink a 52×32 Material switch into the row any more.
              // The tile's own text does not name the control, so the switch
              // carries the name itself.
              AppSwitch(
                value: list.enabled,
                semanticLabel: 'Use ${list.name}',
                onChanged: busy ? null : (v) => _toggleRoutingList(list, v),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            parts.join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _mono(size: 11, color: statusColor),
          ),
          const SizedBox(height: 4),
          // Geometry from dividerTheme (outlineVariant, 1px, space 1).
          const Divider(),
          SizedBox(
            height: 28,
            child: Row(
              children: [
                // Icon-only actions, right-aligned, dim — SplitAddList.dc.html.
                // 28×28 and radius 8 come from iconButtonTheme.
                if (list.enabled)
                  IconButton(
                    tooltip: 'Update now',
                    icon: const Icon(Icons.refresh, size: 16),
                    color: _dim,
                    onPressed: busy ? null : () => _refreshRoutingList(list),
                  ),
                const Spacer(),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: PopupMenuButton<String>(
                    tooltip: 'List options',
                    icon: Icon(Icons.tune, size: 16, color: _dim),
                    iconSize: 16,
                    padding: EdgeInsets.zero,
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        enabled: false,
                        child: Text(
                          'Apply this list in:',
                          style: _sectionLabelStyle,
                        ),
                      ),
                      CheckedPopupMenuItem(
                        value: 'selective',
                        checked: list.appliesTo == 'selective',
                        child: const Text('Selective mode'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'general',
                        checked: list.appliesTo == 'general',
                        child: const Text('General mode'),
                      ),
                      CheckedPopupMenuItem(
                        value: 'both',
                        checked: list.appliesTo == 'both',
                        child: const Text('Both modes'),
                      ),
                      // Every list can be removed, including one carried over
                      // from the pre-0.4.0 preset: an entry the user cannot
                      // delete is a trap, and the catalogue can add it back.
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete list'),
                      ),
                    ],
                    onSelected: (v) async {
                      if (_busyLists.contains(list.id)) {
                        showAppSnackBar(
                          context,
                          'Wait for the running update to finish',
                        );
                        return;
                      }
                      final configService = context.read<ConfigService>();
                      if (v == 'delete') {
                        await configService.deleteRoutingList(list.id);
                      } else {
                        await configService.setRoutingListAppliesTo(list.id, v);
                      }
                      await _reloadRoutingLists();
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleRoutingList(RoutingList list, bool enable) async {
    final configService = context.read<ConfigService>();

    // First enable of a never-downloaded list → fetch before flipping.
    if (enable && list.entryCount == 0) {
      setState(() => _busyLists.add(list.id));
      try {
        await configService.refreshRoutingList(list.id);
      } catch (e) {
        if (mounted) {
          setState(() => _busyLists.remove(list.id));
          showAppSnackBar(
            context,
            'Failed to download "${list.name}": $e',
            kind: SnackKind.error,
          );
        }
        return;
      }
      if (mounted) setState(() => _busyLists.remove(list.id));
    }

    await configService.setRoutingListEnabled(list.id, enable);
    await _reloadRoutingLists();
  }

  Future<void> _refreshRoutingList(RoutingList list) async {
    final configService = context.read<ConfigService>();
    setState(() => _busyLists.add(list.id));
    try {
      await configService.refreshRoutingList(list.id);
      if (mounted) {
        showAppSnackBar(
          context,
          '"${list.name}" updated',
          kind: SnackKind.success,
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Failed to update "${list.name}": $e',
          kind: SnackKind.error,
        );
      }
    }
    if (mounted) setState(() => _busyLists.remove(list.id));
    await _reloadRoutingLists();
  }

  Future<void> _addRoutingList() async {
    final added = await showDialog<RoutingList>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          _AddRoutingListDialog(configService: context.read<ConfigService>()),
    );
    if (!mounted) return;
    if (added != null) {
      showAppSnackBar(
        context,
        '"${added.name}" added (${added.entryCount} entries)',
        kind: SnackKind.success,
      );
    }
    // Reload unconditionally: an interrupted _add() may have persisted the
    // list even though the dialog returned null.
    await _reloadRoutingLists();
  }

  Widget _buildDomainsTab() {
    final l10n = AppLocalizations.of(context)!;
    final isEmpty =
        _groups.isEmpty && _standaloneDomains.isEmpty && _suggestions.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _islandHeader(
          label: 'Domains',
          subtitle: _vpnMode == VpnMode.general
              ? l10n.splitTunnelDomainsExclude
              : l10n.splitTunnelDomainsInclude,
          // The format explanation lives here instead of standing under the
          // field as helper prose.
          hint: l10n.splitTunnelDomainsHint,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: _kControlHeight,
                child: TextField(
                  controller: _domainController,
                  style: _mono(color: _scheme.onSurface),
                  textAlignVertical: TextAlignVertical.center,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.splitTunnelDomainsInputHint,
                    hintStyle: _mono(color: _dim),
                    prefixIcon: Icon(Icons.add_link, size: 18, color: _dim),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 38,
                      minHeight: _kControlHeight,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onSubmitted: (_) => _addEntry(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _squareIconButton(
              child: IconButton.filled(
                // iconButtonTheme pins the 8px radius for every variant but
                // also its onSurfaceVariant foreground, which would leave the
                // glyph unreadable on the primary fill.
                style: IconButton.styleFrom(foregroundColor: _scheme.onPrimary),
                tooltip: l10n.commonAdd,
                onPressed: _addEntry,
                icon: const Icon(Icons.add, size: 18),
              ),
            ),
            const SizedBox(width: 8),
            _squareIconButton(
              child: IconButton.outlined(
                style: IconButton.styleFrom(foregroundColor: _scheme.onSurface),
                onPressed: _importDomainList,
                tooltip: 'Paste a list',
                icon: const Icon(Icons.content_paste, size: 18),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: isEmpty
              ? _emptyState(Icons.dns_outlined, l10n.splitTunnelNoDomains)
              : _buildDomainsList(),
        ),
      ],
    );
  }

  /// Sections in order: group cards, an "Other" header (only when both
  /// groups and standalone entries exist), standalone domain rows, the
  /// suggestion banner. ListView.builder keeps the list lazy — a user list
  /// of hundreds/thousands of domains must not be rebuilt as widgets in full
  /// on every setState.
  Widget _buildDomainsList() {
    final hasHeader = _standaloneDomains.isNotEmpty && _groups.isNotEmpty;
    final standaloneStart = _groups.length + (hasHeader ? 1 : 0);
    final bannerIndex = standaloneStart + _standaloneDomains.length;
    // With no groups and no suggestions every item is a plain 34px entry row,
    // so the list can be given a fixed extent: scrolling a few thousand
    // domains then costs no per-child layout pass and the scrollbar knows the
    // full extent up front instead of estimating it.
    final uniformRows = _groups.isEmpty && _suggestions.isEmpty;
    final deleteLabel = AppLocalizations.of(context)!.commonDelete;
    final otherLabel = AppLocalizations.of(context)!.splitTunnelOther;
    final domainStyle = _mono(color: _scheme.onSurface);
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemExtent: uniformRows ? _kDomainRowExtent : null,
      itemCount: bannerIndex + (_suggestions.isNotEmpty ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _groups.length) return _buildGroupCard(_groups[index]);
        if (hasHeader && index == _groups.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text(
              otherLabel,
              style: _textTheme.bodySmall?.copyWith(
                color: _scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        if (index < bannerIndex) {
          final domain = _standaloneDomains[index - standaloneStart];
          return Container(
            margin: const EdgeInsets.only(bottom: 4),
            height: _kControlHeight,
            padding: const EdgeInsets.only(left: 12, right: 6),
            decoration: _insetRowDecoration,
            child: Row(
              children: [
                Icon(_getDomainIcon(domain), size: 18, color: _dim),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    domain,
                    overflow: TextOverflow.ellipsis,
                    style: domainStyle,
                  ),
                ),
                // 28×28 and the 8px radius are iconButtonTheme's; only the
                // dim glyph tone is local (artboard: the row's trailing X).
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  color: _dim,
                  tooltip: deleteLabel,
                  onPressed: () => _removeStandaloneDomain(domain),
                ),
              ],
            ),
          );
        }
        return _buildSuggestionBanner();
      },
    );
  }

  Widget _buildGroupCard(DomainGroup group) {
    final scheme = _scheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      decoration: _insetDecoration,
      child: ExpansionTile(
        // A card opening is a surface change, so it runs on the surface
        // duration and the app's curve. Left alone it used the framework's
        // 200ms / `Curves.easeIn` — an ease that starts slowly, which on a
        // click reads as lag before anything moves.
        expansionAnimationStyle: AnimationStyle(
          duration: kSurfaceChangeDuration,
          curve: kMotionCurve,
        ),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.only(left: 12, right: 8, bottom: 6),
        leading: Icon(Icons.folder_outlined, size: 18, color: scheme.primary),
        title: Text(
          group.name,
          style: _textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          _pluralDomains(group.domains.length),
          style: _mono(size: 11, color: _dim),
        ),
        children: [
          // Domains in group
          ...group.domains.map(
            (domain) => Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 2),
              child: Row(
                children: [
                  Icon(_getDomainIcon(domain), size: 15, color: _dim),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      domain,
                      overflow: TextOverflow.ellipsis,
                      style: _mono(color: scheme.onSurface),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    color: _dim,
                    tooltip: 'Remove from group',
                    onPressed: () => _removeDomainFromGroup(group, domain),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 2),
          // Actions. Height, radius and padding are textButtonTheme's; only
          // the foreground is local, because the artboard draws Add/Rename
          // neutral rather than in the accent and Delete in the error tone.
          Row(
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
                onPressed: () => _addDomainToGroup(group),
                icon: const Icon(Icons.add, size: 16),
                label: Text(AppLocalizations.of(context)!.commonAdd),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: scheme.onSurface),
                onPressed: () => _renameGroup(group),
                icon: const Icon(Icons.edit, size: 16),
                label: Text(AppLocalizations.of(context)!.commonRename),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: () => _confirmDeleteGroup(group),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: Text(AppLocalizations.of(context)!.commonDelete),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmDeleteGroup(DomainGroup group) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.splitTunnelDeleteGroupTitle),
        content: Text(
          AppLocalizations.of(
            context,
          )!.splitTunnelDeleteGroupMessage(group.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.commonCancel),
          ),
          // Destructive confirm: the primary shape in the error tone, so the
          // colour lives in the button rather than only in its label.
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () {
              Navigator.pop(context);
              _deleteGroup(group);
            },
            child: Text(AppLocalizations.of(context)!.commonDelete),
          ),
        ],
      ),
    );
  }

  /// State the app raises for a reason, so it stays visible on the screen
  /// rather than behind a hint.
  Widget _buildSuggestionBanner() {
    final scheme = _scheme;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline, color: scheme.primary, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.splitTunnelSuggestionTitle,
                  style: _textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Quiet action: textButtonTheme already sizes and types it.
              TextButton(
                onPressed: () => setState(() => _suggestions.clear()),
                child: const Text('Hide all'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ..._suggestions.map(
            (domain) => Row(
              children: [
                Expanded(
                  child: Text(
                    domain,
                    overflow: TextOverflow.ellipsis,
                    style: _mono(color: scheme.onSurface),
                  ),
                ),
                if (_groups.isNotEmpty)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: PopupMenuButton<DomainGroup>(
                      tooltip: l10n.splitTunnelSuggestionAddToGroup,
                      icon: const Icon(Icons.playlist_add, size: 18),
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      itemBuilder: (context) => _groups
                          .map(
                            (g) => PopupMenuItem(
                              value: g,
                              child: Text(l10n.splitTunnelToGroup(g.name)),
                            ),
                          )
                          .toList(),
                      onSelected: (group) =>
                          _addSuggestionToGroup(domain, group),
                    ),
                  ),
                // Sized by iconButtonTheme (28×28, radius 8).
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  color: scheme.primary,
                  tooltip: l10n.splitTunnelSuggestionAddStandalone,
                  onPressed: () => _addSuggestionToStandalone(domain),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: _dim,
                  tooltip: l10n.splitTunnelSuggestionHide,
                  onPressed: () => _dismissSuggestion(domain),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _pluralDomains(int count) {
    return AppLocalizations.of(context)!.splitTunnelDomainCount(count);
  }

  IconData _getDomainIcon(String domain) {
    switch (classifyExclusion(domain)) {
      case ExclusionKind.cidr:
        return Icons.hub;
      case ExclusionKind.ip:
        return Icons.router;
      case ExclusionKind.domain:
      case ExclusionKind.invalid:
        return Icons.language;
    }
  }

  /// Recompute the memoized Apps-tab rows for [query].
  ///
  /// Everything that does not depend on the query — lower-casing, space
  /// stripping, the known-name set and the alphabetical order — is done once
  /// per scan in [_indexInstalledApps]. What is left here is two linear
  /// passes with no string allocation and no sort over the scanned apps.
  void _rebuildAppsView(String query) {
    // Space-insensitive match, so "whatsapp" finds "Whats App Desktop" and
    // "apple music" finds "AppleMusic.exe".
    final compactQuery = query.replaceAll(' ', '');

    // Set lookups: _apps.contains inside the sort comparator was a linear
    // scan per comparison.
    final selected = _apps.toSet();
    _selectedAppsView = selected;

    // Selected apps the scanner didn't find (added manually, custom install
    // dirs, or picked on another machine) — must stay visible and removable,
    // never silently filtered out.
    _manualAppsView = _apps.where((a) {
      final l = a.toLowerCase();
      if (_installedNamesLower.contains(l)) return false;
      return query.isEmpty ||
          l.contains(query) ||
          l.replaceAll(' ', '').contains(compactQuery);
    }).toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    // Selected first, so what's enabled is visible without scrolling. Both
    // buckets keep the alphabetical order _installedApps was indexed in, so
    // partitioning replaces the old comparator sort.
    final selectedRows = <InstalledApp>[];
    final otherRows = <InstalledApp>[];
    for (var i = 0; i < _installedApps.length; i++) {
      final app = _installedApps[i];
      final isSelected = selected.contains(app.name);
      // Running processes are search-only: the default view shows the clean
      // Installed-Apps list (selected ones always stay).
      if (app.running && query.isEmpty && !isSelected) continue;
      final key = _appKeys[i];
      final hit =
          query.isEmpty ||
          key.nameLower.contains(query) ||
          key.nameCompact.contains(compactQuery) ||
          key.displayLower.contains(query) ||
          key.displayCompact.contains(compactQuery);
      if (!hit) continue;
      (isSelected ? selectedRows : otherRows).add(app);
    }
    _filteredAppsView = [...selectedRows, ...otherRows];
  }

  Widget _buildAppsTab() {
    final l10n = AppLocalizations.of(context)!;
    final query = _appSearchQuery.trim().toLowerCase();
    final viewKey = '$_appsRevision|$query';
    if (_appsViewKey != viewKey) {
      _appsViewKey = viewKey;
      _rebuildAppsView(query);
    }
    final manualApps = _manualAppsView;
    final filteredApps = _filteredAppsView;

    final nothingToShow = manualApps.isEmpty && filteredApps.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _islandHeader(
          label: 'Apps',
          subtitle: _vpnMode == VpnMode.general
              ? l10n.splitTunnelAppsExclude
              : l10n.splitTunnelAppsInclude,
          hint: l10n.splitTunnelAppsHint,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: _kControlHeight,
                child: TextField(
                  controller: _appSearchController,
                  style: _mono(color: _scheme.onSurface),
                  textAlignVertical: TextAlignVertical.center,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: Platform.isWindows
                        ? 'Search apps or type a process name (game.exe)'
                        : 'Search apps or type a process name',
                    hintStyle: _mono(color: _dim),
                    prefixIcon: Icon(Icons.search, size: 18, color: _dim),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 38,
                      minHeight: _kControlHeight,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  // No onSubmitted: Enter must never silently ADD the query
                  // as a process name — adding is the explicit "+" button.
                  onChanged: (value) {
                    setState(() {
                      _appSearchQuery = value;
                    });
                  },
                ),
              ),
            ),
            if (query.isNotEmpty) ...[
              const SizedBox(width: 8),
              _squareIconButton(
                child: IconButton.filled(
                  style: IconButton.styleFrom(
                    foregroundColor: _scheme.onPrimary,
                  ),
                  tooltip: 'Add "${_manualAppName()}" as a process name',
                  onPressed: _addManualApp,
                  icon: const Icon(Icons.add, size: 18),
                ),
              ),
            ],
            const SizedBox(width: 8),
            _squareIconButton(
              child: IconButton.outlined(
                style: IconButton.styleFrom(foregroundColor: _scheme.onSurface),
                tooltip: 'Rescan installed apps and running processes',
                onPressed: _isLoadingApps ? null : _loadInstalledApps,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _isLoadingApps
              ? const Center(child: CircularProgressIndicator())
              : nothingToShow
              ? _emptyState(
                  Icons.apps_outlined,
                  l10n.splitTunnelNoApps,
                  // KIT empty state: an optional OUTLINED button.
                  action: query.isEmpty
                      ? null
                      : OutlinedButton.icon(
                          onPressed: _addManualApp,
                          icon: const Icon(Icons.add, size: 18),
                          label: Text('Add "${_manualAppName()}"'),
                        ),
                )
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  // Every app row is the same fixed height, so the list can
                  // scroll by a known extent instead of laying out each child
                  // to measure it.
                  itemExtent: _kAppRowExtent,
                  itemCount: manualApps.length + filteredApps.length,
                  itemBuilder: (context, index) {
                    // Manual/unscanned entries first — always checked.
                    if (index < manualApps.length) {
                      final name = manualApps[index];
                      return _buildAppRow(
                        icon: Icon(Icons.terminal, size: 18, color: _dim),
                        title: name,
                        titleMono: true,
                        subtitle: 'Added manually',
                        selected: true,
                        onToggle: () => _toggleApp(name),
                      );
                    }

                    final app = filteredApps[index - manualApps.length];
                    return _buildAppRow(
                      icon: _appIcon(app),
                      title: app.displayName,
                      subtitle: app.running
                          ? '${app.name} · running'
                          : app.name,
                      subtitleMono: true,
                      // Set lookup: _apps.contains was a linear scan per row.
                      selected: _selectedAppsView.contains(app.name),
                      onToggle: () => _toggleApp(app.name),
                    );
                  },
                ),
        ),
        if (_apps.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                l10n.splitTunnelSelectedApps(_apps.length),
                style: _textTheme.bodySmall,
              ),
            ),
          ),
      ],
    );
  }

  /// One app row, at the artboard's fixed geometry: 26px icon well, 13px
  /// title over an 11.5px subtitle, radius 10, tonal fill when selected.
  ///
  /// The title is taken as text rather than a widget so the row can pin both
  /// line heights and therefore its own height — that fixed height is what
  /// lets the list declare an `itemExtent`.
  ///
  /// The row is one control, not two: the `InkWell` and the `Checkbox` it
  /// replaces both called the same [onToggle], which cost two focus stops per
  /// row for one action and left the ink surface itself unnamed (a tappable
  /// node with no label). [_CheckRow] merges them into a single named,
  /// checkable, focusable row and the box becomes the state readout it always
  /// looked like.
  Widget _buildAppRow({
    required Widget icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onToggle,
    bool titleMono = false,
    bool subtitleMono = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SizedBox(
        height: _kAppRowHeight,
        child: _CheckRow(
          checked: selected,
          background: selected
              ? _scheme.surfaceContainerHigh
              : _scheme.surfaceContainerLow,
          onTap: onToggle,
          child: Row(
            children: [
              SizedBox(width: 26, height: 26, child: Center(child: icon)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleMono
                          ? _mono(color: _scheme.onSurface, height: 1.25)
                          : TextStyle(
                              fontSize: 13,
                              height: 1.25,
                              color: _scheme.onSurface,
                            ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: subtitleMono
                          ? _mono(
                              size: 11.5,
                              height: 1.3,
                              color: _scheme.onSurfaceVariant,
                            )
                          : TextStyle(fontSize: 11.5, height: 1.3, color: _dim),
                    ),
                  ],
                ),
              ),
              // Same 22px slot the Material checkbox occupied, so nothing
              // else in the row moves.
              SizedBox(
                width: 22,
                height: 22,
                child: Center(child: _CheckMark(checked: selected)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pointer-driven row ──

/// A selectable list row that answers the **pointer**, not the touch point.
///
/// What it replaces: `Material` + `InkWell` + `Checkbox`. The ink surface threw
/// a ripple from wherever the cursor happened to be, and the checkbox drew its
/// own expanding circle — `Toggleable` paints that radial reaction straight
/// onto the canvas, so the theme's `NoSplash.splashFactory` never reached it.
///
/// In their place: a flat tint at the shared hover / press / focus strengths,
/// the app's 1.5px focus ring, and one merged semantics node carrying the
/// row's name, its checked state and its tap action.
class _CheckRow extends StatefulWidget {
  const _CheckRow({
    required this.checked,
    required this.onTap,
    required this.child,
    this.background = Colors.transparent,
  });

  final bool checked;

  /// The row's own ground; the pointer tint is blended over it. Transparent
  /// for a row that carries no fill of its own, so the tint lands straight on
  /// whatever surface the row sits on.
  final Color background;
  final VoidCallback onTap;
  final Widget child;

  /// Horizontal / vertical inset of the row's content, minus the ring the
  /// border always reserves — so the row's outer geometry, and the content
  /// inside it, are the same whether or not it has focus.
  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: 10 - kFocusRingWidth,
    vertical: 8 - kFocusRingWidth,
  );

  @override
  State<_CheckRow> createState() => _CheckRowState();
}

class _CheckRowState extends State<_CheckRow> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  void _setState(void Function() mutate, bool changed) {
    if (changed) setState(mutate);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final overlay = pointerOverlay(scheme.onSurface).resolve(<WidgetState>{
      if (_hovered) WidgetState.hovered,
      if (_focused) WidgetState.focused,
      if (_pressed) WidgetState.pressed,
    });
    final fill = overlay == null
        ? widget.background
        : Color.alphaBlend(overlay, widget.background);

    // The ring lives in a border that is always there and only changes
    // colour, so gaining focus never re-lays-out the row (the list declares a
    // fixed itemExtent, and a border that appears would shift the content).
    final surface = AnimatedContainer(
      duration: kStateChangeDuration,
      curve: kMotionCurve,
      padding: _CheckRow.padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _focused ? scheme.primary : Colors.transparent,
          width: kFocusRingWidth,
        ),
      ),
      child: widget.child,
    );

    return MergeSemantics(
      child: Semantics(
        container: true,
        checked: widget.checked,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (v) =>
              _setState(() => _hovered = v, _hovered != v),
          onShowFocusHighlight: (v) =>
              _setState(() => _focused = v, _focused != v),
          // Space and enter toggle the row, as they would a checkbox.
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
            ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
              onInvoke: (_) {
                widget.onTap();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onTapDown: (_) => _setState(() => _pressed = true, !_pressed),
            onTapUp: (_) => _setState(() => _pressed = false, _pressed),
            onTapCancel: () => _setState(() => _pressed = false, _pressed),
            child: surface,
          ),
        ),
      ),
    );
  }
}

/// The check state of a [_CheckRow], drawn at the kit's geometry: a 16px box
/// at radius 4, hairline when off, filled with the accent when on.
///
/// It is a readout, not a control — the row it sits in is the control — so it
/// declares no semantics and no gesture of its own.
class _CheckMark extends StatelessWidget {
  const _CheckMark({required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: kStateChangeDuration,
      curve: kMotionCurve,
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: checked ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: checked ? scheme.primary : scheme.outline,
          width: 1.5,
        ),
      ),
      child: checked
          ? Icon(Icons.check, size: 11, color: scheme.onPrimary)
          : null,
    );
  }
}

/// Query-independent search keys for one scanned app, built once per scan.
class _AppSearchKey {
  final String nameLower;
  final String nameCompact;
  final String displayLower;
  final String displayCompact;

  _AppSearchKey._(
    this.nameLower,
    this.nameCompact,
    this.displayLower,
    this.displayCompact,
  );

  factory _AppSearchKey(InstalledApp app) {
    final name = app.name.toLowerCase();
    final display = app.displayName.toLowerCase();
    return _AppSearchKey._(
      name,
      name.replaceAll(' ', ''),
      display,
      display.replaceAll(' ', ''),
    );
  }
}

// ── One-field prompt dialog ──

/// The rename / add-to-group / paste-list prompts.
///
/// The dialog owns its [TextEditingController] for as long as its route
/// exists. Creating the controller next to the `showDialog` call and disposing
/// it on the line after is a use-after-dispose: that future completes when the
/// route is *popped*, while the dialog keeps rebuilding — and the field keeps
/// listening to the controller — until the exit transition ends.
class _TextPromptDialog extends StatefulWidget {
  final String title;

  /// Optional line of explanation above the field.
  final String? caption;
  final String hint;
  final String initialText;
  final String confirmLabel;
  final Widget? prefixIcon;

  /// Fixed dialog width, for the prompts that hold a wide block of text.
  final double? width;
  final int minLines;
  final int maxLines;

  /// Whether the answer comes back trimmed (single-line prompts) or verbatim
  /// (the pasted list, which the caller splits line by line).
  final bool trimResult;

  const _TextPromptDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    this.caption,
    this.initialText = '',
    this.prefixIcon,
    this.width,
    this.minLines = 1,
    this.maxLines = 1,
    this.trimResult = true,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text;
    Navigator.pop(context, widget.trimResult ? text.trim() : text);
  }

  /// How tall the field is allowed to grow. An [AlertDialog] does not scroll,
  /// so a field that asks for more lines than the window can hold overflows
  /// the dialog instead. One line of the input style is ~24 logical pixels,
  /// and the dialog's own insets, title, caption and actions take ~330.
  int get _fittedMaxLines {
    if (widget.maxLines <= widget.minLines) return widget.maxLines;
    const lineHeight = 24.0;
    const dialogChrome = 330.0;
    final fits =
        ((MediaQuery.sizeOf(context).height - dialogChrome) / lineHeight)
            .floor();
    return fits.clamp(widget.minLines, widget.maxLines);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final singleLine = widget.maxLines == 1;

    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: widget.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.caption != null) ...[
              Text(widget.caption!),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: widget.minLines,
              maxLines: _fittedMaxLines,
              // Border, radius and fill come from inputDecorationTheme.
              decoration: InputDecoration(
                hintText: widget.hint,
                prefixIcon: widget.prefixIcon,
              ),
              // Enter confirms a one-line prompt; in a multi-line one it is a
              // newline, so the button is the only way to confirm.
              onSubmitted: singleLine ? (_) => _submit() : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

// ── Add routing list dialog ──

enum _ListSource { preset, url, file }

class _AddRoutingListDialog extends StatefulWidget {
  final ConfigService configService;

  const _AddRoutingListDialog({required this.configService});

  @override
  State<_AddRoutingListDialog> createState() => _AddRoutingListDialogState();
}

class _AddRoutingListDialogState extends State<_AddRoutingListDialog> {
  final _name = TextEditingController();
  final _urls = TextEditingController();
  final _path = TextEditingController();
  _ListSource _source = _ListSource.preset;
  RoutingPreset? _preset;
  bool _busy = false;
  String? _checkResult;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _urls.dispose();
    _path.dispose();
    super.dispose();
  }

  List<String> get _urlList =>
      _urls.text.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList();

  Future<void> _browse() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Lists', extensions: ['lst', 'txt']),
        const XTypeGroup(label: 'All files'),
      ],
    );
    if (file != null) {
      setState(() {
        _path.text = file.path;
        if (_name.text.trim().isEmpty) {
          _name.text = file.name.replaceAll(RegExp(r'\.(lst|txt)$'), '');
        }
      });
    }
  }

  bool get _sourceFilled => switch (_source) {
    _ListSource.preset => _preset != null,
    _ListSource.url => _urlList.isNotEmpty,
    _ListSource.file => _path.text.trim().isNotEmpty,
  };

  List<String> get _sourceUrls => switch (_source) {
    _ListSource.preset => _preset!.urls,
    _ListSource.url => _urlList,
    _ListSource.file => const [],
  };

  String get _sourceFile =>
      _source == _ListSource.file ? _path.text.trim() : '';

  String get _sourceFormat =>
      _source == _ListSource.preset ? _preset!.format : 'plain';

  /// Dry-run fetch: shows "Found N valid entries (M skipped)" before saving.
  Future<void> _check() async {
    setState(() {
      _busy = true;
      _checkResult = null;
      _error = null;
    });
    try {
      final (entries, skipped, errors) = await widget.configService
          .fetchRoutingSource(
            urls: _sourceUrls,
            filePath: _sourceFile,
            format: _sourceFormat,
          );
      if (!mounted) return;
      setState(() {
        _checkResult =
            '${entries.length} entries${skipped > 0 ? ' · $skipped skipped' : ''}'
            '${errors.isNotEmpty ? ' · ${errors.length} sources failed' : ''}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _add() async {
    final fallbackName = switch (_source) {
      _ListSource.preset => _preset!.name,
      _ListSource.url => 'Custom list',
      _ListSource.file => 'Local list',
    };
    final name = _name.text.trim().isEmpty ? fallbackName : _name.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final list = await widget.configService.addRoutingList(
        name: name,
        urls: _sourceUrls,
        filePath: _sourceFile,
        format: _sourceFormat,
      );
      if (mounted) Navigator.pop(context, list);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  /// What every source shares: the file format the fetcher accepts.
  static const String _formatHint =
      'A plain-text list: one domain, IP or CIDR per line. # comments are '
      'allowed.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final dim = dimTextOf(scheme);
    // _monoFallback is computed once; kMonoFontStack.sublist(1) allocated a
    // new list on every rebuild of this dialog (one per keystroke).
    final mono = TextStyle(
      fontFamily: kMonoFontStack.first,
      fontFamilyFallback: _monoFallback,
      fontSize: 12.5,
    );

    Widget hintedLabel(String label, String hint) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: hint,
          child: Icon(Icons.info_outline, size: 15, color: dim),
        ),
      ],
    );

    return AlertDialog(
      title: const Text('Add routing list'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<_ListSource>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: _ListSource.preset,
                  icon: const Icon(Icons.category_outlined, size: 18),
                  label: Text(l10n.splitTunnelSourcePreset),
                ),
                const ButtonSegment(
                  value: _ListSource.url,
                  icon: Icon(Icons.link, size: 18),
                  label: Text('From URL'),
                ),
                const ButtonSegment(
                  value: _ListSource.file,
                  icon: Icon(Icons.description_outlined, size: 18),
                  label: Text('From file'),
                ),
              ],
              selected: {_source},
              onSelectionChanged: (v) => setState(() {
                _source = v.first;
                _checkResult = null;
                _error = null;
              }),
            ),
            const SizedBox(height: 10),
            // Refresh behaviour differs by source: URL-backed lists age out,
            // a local file only changes when the user says so (COPY §5).
            Text(
              _source == _ListSource.file
                  ? 'Edited the file? Press Update now.'
                  : 'Lists older than 24 hours are refreshed when you connect',
              style: theme.textTheme.bodySmall?.copyWith(color: dim),
            ),
            const SizedBox(height: 12),
            if (_source == _ListSource.preset) ...[
              hintedLabel(
                l10n.splitTunnelPresetPick,
                l10n.splitTunnelPresetHint,
              ),
              const SizedBox(height: 6),
              // The visible caption above the field is a sibling Text, so
              // the button itself reads as an unnamed glyph until a preset
              // is picked.
              Semantics(
                label: l10n.splitTunnelPresetPick,
                child: DropdownButtonFormField<RoutingPreset>(
                  initialValue: _preset,
                  isExpanded: true,
                  decoration: const InputDecoration(isDense: true),
                  items: [
                    for (final p in routingPresets)
                      DropdownMenuItem(value: p, child: Text(p.name)),
                  ],
                  onChanged: (p) => setState(() {
                    // Follow the picked preset's name unless the user typed
                    // their own.
                    if (_name.text.trim().isEmpty ||
                        _name.text == _preset?.name) {
                      _name.text = p?.name ?? '';
                    }
                    _preset = p;
                    _checkResult = null;
                    _error = null;
                  }),
                ),
              ),
            ] else if (_source == _ListSource.file) ...[
              hintedLabel('File path', _formatHint),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _path,
                      style: mono,
                      decoration: const InputDecoration(isDense: true),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _browse,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Browse'),
                  ),
                ],
              ),
            ] else ...[
              hintedLabel('Raw URL(s), one per line', _formatHint),
              const SizedBox(height: 6),
              TextField(
                controller: _urls,
                minLines: 1,
                maxLines: 4,
                style: mono,
                decoration: InputDecoration(
                  isDense: true,
                  hintText:
                      'https://raw.githubusercontent.com/user/repo/main/list.lst',
                  hintStyle: mono.copyWith(color: dim),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: 12),
            if (_busy)
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Fetching…'),
                ],
              )
            else if (_error != null)
              Text(_error!, style: TextStyle(color: scheme.error, fontSize: 13))
            else if (_checkResult != null)
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_checkResult!, style: mono)),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        OutlinedButton(
          onPressed: (_busy || !_sourceFilled) ? null : _check,
          child: const Text('Check'),
        ),
        FilledButton(
          onPressed: (_busy || !_sourceFilled) ? null : _add,
          child: Text(l10n.commonAdd),
        ),
      ],
    );
  }
}

// ── Discovery Dialog ──

class _DiscoveryDialogResult {
  final bool createGroup;
  final String groupName;
  final List<String> selectedDomains;

  _DiscoveryDialogResult({
    required this.createGroup,
    required this.groupName,
    required this.selectedDomains,
  });
}

class _DiscoveryDialog extends StatefulWidget {
  final String domain;
  final DomainDiscoveryService discoveryService;

  const _DiscoveryDialog({
    required this.domain,
    required this.discoveryService,
  });

  @override
  State<_DiscoveryDialog> createState() => _DiscoveryDialogState();
}

class _DiscoveryDialogState extends State<_DiscoveryDialog> {
  bool _isLoading = true;
  List<String> _discovered = [];
  Map<String, bool> _selected = {};
  String? _error;
  late TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    // Capitalize first letter for group name
    final name = widget.domain.split('.').first;
    _nameController = TextEditingController(
      text: name[0].toUpperCase() + name.substring(1),
    );
    _discover();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    final result = await widget.discoveryService.discoverRelatedDomains(
      widget.domain,
    );
    if (!mounted) return;

    setState(() {
      _isLoading = false;
      _discovered = result.discoveredDomains;
      _selected = {for (final d in result.discoveredDomains) d: true};
      _error = result.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = dimTextOf(theme.colorScheme);
    final statusColors = theme.extension<StatusColors>()!;

    return AlertDialog(
      title: Text(AppLocalizations.of(context)!.discoveryTitle(widget.domain)),
      content: SizedBox(
        width: 420,
        child: _isLoading
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(AppLocalizations.of(context)!.discoverySearching),
                  ],
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_discovered.isNotEmpty) ...[
                      Text(
                        AppLocalizations.of(context)!.discoveryRelatedFound,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _nameController,
                        decoration: InputDecoration(
                          labelText: AppLocalizations.of(
                            context,
                          )!.discoveryGroupName,
                          prefixIcon: const Icon(
                            Icons.folder_outlined,
                            size: 20,
                          ),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Primary domain (always included, not toggleable). It
                      // is drawn at the same geometry as the choices below it
                      // but as a plain row: nothing to hover, nothing to
                      // focus, because there is nothing to decide.
                      Padding(
                        padding: _CheckRow.padding,
                        child: Row(
                          children: [
                            Icon(Icons.language, size: 18, color: dim),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                widget.domain,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Icon(
                              Icons.check,
                              size: 16,
                              color: statusColors.connected,
                            ),
                          ],
                        ),
                      ),
                      // Discovered domains, each a row the pointer can take:
                      // `CheckboxListTile` put a Material ripple under the row
                      // and a second expanding circle around the box.
                      ..._discovered.map((domain) {
                        final checked = _selected[domain] ?? false;
                        return _CheckRow(
                          checked: checked,
                          onTap: () =>
                              setState(() => _selected[domain] = !checked),
                          child: Row(
                            children: [
                              Icon(Icons.link, size: 18, color: dim),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  domain,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              _CheckMark(checked: checked),
                            ],
                          ),
                        );
                      }),
                    ] else ...[
                      if (_error != null) ...[
                        Icon(
                          Icons.info_outline,
                          size: 32,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        AppLocalizations.of(context)!.discoveryNoRelated,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppLocalizations.of(context)!.discoveryAddStandalone,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          // `outline` is the border tone; as a caption colour
                          // it lands under the AA floor.
                          color: dimTextOf(Theme.of(context).colorScheme),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: _isLoading
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context)!.commonCancel),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context)!.commonCancel),
              ),
              if (_discovered.isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    _DiscoveryDialogResult(
                      createGroup: false,
                      groupName: '',
                      selectedDomains: [],
                    ),
                  ),
                  child: Text(
                    AppLocalizations.of(context)!.discoveryWithoutGroup,
                  ),
                ),
              FilledButton(
                onPressed: () {
                  final selected = _selected.entries
                      .where((e) => e.value)
                      .map((e) => e.key)
                      .toList();
                  Navigator.pop(
                    context,
                    _DiscoveryDialogResult(
                      createGroup: _discovered.isNotEmpty,
                      groupName: _nameController.text.trim().isEmpty
                          ? widget.domain
                          : _nameController.text.trim(),
                      selectedDomains: selected,
                    ),
                  );
                },
                child: Text(
                  _discovered.isNotEmpty
                      ? AppLocalizations.of(context)!.discoveryAddGroup
                      : AppLocalizations.of(context)!.commonAdd,
                ),
              ),
            ],
    );
  }
}

// ── Models ──

class InstalledApp {
  final String name;
  final String displayName;
  final String path;

  /// True when this entry comes from the running-process list rather than an
  /// install location — the exact process name the client's filter matches.
  final bool running;

  /// PNG icon extracted from the app ('' = none, show the generic icon).
  final String iconPath;

  InstalledApp({
    required this.name,
    required this.displayName,
    required this.path,
    this.running = false,
    this.iconPath = '',
  });

  InstalledApp withIcon(String icon) => InstalledApp(
    name: name,
    displayName: displayName,
    path: path,
    running: running,
    iconPath: icon,
  );
}

// ── App discovery (Fix #2) ──
//
// These run inside `Isolate.run`, so they must be top-level (no `this`, no
// BuildContext). They are pure IO/CPU and return sendable `InstalledApp`s
// (only `final String`/`bool` fields).
//
// Windows sources mirror Settings → Apps → Installed apps: the registry
// Uninstall hives (classic installers) + Get-AppxPackage (Store/MSIX),
// with real app icons extracted into a temp cache. No blind filesystem
// walks — those surfaced every helper and uninstaller exe on the machine.
// Running processes are a separate, search-only source.

Future<List<InstalledApp>> _discoverInstalledApps() async {
  final apps = Platform.isMacOS
      ? await _getInstalledAppsMacOS()
      : await _getInstalledAppsWindows();

  // Running processes cover portable builds and games no installer knows
  // about, with the exact process name the client's filter matches. The UI
  // shows them only in search results so the default list stays clean.
  final running = await _getRunningProcesses();
  final known = apps.map((a) => a.name.toLowerCase()).toSet();
  apps.addAll(running.where((r) => !known.contains(r.name.toLowerCase())));
  return apps;
}

/// Parse a registry DisplayIcon value down to an .exe path, or null.
/// Handles `"C:\p\app.exe",0`, `C:\p\app.exe,0`, plain paths; .ico
/// references yield null (they identify no process).
String? registryIconExePath(String? displayIcon) {
  var icon = (displayIcon ?? '').trim().replaceAll('"', '');
  if (icon.isEmpty) return null;
  final comma = icon.lastIndexOf(',');
  if (comma > 0 && int.tryParse(icon.substring(comma + 1).trim()) != null) {
    icon = icon.substring(0, comma).trim();
  }
  return icon.toLowerCase().endsWith('.exe') ? icon : null;
}

String _winBasename(String path) => path.split('\\').last.split('/').last;

/// Classic installed applications from the registry Uninstall hives — the
/// same set Windows shows in Settings → Apps → Installed apps. The process
/// name comes from DisplayIcon (usually the app's own exe) or a shallow
/// InstallLocation scan.
Future<List<InstalledApp>> _getRegistryAppsWindows() async {
  final apps = <InstalledApp>[];
  try {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r"Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 } | Select-Object DisplayName, DisplayIcon, InstallLocation | ConvertTo-Json -Compress",
    ]).timeout(const Duration(seconds: 20));
    if (result.exitCode != 0) return apps;

    final decoded = jsonDecode((result.stdout as String).trim());
    final items = decoded is List ? decoded : [decoded];
    final seen = <String>{};
    for (final item in items) {
      final name = (item['DisplayName'] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;
      final exePath = await _resolveRegistryExe(
        item['DisplayIcon'] as String?,
        item['InstallLocation'] as String?,
        name,
      );
      if (exePath == null) continue;
      final exe = _winBasename(exePath);
      if (!seen.add(exe.toLowerCase())) continue;
      apps.add(InstalledApp(name: exe, displayName: name, path: exePath));
    }
  } catch (e) {
    debugPrint('Registry app scan failed: $e');
  }
  return apps;
}

/// Map an Uninstall entry to its main executable: DisplayIcon first, else
/// the best exe found by a shallow (2-level) InstallLocation scan.
Future<String?> _resolveRegistryExe(
  String? displayIcon,
  String? installLocation,
  String displayName,
) async {
  final fromIcon = registryIconExePath(displayIcon);
  if (fromIcon != null &&
      !_isSystemExecutable(_winBasename(fromIcon)) &&
      await File(fromIcon).exists()) {
    return fromIcon;
  }

  final loc = (installLocation ?? '').trim().replaceAll('"', '');
  if (loc.isEmpty) return null;
  final dir = Directory(loc);
  if (!await dir.exists()) return null;

  final candidates = <File>[];
  try {
    await for (final e in dir.list(recursive: false)) {
      if (e is File && e.path.toLowerCase().endsWith('.exe')) {
        candidates.add(e);
      } else if (e is Directory) {
        try {
          await for (final f in e.list(recursive: false)) {
            if (f is File && f.path.toLowerCase().endsWith('.exe')) {
              candidates.add(f);
            }
          }
        } catch (_) {}
      }
    }
  } catch (_) {}

  final usable = candidates
      .where((f) => !_isSystemExecutable(_winBasename(f.path)))
      .toList();
  if (usable.isEmpty) return null;

  // Prefer the exe whose name appears in the display name (chrome.exe for
  // "Google Chrome"); otherwise the largest binary is usually the app.
  String alnum(String v) =>
      v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final dn = alnum(displayName);
  for (final f in usable) {
    final stem = alnum(
      _winBasename(
        f.path,
      ).replaceAll(RegExp(r'\.exe$', caseSensitive: false), ''),
    );
    if (stem.length >= 3 && dn.contains(stem)) return f.path;
  }
  int sizeOf(File f) {
    try {
      return f.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  usable.sort((a, b) => sizeOf(b).compareTo(sizeOf(a)));
  return usable.first.path;
}

/// Deterministic, file-safe cache name for an exe path's icon PNG.
String iconCacheName(String exePath) {
  final safe = exePath.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
  final tail = safe.length > 80 ? safe.substring(safe.length - 80) : safe;
  return '${tail}_${exePath.length}.png';
}

/// Extract app icons for [exePaths] as PNGs into a temp cache with ONE
/// PowerShell batch (System.Drawing ExtractAssociatedIcon — no plugins).
/// Returns exePath → pngPath for successes; failures are simply absent.
Future<Map<String, String>> _extractIconsWindows(List<String> exePaths) async {
  final out = <String, String>{};
  if (exePaths.isEmpty) return out;
  try {
    final dir = Directory('${Directory.systemTemp.path}\\trusty_icons');
    if (!await dir.exists()) await dir.create(recursive: true);

    final jobs = <Map<String, String>>[];
    for (final exe in exePaths) {
      final png = '${dir.path}\\${iconCacheName(exe)}';
      if (await File(png).exists()) {
        out[exe] = png;
      } else {
        jobs.add({'exe': exe, 'png': png});
      }
    }
    if (jobs.isNotEmpty) {
      final manifest = File('${dir.path}\\jobs.json');
      await manifest.writeAsString(jsonEncode(jobs));
      final script = File('${dir.path}\\extract.ps1');
      await script.writeAsString(
        'Add-Type -AssemblyName System.Drawing\n'
        "\$jobs = ConvertFrom-Json ([IO.File]::ReadAllText('${manifest.path}'))\n"
        'foreach (\$j in \$jobs) {\n'
        '  try {\n'
        '    \$i = [System.Drawing.Icon]::ExtractAssociatedIcon(\$j.exe)\n'
        '    if (\$i) { \$i.ToBitmap().Save(\$j.png, [System.Drawing.Imaging.ImageFormat]::Png) }\n'
        '  } catch {}\n'
        '}\n',
      );
      await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
      ]).timeout(const Duration(seconds: 30));
      for (final j in jobs) {
        if (await File(j['png']!).exists()) out[j['exe']!] = j['png']!;
      }
    }
  } catch (e) {
    debugPrint('Icon extraction failed: $e');
  }
  return out;
}

Future<List<InstalledApp>> _getInstalledAppsWindows() async {
  final apps = <InstalledApp>[
    ...await _getRegistryAppsWindows(),
    // Store (MSIX/UWP) apps — Apple Music, WhatsApp etc. — are part of the
    // system's Installed Apps list too, reachable only via the package
    // manager.
    ...await _getStoreAppsWindows(),
  ];

  final deduped = _deduplicateAndSort(apps);

  // Icons in one batch, cached in temp; Store apps already carry a PNG.
  final icons = await _extractIconsWindows([
    for (final a in deduped)
      if (a.iconPath.isEmpty && a.path.toLowerCase().endsWith('.exe')) a.path,
  ]);
  return [
    for (final a in deduped)
      icons.containsKey(a.path) ? a.withIcon(icons[a.path]!) : a,
  ];
}

/// "AppleInc.AppleMusicWin" → "Apple Music Win": drop the publisher prefix
/// and split camel case, so Store packages are readable and searchable.
String storeAppDisplayName(String packageName) {
  var name = packageName.contains('.')
      ? packageName.substring(packageName.indexOf('.') + 1)
      : packageName;
  name = name.replaceAll('.', ' ');
  return name.replaceAllMapped(RegExp(r'(?<=[a-z0-9])(?=[A-Z])'), (_) => ' ');
}

/// All process names declared in an AppxManifest — one per `<Application>`
/// node. The first is NOT always the main app (Xbox lists its helpers
/// first), so every declared executable becomes a list entry. Unexpanded
/// manifest tokens (`$targetnametoken$.exe`) are skipped.
List<String> manifestExecutables(String manifestXml) {
  final seen = <String>{};
  final result = <String>[];
  for (final m in RegExp(
    r'Executable="([^"]+\.exe)"',
    caseSensitive: false,
  ).allMatches(manifestXml)) {
    final exe = m.group(1)!.split(RegExp(r'[\\/]')).last;
    if (exe.contains(r'$')) continue;
    if (seen.add(exe.toLowerCase())) result.add(exe);
  }
  return result;
}

/// Resolve an AppxManifest `<Logo>` path to an actual asset file (packages
/// ship `Logo.scale-200.png`-style variants, rarely the literal name).
Future<String?> _resolveStoreLogo(String location, String logo) async {
  final rel = logo.replaceAll('/', '\\');
  final exact = File('$location\\$rel');
  if (await exact.exists()) return exact.path;

  final dot = rel.lastIndexOf('.');
  if (dot < 0) return null;
  final stem = rel.substring(0, dot);
  for (final variant in [
    'scale-100',
    'scale-125',
    'scale-150',
    'scale-200',
    'scale-400',
    'targetsize-48',
    'targetsize-32',
  ]) {
    final f = File('$location\\$stem.$variant.png');
    if (await f.exists()) return f.path;
  }

  // Last resort: any asset starting with the stem's basename.
  try {
    final sep = stem.lastIndexOf('\\');
    final assetDir = Directory(
      sep < 0 ? location : '$location\\${stem.substring(0, sep)}',
    );
    final prefix = _winBasename(stem).toLowerCase();
    if (await assetDir.exists()) {
      await for (final f in assetDir.list(recursive: false)) {
        if (f is File &&
            _winBasename(f.path).toLowerCase().startsWith('$prefix.')) {
          return f.path;
        }
      }
    }
  } catch (_) {}
  return null;
}

/// Microsoft Store apps via `Get-AppxPackage`: package name + install
/// location, then process names and the logo from each AppxManifest.xml.
Future<List<InstalledApp>> _getStoreAppsWindows() async {
  final apps = <InstalledApp>[];
  try {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'Get-AppxPackage | Where-Object { -not $_.IsFramework } | Select-Object Name, InstallLocation | ConvertTo-Json -Compress',
    ]).timeout(const Duration(seconds: 20));
    if (result.exitCode != 0) return apps;

    final decoded = jsonDecode((result.stdout as String).trim());
    final packages = decoded is List ? decoded : [decoded];
    // System shell packages live under C:\Windows (SystemApps entries carry
    // GUID names, "windows.immersivecontrolpanel" sits right in C:\Windows),
    // so filter by location as well as by name prefix.
    final winDir = (Platform.environment['WINDIR'] ?? r'C:\Windows')
        .toLowerCase();
    for (final pkg in packages) {
      final name = pkg['Name'] as String? ?? '';
      final location = pkg['InstallLocation'] as String? ?? '';
      if (name.isEmpty || location.isEmpty) continue;
      if (name.startsWith('Microsoft.Windows') ||
          name.startsWith('MicrosoftWindows.') ||
          location.toLowerCase().startsWith('$winDir\\')) {
        continue;
      }
      var exes = const <String>[];
      var iconPath = '';
      try {
        final manifest = File('$location\\AppxManifest.xml');
        if (await manifest.exists()) {
          final xml = await manifest.readAsString();
          exes = manifestExecutables(xml);
          final logo = RegExp(
            r'<Logo>([^<]+)</Logo>',
          ).firstMatch(xml)?.group(1);
          if (logo != null) {
            iconPath = await _resolveStoreLogo(location, logo.trim()) ?? '';
          }
        }
      } catch (_) {}

      final display = storeAppDisplayName(name);
      for (final exe in exes) {
        apps.add(
          InstalledApp(
            name: exe,
            displayName: display,
            path: location,
            iconPath: iconPath,
          ),
        );
      }
    }
  } catch (_) {
    // PowerShell unavailable/slow — the rest of the scan still works.
  }
  return apps;
}

/// Extract the process name from a `tasklist /fo csv` line.
/// Returns null for lines that don't parse.
String? tasklistProcessName(String csvLine) {
  return RegExp(r'^"([^"]+)"').firstMatch(csvLine)?.group(1);
}

/// Infrastructure processes that make no sense as split-tunnel entries —
/// including our own client (routing the tunnel through itself).
const _systemProcesses = {
  // Windows
  'svchost.exe', 'csrss.exe', 'wininit.exe', 'winlogon.exe', 'smss.exe',
  'lsass.exe', 'services.exe', 'dwm.exe', 'fontdrvhost.exe', 'conhost.exe',
  'runtimebroker.exe', 'sihost.exe', 'taskhostw.exe', 'dllhost.exe',
  'searchindexer.exe', 'spoolsv.exe', 'audiodg.exe', 'ctfmon.exe',
  'msmpeng.exe', 'securityhealthservice.exe', 'registry', 'system',
  'memory compression', 'tasklist.exe',
  // macOS
  'launchd', 'kernel_task', 'windowserver', 'loginwindow', 'cfprefsd',
  'distnoted', 'mds', 'mds_stores', 'mdworker', 'ps',
  // This app
  'trusty.exe', 'trusttunnel_client.exe', 'trusty', 'trusttunnel_client',
};

/// Currently running processes (tasklist / ps). Marked with `running: true`
/// so the UI can label them and show them only during search.
Future<List<InstalledApp>> _getRunningProcesses() async {
  final names = <String>{};
  try {
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', [
        '/fo',
        'csv',
        '/nh',
      ]).timeout(const Duration(seconds: 10));
      if (result.exitCode != 0) return [];
      for (final line in const LineSplitter().convert(
        result.stdout as String,
      )) {
        final name = tasklistProcessName(line);
        if (name != null &&
            name.toLowerCase().endsWith('.exe') &&
            !_systemProcesses.contains(name.toLowerCase())) {
          names.add(name);
        }
      }
    } else {
      final result = await Process.run('ps', [
        '-axco',
        'comm=',
      ]).timeout(const Duration(seconds: 10));
      if (result.exitCode != 0) return [];
      for (final line in const LineSplitter().convert(
        result.stdout as String,
      )) {
        final name = line.trim();
        if (name.isNotEmpty && !_systemProcesses.contains(name.toLowerCase())) {
          names.add(name);
        }
      }
    }
  } catch (_) {
    return [];
  }

  final sorted = names.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return sorted
      .map(
        (n) => InstalledApp(
          name: n,
          displayName: n.toLowerCase().endsWith('.exe')
              ? n.substring(0, n.length - 4)
              : n,
          path: '',
          running: true,
        ),
      )
      .toList();
}

Future<List<InstalledApp>> _getInstalledAppsMacOS() async {
  final apps = <InstalledApp>[];

  final homeDir =
      Platform.environment['HOME'] ?? '/Users/${Platform.environment['USER']}';
  final searchDirs = [
    '/Applications',
    // System apps — Music (Apple Music), Safari, Mail live here, not in
    // /Applications.
    '/System/Applications',
    '$homeDir/Applications',
  ];

  for (final dirPath in searchDirs) {
    final dir = Directory(dirPath);
    if (!await dir.exists()) continue;

    try {
      await for (final entity in dir.list(recursive: false)) {
        if (entity is Directory && entity.path.endsWith('.app')) {
          final appName = entity.path.split('/').last.replaceAll('.app', '');
          // Try to find the actual binary name inside the bundle
          final macosDir = Directory('${entity.path}/Contents/MacOS');
          String processName = appName;
          if (await macosDir.exists()) {
            try {
              await for (final bin in macosDir.list(recursive: false)) {
                if (bin is File) {
                  processName = bin.path.split('/').last;
                  break;
                }
              }
            } catch (_) {}
          }
          if (!_isSystemAppMacOS(appName)) {
            apps.add(
              InstalledApp(
                name: processName,
                displayName: appName,
                path: entity.path,
              ),
            );
          }
        }
      }
    } catch (_) {}
  }

  return _deduplicateAndSort(apps);
}

bool _isSystemAppMacOS(String appName) {
  final systemApps = [
    'Utilities',
    'Automator',
    'Migration Assistant',
    'System Preferences',
    'System Settings',
  ];
  return systemApps.any((s) => appName.contains(s));
}

List<InstalledApp> _deduplicateAndSort(List<InstalledApp> apps) {
  apps.sort((a, b) => a.displayName.compareTo(b.displayName));

  final seen = <String>{};
  apps.removeWhere((app) {
    final key = app.name.toLowerCase();
    if (seen.contains(key)) return true;
    seen.add(key);
    return false;
  });

  return apps;
}

bool _isSystemExecutable(String name) {
  final systemExes = [
    'uninstall',
    'uninst',
    'setup',
    'install',
    'update',
    'updater',
    'helper',
    'crash',
    'reporter',
    'service',
  ];
  final lowerName = name.toLowerCase();
  return systemExes.any((s) => lowerName.contains(s));
}

// ── Log suggestion extraction (Fix #3) ──

/// Pure helper: scan [lines] for domain-like tokens and return new suggestions
/// not already present in [existingDomains] or [existingSuggestions], capped at
/// [remainingSlots]. Extracted as a top-level function so it can be unit
/// tested without any widget plumbing.
List<String> extractDomainSuggestions(
  Iterable<String> lines, {
  required Set<String> existingDomains,
  required List<String> existingSuggestions,
  required int remainingSlots,
}) {
  if (remainingSlots <= 0) return const [];

  final domainPattern = RegExp(r'(?:[\w-]+\.)+[a-zA-Z]{2,}');
  final newSuggestions = <String>[];
  final seen = <String>{};

  for (final line in lines) {
    for (final match in domainPattern.allMatches(line)) {
      final domain = match.group(0)!.toLowerCase();
      if (existingDomains.contains(domain)) continue;
      if (existingSuggestions.contains(domain)) continue;
      if (seen.contains(domain)) continue;
      if (domain.endsWith('.local') || domain.endsWith('.internal')) continue;
      if (domain == 'trusttunnel.com') continue;
      if (newSuggestions.length >= remainingSlots) return newSuggestions;
      seen.add(domain);
      newSuggestions.add(domain);
    }
  }

  return newSuggestions;
}

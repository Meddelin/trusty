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
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';

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
    _tabController = TabController(length: 2, vsync: this);
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

    final routingLists = await configService.loadRoutingLists();
    if (!mounted) return;

    setState(() {
      _vpnMode = config.vpnMode;
      _groups = List.from(groupsData.groups);
      _standaloneDomains = List.from(groupsData.standaloneDomains);
      _apps = List.from(config.splitTunnelApps);
      _routingLists = routingLists;
      _isLoading = false;
    });

    _rebuildDomainsCache();
    _startLogMonitoring();
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

    if (_getAllCurrentDomains().contains(entry)) {
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

    final existing = _getAllCurrentDomains()..remove(domain);
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
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste list'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'One domain, IP or CIDR per line (commas and spaces also work):',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 6,
                maxLines: 14,
                decoration: const InputDecoration(
                  hintText: '92.255.112.0/20\nalfa.bank\nvk.com\nya.ru',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(AppLocalizations.of(context)!.commonAdd),
          ),
        ],
      ),
    );
    controller.dispose();

    if (raw == null) return;

    final (toAdd, invalid) =
        importExclusionList(raw, _getAllCurrentDomains());

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
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          AppLocalizations.of(context)!.splitTunnelAddToGroup(group.name),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.splitTunnelEnterDomain,
            prefixIcon: Icon(Icons.add_link, size: 20),
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(AppLocalizations.of(context)!.commonAdd),
          ),
        ],
      ),
    );
    controller.dispose();

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
    if (_getAllCurrentDomains().contains(entry)) {
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
    final controller = TextEditingController(text: group.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.splitTunnelRenameGroup),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.splitTunnelGroupName,
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(AppLocalizations.of(context)!.commonSave),
          ),
        ],
      ),
    );
    controller.dispose();

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
  Widget _appIcon(InstalledApp app) {
    if (app.iconPath.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(app.iconPath),
          width: 26,
          height: 26,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, e, s) => const Icon(Icons.apps, size: 20),
        ),
      );
    }
    return Icon(
      app.running ? Icons.play_circle_outline : Icons.apps,
      size: 20,
    );
  }

  /// The process name the current search query would add.
  /// ponytail: on Windows a bare name gets ".exe" appended — that's what the
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
    });
    _saveConfig();
  }

  void _setVpnMode(VpnMode mode) {
    setState(() {
      _vpnMode = mode;
    });
    _saveConfig();
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

        return Column(
          children: [
            // Everything stays editable while connected — changes are saved
            // immediately and picked up on the next connect. The banner just
            // says so instead of locking the whole screen.
            if (isConnected)
              InfoBanner(
                severity: BannerSeverity.info,
                message: AppLocalizations.of(
                  context,
                )!.splitTunnelWarningConnected,
                margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              ),
            Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<VpnMode>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: VpnMode.general,
                              icon: const Icon(Icons.shield, size: 18),
                              label: Text(
                                AppLocalizations.of(
                                  context,
                                )!.splitTunnelModeGeneralTitle,
                              ),
                            ),
                            ButtonSegment(
                              value: VpnMode.selective,
                              icon: const Icon(Icons.filter_alt, size: 18),
                              label: Text(
                                AppLocalizations.of(
                                  context,
                                )!.splitTunnelModeSelectiveTitle,
                              ),
                            ),
                          ],
                          selected: {_vpnMode},
                          onSelectionChanged: (modes) =>
                              _setVpnMode(modes.first),
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        _vpnMode == VpnMode.general
                            ? AppLocalizations.of(
                                context,
                              )!.splitTunnelModeGeneralSubtitle
                            : AppLocalizations.of(
                                context,
                              )!.splitTunnelModeSelectiveSubtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                      SizedBox(height: 10),
                      _buildRoutingListsSection(),
                    ],
                  ),
                ),
              ),
            ),
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(
                  icon: Icon(Icons.language, size: 20),
                  text: AppLocalizations.of(
                    context,
                  )!.splitTunnelDomainsTab(_totalDomainCount),
                ),
                Tab(
                  icon: Icon(Icons.apps, size: 20),
                  text: AppLocalizations.of(
                    context,
                  )!.splitTunnelAppsTab(_apps.length),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [_buildDomainsTab(), _buildAppsTab()],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  SizedBox(width: 6),
                  Text(
                    AppLocalizations.of(context)!.splitTunnelAutoSave,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Ready-made routing lists ──────────────────────────────────────────

  Future<void> _reloadRoutingLists() async {
    final lists = await context.read<ConfigService>().loadRoutingLists();
    if (mounted) setState(() => _routingLists = lists);
  }

  /// One tile per list (built-in preset + user lists) with enable switch,
  /// refresh, per-mode applicability and delete. Entries are merged into
  /// the exclusions at connect time; they never clutter the domain list.
  Widget _buildRoutingListsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Ready-made routing lists',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _addRoutingList,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add list'),
            ),
          ],
        ),
        // Cap the section height so many lists scroll here instead of
        // squeezing the domains/apps tabs out of the screen.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 236),
          child: ListView(
            shrinkWrap: true,
            children: _routingLists.map(_buildRoutingListTile).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildRoutingListTile(RoutingList list) {
    final theme = Theme.of(context);
    final busy = _busyLists.contains(list.id);
    final activeInMode = list.enabled && list.matchesMode(_vpnMode);
    final hasError = list.lastError.isNotEmpty;

    final parts = <String>[];
    if (list.entryCount > 0) {
      parts.add('${list.entryCount} entries');
      if (list.lastUpdated != null) {
        parts.add(
          'updated ${MaterialLocalizations.of(context).formatShortDate(list.lastUpdated!)}',
        );
      }
    } else {
      parts.add(
        list.isBuiltin
            ? 'Downloads on first enable · itdoginfo/allow-domains'
            : 'Not downloaded yet',
      );
    }
    if (hasError) parts.add('update failed');
    if (list.enabled && !list.matchesMode(_vpnMode)) {
      parts.add('inactive in ${_vpnMode.name} mode (set to ${list.appliesTo})');
    }

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 16, right: 8),
        leading: busy
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                hasError
                    ? Icons.sync_problem
                    : list.type == 'file'
                    ? Icons.description_outlined
                    : Icons.alt_route,
                color: hasError
                    ? theme.colorScheme.error
                    : activeInMode
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
        title: Text(list.name),
        subtitle: Text(
          parts.join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: hasError ? TextStyle(color: theme.colorScheme.error) : null,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (list.enabled)
              IconButton(
                tooltip: 'Update now',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: busy ? null : () => _refreshRoutingList(list),
              ),
            PopupMenuButton<String>(
              tooltip: 'List options',
              itemBuilder: (context) => [
                const PopupMenuItem(
                  enabled: false,
                  child: Text('Apply this list in:'),
                ),
                CheckedPopupMenuItem(
                  value: 'selective',
                  checked: list.appliesTo == 'selective',
                  child: const Text('Selective mode (route via VPN)'),
                ),
                CheckedPopupMenuItem(
                  value: 'general',
                  checked: list.appliesTo == 'general',
                  child: const Text('General mode (bypass VPN)'),
                ),
                CheckedPopupMenuItem(
                  value: 'both',
                  checked: list.appliesTo == 'both',
                  child: const Text('Both modes'),
                ),
                if (!list.isBuiltin) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete list'),
                  ),
                ],
              ],
              onSelected: (v) async {
                if (_busyLists.contains(list.id)) {
                  showAppSnackBar(
                      context, 'Wait for the running update to finish');
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
            Switch(
              value: list.enabled,
              onChanged: busy ? null : (v) => _toggleRoutingList(list, v),
            ),
          ],
        ),
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _vpnMode == VpnMode.general
                    ? AppLocalizations.of(context)!.splitTunnelDomainsExclude
                    : AppLocalizations.of(context)!.splitTunnelDomainsInclude,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              SizedBox(height: 4),
              Text(
                AppLocalizations.of(context)!.splitTunnelDomainsHint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),

              // Add domain input
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _domainController,
                      decoration: InputDecoration(
                        hintText: AppLocalizations.of(
                          context,
                        )!.splitTunnelDomainsInputHint,
                        prefixIcon: const Icon(Icons.add_link, size: 20),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onSubmitted: (_) => _addEntry(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _addEntry,
                    icon: const Icon(Icons.add),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    onPressed: _importDomainList,
                    tooltip: 'Paste a list',
                    icon: const Icon(Icons.content_paste),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Domain groups and standalone list
              Expanded(
                child:
                    (_groups.isEmpty &&
                        _standaloneDomains.isEmpty &&
                        _suggestions.isEmpty)
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.dns_outlined,
                              size: 48,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            SizedBox(height: 8),
                            Text(
                              AppLocalizations.of(
                                context,
                              )!.splitTunnelNoDomains,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                  ),
                            ),
                          ],
                        ),
                      )
                    : _buildDomainsList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Sections in order: group cards, an "Other" header (only when both
  /// groups and standalone entries exist), standalone domain tiles, the
  /// suggestion banner. ListView.builder keeps the list lazy — a user list
  /// of hundreds/thousands of domains must not be rebuilt as widgets in full
  /// on every setState.
  Widget _buildDomainsList() {
    final hasHeader = _standaloneDomains.isNotEmpty && _groups.isNotEmpty;
    final standaloneStart = _groups.length + (hasHeader ? 1 : 0);
    final bannerIndex = standaloneStart + _standaloneDomains.length;
    return ListView.builder(
      itemCount: bannerIndex + (_suggestions.isNotEmpty ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < _groups.length) return _buildGroupCard(_groups[index]);
        if (hasHeader && index == _groups.length) {
          return Padding(
            padding: EdgeInsets.only(top: 12, bottom: 4),
            child: Text(
              AppLocalizations.of(context)!.splitTunnelOther,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          );
        }
        if (index < bannerIndex) {
          final domain = _standaloneDomains[index - standaloneStart];
          return Card(
            margin: const EdgeInsets.only(bottom: 4),
            child: ListTile(
              dense: true,
              leading: Icon(_getDomainIcon(domain), size: 20),
              title: Text(domain),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => _removeStandaloneDomain(domain),
              ),
            ),
          );
        }
        return _buildSuggestionBanner();
      },
    );
  }

  Widget _buildGroupCard(DomainGroup group) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: ExpansionTile(
        leading: Icon(Icons.folder_outlined, color: theme.colorScheme.primary),
        title: Text(
          group.name,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          _pluralDomains(group.domains.length),
          style: theme.textTheme.bodySmall,
        ),
        children: [
          // Domains in group
          ...group.domains.map(
            (domain) => ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 72, right: 16),
              leading: Icon(_getDomainIcon(domain), size: 18),
              title: Text(domain, style: const TextStyle(fontSize: 13)),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => _removeDomainFromGroup(group, domain),
              ),
            ),
          ),
          // Actions
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => _addDomainToGroup(group),
                  icon: Icon(Icons.add, size: 18),
                  label: Text(AppLocalizations.of(context)!.commonAdd),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _renameGroup(group),
                  icon: Icon(Icons.edit, size: 18),
                  label: Text(AppLocalizations.of(context)!.commonRename),
                ),
                TextButton.icon(
                  onPressed: () => _confirmDeleteGroup(group),
                  icon: Icon(
                    Icons.delete_outline,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  label: Text(
                    AppLocalizations.of(context)!.commonDelete,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
            ),
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
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteGroup(group);
            },
            child: Text(
              AppLocalizations.of(context)!.commonDelete,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionBanner() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline, color: Colors.blue, size: 20),
              const SizedBox(width: 8),
              Text(
                'Domains discovered in logs',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.blue,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _suggestions.clear()),
                child: const Text('Hide all', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ..._suggestions.map(
            (domain) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(child: Text(domain, style: TextStyle(fontSize: 13))),
                  if (_groups.isNotEmpty)
                    PopupMenuButton<DomainGroup>(
                      tooltip: AppLocalizations.of(
                        context,
                      )!.splitTunnelSuggestionAddToGroup,
                      icon: Icon(Icons.playlist_add, size: 18),
                      itemBuilder: (context) => _groups
                          .map(
                            (g) => PopupMenuItem(
                              value: g,
                              child: Text(
                                AppLocalizations.of(
                                  context,
                                )!.splitTunnelToGroup(g.name),
                              ),
                            ),
                          )
                          .toList(),
                      onSelected: (group) =>
                          _addSuggestionToGroup(domain, group),
                    ),
                  IconButton(
                    icon: Icon(Icons.add_circle_outline, size: 18),
                    tooltip: AppLocalizations.of(
                      context,
                    )!.splitTunnelSuggestionAddStandalone,
                    onPressed: () => _addSuggestionToStandalone(domain),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 18),
                    tooltip: AppLocalizations.of(
                      context,
                    )!.splitTunnelSuggestionHide,
                    onPressed: () => _dismissSuggestion(domain),
                  ),
                ],
              ),
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

  Widget _buildAppsTab() {
    final query = _appSearchQuery.trim().toLowerCase();
    // Space-insensitive match, so "whatsapp" finds "Whats App Desktop" and
    // "apple music" finds "AppleMusic.exe".
    final compactQuery = query.replaceAll(' ', '');
    bool matches(String s) {
      if (query.isEmpty) return true;
      final l = s.toLowerCase();
      return l.contains(query) || l.replaceAll(' ', '').contains(compactQuery);
    }

    // Selected apps the scanner didn't find (added manually, custom install
    // dirs, or picked on another machine) — must stay visible and removable,
    // never silently filtered out.
    final knownNames = _installedApps.map((a) => a.name.toLowerCase()).toSet();
    final manualApps =
        _apps
            .where((a) => !knownNames.contains(a.toLowerCase()))
            .where(matches)
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final filteredApps =
        _installedApps
            .where((app) {
              // Running processes are search-only: the default view shows
              // the clean Installed-Apps list (selected ones always stay).
              if (app.running && query.isEmpty && !_apps.contains(app.name)) {
                return false;
              }
              return matches(app.name) || matches(app.displayName);
            })
            .toList()
          // Selected first, so what's enabled is visible without scrolling.
          ..sort((a, b) {
            final selA = _apps.contains(a.name) ? 0 : 1;
            final selB = _apps.contains(b.name) ? 0 : 1;
            if (selA != selB) return selA - selB;
            return a.displayName.toLowerCase().compareTo(
              b.displayName.toLowerCase(),
            );
          });

    final nothingToShow = manualApps.isEmpty && filteredApps.isEmpty;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _vpnMode == VpnMode.general
                    ? AppLocalizations.of(context)!.splitTunnelAppsExclude
                    : AppLocalizations.of(context)!.splitTunnelAppsInclude,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _appSearchController,
                      decoration: InputDecoration(
                        hintText: Platform.isWindows
                            ? 'Search apps or type a process name (game.exe)'
                            : 'Search apps or type a process name',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
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
                  if (query.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    IconButton.filled(
                      tooltip: 'Add "${_manualAppName()}" as a process name',
                      onPressed: _addManualApp,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: 'Rescan installed apps and running processes',
                    onPressed: _isLoadingApps ? null : _loadInstalledApps,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _isLoadingApps
                    ? const Center(child: CircularProgressIndicator())
                    : nothingToShow
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.apps_outlined,
                              size: 48,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                            SizedBox(height: 8),
                            Text(
                              AppLocalizations.of(context)!.splitTunnelNoApps,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                              ),
                              child: Text(
                                'Tip: type a name to also search running processes, '
                                'or start the app and press the refresh button — '
                                'running processes appear in this list with their exact process name.',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outline,
                                    ),
                              ),
                            ),
                            if (query.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              FilledButton.tonalIcon(
                                onPressed: _addManualApp,
                                icon: const Icon(Icons.add, size: 18),
                                label: Text(
                                  'Add "${_manualAppName()}" manually',
                                ),
                              ),
                            ],
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: manualApps.length + filteredApps.length,
                        itemBuilder: (context, index) {
                          // Manual/unscanned entries first — always checked.
                          if (index < manualApps.length) {
                            final name = manualApps[index];
                            return Card(
                              margin: const EdgeInsets.only(bottom: 4),
                              child: CheckboxListTile(
                                dense: true,
                                value: true,
                                onChanged: (_) => _toggleApp(name),
                                secondary: const Icon(Icons.terminal, size: 20),
                                title: Text(name),
                                subtitle: Text(
                                  'Added by process name',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            );
                          }

                          final app = filteredApps[index - manualApps.length];
                          final isSelected = _apps.contains(app.name);

                          return Card(
                            margin: const EdgeInsets.only(bottom: 4),
                            child: CheckboxListTile(
                              dense: true,
                              value: isSelected,
                              onChanged: (value) => _toggleApp(app.name),
                              secondary: _appIcon(app),
                              title: Text(app.displayName),
                              subtitle: Text(
                                app.running
                                    ? '${app.name} — running now'
                                    : app.name,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (_apps.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                      SizedBox(width: 8),
                      Text(
                        AppLocalizations.of(
                          context,
                        )!.splitTunnelSelectedApps(_apps.length),
                        style: TextStyle(
                          fontSize: 13,
                          color: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
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
        _ListSource.preset => [_preset!.url],
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
            'Found ${entries.length} valid entries${skipped > 0 ? ' ($skipped skipped)' : ''}'
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Add routing list'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _source == _ListSource.preset
                  ? AppLocalizations.of(context)!.splitTunnelPresetHint
                  : 'A plain-text list: one domain, IP or CIDR per line '
                      '(# comments allowed). URL lists refresh automatically '
                      'when older than 24 hours.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<_ListSource>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: _ListSource.preset,
                  icon: const Icon(Icons.category_outlined, size: 18),
                  label: Text(
                      AppLocalizations.of(context)!.splitTunnelSourcePreset),
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
            const SizedBox(height: 12),
            if (_source == _ListSource.preset)
              DropdownButtonFormField<RoutingPreset>(
                initialValue: _preset,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText:
                      AppLocalizations.of(context)!.splitTunnelPresetPick,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
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
              )
            else if (_source == _ListSource.file)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _path,
                      decoration: const InputDecoration(
                        labelText: 'File path',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
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
              )
            else
              TextField(
                controller: _urls,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Raw URL(s), one per line',
                  hintText:
                      'https://raw.githubusercontent.com/user/repo/main/list.lst',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
              ),
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
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              )
            else if (_checkResult != null)
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _checkResult!,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          onPressed: (_busy || !_sourceFilled) ? null : _check,
          child: const Text('Check'),
        ),
        FilledButton(
          onPressed: (_busy || !_sourceFilled) ? null : _add,
          child: const Text('Add'),
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
    return AlertDialog(
      title: Text(AppLocalizations.of(context)!.discoveryTitle(widget.domain)),
      content: SizedBox(
        width: 420,
        child: _isLoading
            ? Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
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
                          prefixIcon: Icon(Icons.folder_outlined, size: 20),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Primary domain (always included, not toggleable)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.language, size: 18),
                        title: Text(widget.domain),
                        trailing: const Icon(
                          Icons.check,
                          size: 18,
                          color: Colors.green,
                        ),
                      ),
                      // Discovered domains with checkboxes
                      ..._discovered.map(
                        (domain) => CheckboxListTile(
                          dense: true,
                          value: _selected[domain] ?? false,
                          onChanged: (v) =>
                              setState(() => _selected[domain] = v ?? false),
                          secondary: const Icon(Icons.link, size: 18),
                          title: Text(
                            domain,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ] else ...[
                      if (_error != null) ...[
                        Icon(
                          Icons.info_outline,
                          size: 32,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        SizedBox(height: 8),
                      ],
                      Text(
                        AppLocalizations.of(context)!.discoveryNoRelated,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      SizedBox(height: 4),
                      Text(
                        AppLocalizations.of(context)!.discoveryAddStandalone,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
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
  String alnum(String v) => v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  final dn = alnum(displayName);
  for (final f in usable) {
    final stem = alnum(
      _winBasename(f.path).replaceAll(RegExp(r'\.exe$', caseSensitive: false), ''),
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
          final logo = RegExp(r'<Logo>([^<]+)</Logo>').firstMatch(xml)?.group(1);
          if (logo != null) {
            iconPath = await _resolveStoreLogo(location, logo.trim()) ?? '';
          }
        }
      } catch (_) {}

      final display = storeAppDisplayName(name);
      for (final exe in exes) {
        apps.add(InstalledApp(
          name: exe,
          displayName: display,
          path: location,
          iconPath: iconPath,
        ));
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

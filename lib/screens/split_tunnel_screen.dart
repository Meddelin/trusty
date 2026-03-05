import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/server_config.dart';
import '../models/domain_group.dart';
import '../models/vpn_status.dart';
import '../services/config_service.dart';
import '../services/vpn_service.dart';
import '../services/domain_discovery_service.dart';
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

  final TextEditingController _domainController = TextEditingController();
  List<InstalledApp> _installedApps = [];
  bool _isLoadingApps = false;
  String _appSearchQuery = '';

  final DomainDiscoveryService _discoveryService = DomainDiscoveryService();

  // Suggestions from log monitoring
  final List<String> _suggestions = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadConfig();
    _loadInstalledApps();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _domainController.dispose();
    _stopLogMonitoring();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final configService = context.read<ConfigService>();
    final config = await configService.loadConfig();

    // Migrate and load domain groups
    final groupsData = await configService.migrateFlatDomainsToGroups();

    setState(() {
      _vpnMode = config.vpnMode;
      _groups = List.from(groupsData.groups);
      _standaloneDomains = List.from(groupsData.standaloneDomains);
      _apps = List.from(config.splitTunnelApps);
      _isLoading = false;
    });

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

  void _onLogLine(String line) {
    // Extract domain-like patterns from log lines
    final domainPattern = RegExp(r'(?:[\w-]+\.)+[a-zA-Z]{2,}');
    final matches = domainPattern.allMatches(line);

    final currentDomains = _getAllCurrentDomains();

    final newSuggestions = <String>[];
    for (final match in matches) {
      final domain = match.group(0)!.toLowerCase();
      if (currentDomains.contains(domain)) continue;
      if (_suggestions.contains(domain)) continue;
      if (domain.endsWith('.local') || domain.endsWith('.internal')) continue;
      if (domain == 'trusttunnel.com') continue;
      if (_suggestions.length + newSuggestions.length < 20) {
        newSuggestions.add(domain);
      }
    }
    if (newSuggestions.isNotEmpty) {
      setState(() {
        _suggestions.addAll(newSuggestions);
      });
    }
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
      final apps = await _getInstalledApps();
      setState(() {
        _installedApps = apps;
        _isLoadingApps = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingApps = false;
      });
    }
  }

  Future<List<InstalledApp>> _getInstalledApps() async {
    if (Platform.isMacOS) {
      return _getInstalledAppsMacOS();
    }
    return _getInstalledAppsWindows();
  }

  Future<List<InstalledApp>> _getInstalledAppsWindows() async {
    final apps = <InstalledApp>[];

    final programFiles = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 = Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final appData = Platform.environment['APPDATA'] ?? '';

    final searchDirs = [
      programFiles,
      programFilesX86,
      if (localAppData.isNotEmpty) localAppData,
      if (appData.isNotEmpty) appData,
    ];

    for (final dirPath in searchDirs) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) continue;

      try {
        await for (final entity in dir.list(recursive: false)) {
          if (entity is Directory) {
            try {
              await for (final file in entity.list(recursive: false)) {
                if (file is File && file.path.toLowerCase().endsWith('.exe')) {
                  final name = file.path.split(Platform.pathSeparator).last;
                  if (!_isSystemExecutable(name)) {
                    apps.add(InstalledApp(
                      name: name,
                      displayName: _getDisplayName(name, entity.path),
                      path: file.path,
                    ));
                  }
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }

    final commonApps = [
      InstalledApp(name: 'chrome.exe', displayName: 'Google Chrome', path: ''),
      InstalledApp(name: 'firefox.exe', displayName: 'Mozilla Firefox', path: ''),
      InstalledApp(name: 'msedge.exe', displayName: 'Microsoft Edge', path: ''),
      InstalledApp(name: 'opera.exe', displayName: 'Opera', path: ''),
      InstalledApp(name: 'brave.exe', displayName: 'Brave Browser', path: ''),
      InstalledApp(name: 'telegram.exe', displayName: 'Telegram', path: ''),
      InstalledApp(name: 'discord.exe', displayName: 'Discord', path: ''),
      InstalledApp(name: 'slack.exe', displayName: 'Slack', path: ''),
      InstalledApp(name: 'spotify.exe', displayName: 'Spotify', path: ''),
      InstalledApp(name: 'steam.exe', displayName: 'Steam', path: ''),
      InstalledApp(name: 'epicgameslauncher.exe', displayName: 'Epic Games', path: ''),
      InstalledApp(name: 'code.exe', displayName: 'VS Code', path: ''),
      InstalledApp(name: 'idea64.exe', displayName: 'IntelliJ IDEA', path: ''),
      InstalledApp(name: 'torrent.exe', displayName: 'Torrent Client', path: ''),
      InstalledApp(name: 'qbittorrent.exe', displayName: 'qBittorrent', path: ''),
    ];

    for (final app in commonApps) {
      if (!apps.any((a) => a.name.toLowerCase() == app.name.toLowerCase())) {
        apps.add(app);
      }
    }

    return _deduplicateAndSort(apps);
  }

  Future<List<InstalledApp>> _getInstalledAppsMacOS() async {
    final apps = <InstalledApp>[];

    final homeDir = Platform.environment['HOME'] ?? '/Users/${Platform.environment['USER']}';
    final searchDirs = [
      '/Applications',
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
              apps.add(InstalledApp(
                name: processName,
                displayName: appName,
                path: entity.path,
              ));
            }
          }
        }
      } catch (_) {}
    }

    final commonApps = [
      InstalledApp(name: 'Google Chrome', displayName: 'Google Chrome', path: ''),
      InstalledApp(name: 'firefox', displayName: 'Firefox', path: ''),
      InstalledApp(name: 'Safari', displayName: 'Safari', path: ''),
      InstalledApp(name: 'Discord', displayName: 'Discord', path: ''),
      InstalledApp(name: 'Telegram', displayName: 'Telegram', path: ''),
      InstalledApp(name: 'Slack', displayName: 'Slack', path: ''),
      InstalledApp(name: 'Spotify', displayName: 'Spotify', path: ''),
      InstalledApp(name: 'steam_osx', displayName: 'Steam', path: ''),
      InstalledApp(name: 'Electron', displayName: 'VS Code', path: ''),
      InstalledApp(name: 'idea', displayName: 'IntelliJ IDEA', path: ''),
      InstalledApp(name: 'qbittorrent', displayName: 'qBittorrent', path: ''),
    ];

    for (final app in commonApps) {
      if (!apps.any((a) => a.name.toLowerCase() == app.name.toLowerCase())) {
        apps.add(app);
      }
    }

    return _deduplicateAndSort(apps);
  }

  bool _isSystemAppMacOS(String appName) {
    final systemApps = [
      'Utilities', 'Automator', 'Migration Assistant',
      'System Preferences', 'System Settings',
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
      'uninstall', 'uninst', 'setup', 'install', 'update',
      'updater', 'helper', 'crash', 'reporter', 'service',
    ];
    final lowerName = name.toLowerCase();
    return systemExes.any((s) => lowerName.contains(s));
  }

  String _getDisplayName(String exeName, String dirPath) {
    final dirName = dirPath.split(Platform.pathSeparator).last;
    if (dirName.isNotEmpty && !dirName.contains('.')) {
      return dirName;
    }
    return exeName.replaceAll('.exe', '').replaceAll('.EXE', '');
  }

  Future<void> _saveConfig() async {
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.splitTunnelSaveError(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Add domain with discovery flow
  Future<void> _addDomainWithDiscovery() async {
    final domain = _domainController.text.trim();
    if (domain.isEmpty) return;

    // Check if domain already exists
    if (_getAllCurrentDomains().contains(domain.toLowerCase())) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.splitTunnelDomainAlreadyAdded)),
        );
      }
      return;
    }

    // Check if it looks like a domain (not IP or CIDR)
    final isDomain = !RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(domain) &&
        !domain.contains('/');

    if (!isDomain) {
      // IPs and CIDRs go straight to standalone
      setState(() {
        _standaloneDomains.add(domain);
      });
      _domainController.clear();
      _saveConfig();
      return;
    }

    // Show discovery dialog
    if (!mounted) return;
    _domainController.clear();

    final result = await showDialog<_DiscoveryDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DiscoveryDialog(
        domain: domain,
        discoveryService: _discoveryService,
      ),
    );

    if (result == null) return; // Cancelled

    setState(() {
      if (result.createGroup && result.selectedDomains.isNotEmpty) {
        _groups.add(DomainGroup(
          id: '${domain.replaceAll('.', '-')}-${DateTime.now().millisecondsSinceEpoch}',
          name: result.groupName,
          primaryDomain: domain,
          domains: [domain, ...result.selectedDomains],
        ));
      } else {
        _standaloneDomains.add(domain);
      }
    });
    _saveConfig();
  }

  void _addDomainToGroup(DomainGroup group) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.splitTunnelAddToGroup(group.name)),
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

    if (result != null && result.isNotEmpty) {
      final idx = _groups.indexWhere((g) => g.id == group.id);
      if (idx != -1 && !_groups[idx].domains.contains(result)) {
        setState(() {
          final updated = List<String>.from(_groups[idx].domains)..add(result);
          _groups[idx] = _groups[idx].copyWith(domains: updated);
        });
        _saveConfig();
      }
    }
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
          decoration: InputDecoration(hintText: AppLocalizations.of(context)!.splitTunnelGroupName),
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
            Expanded(
              flex: 0,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    if (isConnected)
                      Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.orange),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                AppLocalizations.of(context)!.splitTunnelWarningConnected,
                                style: TextStyle(color: Colors.orange, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocalizations.of(context)!.splitTunnelVpnMode,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          SizedBox(height: 8),
                          _buildModeCard(
                            title: AppLocalizations.of(context)!.splitTunnelModeGeneralTitle,
                            subtitle: AppLocalizations.of(context)!.splitTunnelModeGeneralSubtitle,
                            icon: Icons.shield,
                            isSelected: _vpnMode == VpnMode.general,
                            enabled: !isConnected,
                            onTap: () {
                              if (!isConnected) _setVpnMode(VpnMode.general);
                            },
                          ),
                          SizedBox(height: 8),
                          _buildModeCard(
                            title: AppLocalizations.of(context)!.splitTunnelModeSelectiveTitle,
                            subtitle: AppLocalizations.of(context)!.splitTunnelModeSelectiveSubtitle,
                            icon: Icons.filter_alt,
                            isSelected: _vpnMode == VpnMode.selective,
                            enabled: !isConnected,
                            onTap: () {
                              if (!isConnected) _setVpnMode(VpnMode.selective);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(
                  icon: Icon(Icons.language, size: 20),
                  text: AppLocalizations.of(context)!.splitTunnelDomainsTab(_totalDomainCount),
                ),
                Tab(
                  icon: Icon(Icons.apps, size: 20),
                  text: AppLocalizations.of(context)!.splitTunnelAppsTab(_apps.length),
                ),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildDomainsTab(isConnected),
                  _buildAppsTab(isConnected),
                ],
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

  Widget _buildModeCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final color = isSelected ? theme.colorScheme.primary : theme.colorScheme.outline;

    return Card(
      elevation: isSelected ? 2 : 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline.withValues(alpha: 0.3),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: enabled ? null : theme.disabledColor,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: enabled ? theme.textTheme.bodySmall?.color : theme.disabledColor,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: theme.colorScheme.primary, size: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDomainsTab(bool isConnected) {
    return Padding(
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
                  enabled: !isConnected,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context)!.splitTunnelDomainsInputHint,
                    prefixIcon: const Icon(Icons.add_link, size: 20),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onSubmitted: (_) => _addDomainWithDiscovery(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: isConnected ? null : _addDomainWithDiscovery,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Domain groups and standalone list
          Expanded(
            child: (_groups.isEmpty && _standaloneDomains.isEmpty && _suggestions.isEmpty)
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
                          AppLocalizations.of(context)!.splitTunnelNoDomains,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    children: [
                      // Domain groups
                      ..._groups.map((group) => _buildGroupCard(group, isConnected)),

                      // Standalone domains
                      if (_standaloneDomains.isNotEmpty) ...[
                        if (_groups.isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(top: 12, bottom: 4),
                            child: Text(
                              AppLocalizations.of(context)!.splitTunnelOther,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                            ),
                          ),
                        ..._standaloneDomains.map((domain) => Card(
                              margin: const EdgeInsets.only(bottom: 4),
                              child: ListTile(
                                dense: true,
                                leading: Icon(_getDomainIcon(domain), size: 20),
                                title: Text(domain),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 20),
                                  onPressed: isConnected ? null : () => _removeStandaloneDomain(domain),
                                ),
                              ),
                            )),
                      ],

                      // Suggestions from log monitoring
                      if (_suggestions.isNotEmpty)
                        _buildSuggestionBanner(isConnected),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(DomainGroup group, bool isConnected) {
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
          style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          _pluralDomains(group.domains.length),
          style: theme.textTheme.bodySmall,
        ),
        children: [
          // Domains in group
          ...group.domains.map((domain) => ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 72, right: 16),
                leading: Icon(_getDomainIcon(domain), size: 18),
                title: Text(domain, style: const TextStyle(fontSize: 13)),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: isConnected ? null : () => _removeDomainFromGroup(group, domain),
                ),
              )),
          // Actions
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: isConnected ? null : () => _addDomainToGroup(group),
                  icon: Icon(Icons.add, size: 18),
                  label: Text(AppLocalizations.of(context)!.commonAdd),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: isConnected ? null : () => _renameGroup(group),
                  icon: Icon(Icons.edit, size: 18),
                  label: Text(AppLocalizations.of(context)!.commonSave),
                ),
                TextButton.icon(
                  onPressed: isConnected ? null : () => _confirmDeleteGroup(group),
                  icon: Icon(Icons.delete_outline, size: 18, color: theme.colorScheme.error),
                  label: Text(AppLocalizations.of(context)!.commonDelete, style: TextStyle(color: theme.colorScheme.error)),
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
        content: Text(AppLocalizations.of(context)!.splitTunnelDeleteGroupMessage(group.name)),
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
            child: Text(AppLocalizations.of(context)!.commonDelete, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionBanner(bool isConnected) {
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
          ..._suggestions.map((domain) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(domain, style: TextStyle(fontSize: 13)),
                    ),
                    if (!isConnected) ...[
                      if (_groups.isNotEmpty)
                        PopupMenuButton<DomainGroup>(
                          tooltip: AppLocalizations.of(context)!.splitTunnelSuggestionAddToGroup,
                          icon: Icon(Icons.playlist_add, size: 18),
                          itemBuilder: (context) => _groups
                              .map((g) => PopupMenuItem(
                                    value: g,
                                    child: Text(AppLocalizations.of(context)!.splitTunnelToGroup(g.name)),
                                  ))
                              .toList(),
                          onSelected: (group) => _addSuggestionToGroup(domain, group),
                        ),
                      IconButton(
                        icon: Icon(Icons.add_circle_outline, size: 18),
                        tooltip: AppLocalizations.of(context)!.splitTunnelSuggestionAddStandalone,
                        onPressed: () => _addSuggestionToStandalone(domain),
                      ),
                    ],
                    IconButton(
                      icon: Icon(Icons.close, size: 18),
                      tooltip: AppLocalizations.of(context)!.splitTunnelSuggestionHide,
                      onPressed: () => _dismissSuggestion(domain),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  String _pluralDomains(int count) {
    return AppLocalizations.of(context)!.splitTunnelDomainCount(count);
  }

  IconData _getDomainIcon(String domain) {
    if (domain.contains('/')) {
      return Icons.hub; // CIDR
    } else if (RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(domain)) {
      return Icons.router; // IP
    } else {
      return Icons.language; // Domain
    }
  }

  Widget _buildAppsTab(bool isConnected) {
    final filteredApps = _appSearchQuery.isEmpty
        ? _installedApps
        : _installedApps.where((app) {
            final query = _appSearchQuery.toLowerCase();
            return app.name.toLowerCase().contains(query) ||
                app.displayName.toLowerCase().contains(query);
          }).toList();

    return Padding(
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
          TextField(
            enabled: !isConnected,
            decoration: InputDecoration(
              hintText: AppLocalizations.of(context)!.splitTunnelSearchApps,
              prefixIcon: const Icon(Icons.search, size: 20),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: (value) {
              setState(() {
                _appSearchQuery = value;
              });
            },
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _isLoadingApps
                ? const Center(child: CircularProgressIndicator())
                : filteredApps.isEmpty
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
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: filteredApps.length,
                        itemBuilder: (context, index) {
                          final app = filteredApps[index];
                          final isSelected = _apps.contains(app.name);

                          return Card(
                            margin: const EdgeInsets.only(bottom: 4),
                            child: CheckboxListTile(
                              dense: true,
                              value: isSelected,
                              onChanged: isConnected
                                  ? null
                                  : (value) => _toggleApp(app.name),
                              secondary: const Icon(Icons.apps, size: 20),
                              title: Text(app.displayName),
                              subtitle: Text(
                                app.name,
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
                    AppLocalizations.of(context)!.splitTunnelSelectedApps(_apps.length),
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
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
    final result = await widget.discoveryService.discoverRelatedDomains(widget.domain);
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
                          labelText: AppLocalizations.of(context)!.discoveryGroupName,
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
                        trailing: const Icon(Icons.check, size: 18, color: Colors.green),
                      ),
                      // Discovered domains with checkboxes
                      ..._discovered.map((domain) => CheckboxListTile(
                            dense: true,
                            value: _selected[domain] ?? false,
                            onChanged: (v) => setState(() => _selected[domain] = v ?? false),
                            secondary: const Icon(Icons.link, size: 18),
                            title: Text(domain, style: const TextStyle(fontSize: 13)),
                          )),
                    ] else ...[
                      if (_error != null) ...[
                        Icon(Icons.info_outline, size: 32, color: Theme.of(context).colorScheme.outline),
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
                  child: Text(AppLocalizations.of(context)!.discoveryWithoutGroup),
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
                child: Text(_discovered.isNotEmpty ? AppLocalizations.of(context)!.discoveryAddGroup : AppLocalizations.of(context)!.commonAdd),
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

  InstalledApp({
    required this.name,
    required this.displayName,
    required this.path,
  });
}

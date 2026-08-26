import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import '../models/routing_list.dart';
import '../models/server_config.dart';
import '../utils/exclusion_parser.dart';
import '../utils/localization_helper.dart';
import '../utils/routing_source_parser.dart';
import '../models/domain_group.dart';

/// Service for managing application configuration
class ConfigService extends ChangeNotifier {
  /// [fetchUrl] is a test seam for everything routing lists download
  /// (sources and geosite `include:` sub-fetches); defaults to a plain
  /// HTTP GET.
  ConfigService({Future<String> Function(String url)? fetchUrl})
      : _fetchUrl = fetchUrl ?? _httpGet;

  final Future<String> Function(String url) _fetchUrl;

  static const String _configKey = 'server_config';
  static const String _serversKey = 'server_list';
  static const String _activeServerKey = 'active_server_id';
  static const String _domainGroupsKey = 'domain_groups';
  static const String _passwordKey = 'vpn_password';
  static const String _configFileName = 'trusttunnel_client.toml';

  // App-global settings (identical for every server). Historically these
  // lived inside each server entry, silently diverging between entries;
  // now they are single keys, seeded from the active config on first run.
  static const String _appDnsKey = 'app_dns';
  static const String _appLogLevelKey = 'app_log_level';

  /// Secure storage for the VPN password (Windows DPAPI / macOS Keychain)
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Secure-storage key for a server's password. The legacy single-server
  /// key is kept as a read fallback for configs saved before server lists.
  String _pwKey(String id) => id.isEmpty ? _passwordKey : '${_passwordKey}_$id';

  /// Secure-storage key for a server's client random prefix. The prefix is a
  /// shared access token (it gates connections on filtering-enabled servers),
  /// so it lives in the keystore like the password, never in SharedPreferences.
  String _prefixKey(String id) => 'client_random_prefix_$id';

  Future<String> _readPrefix(String id) async {
    try {
      return await _secureStorage.read(key: _prefixKey(id)) ?? '';
    } catch (e) {
      debugPrint('Secure storage read failed: $e');
      return '';
    }
  }

  static String newServerId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// One-time migration: wrap the single stored config into a server list.
  /// Afterwards `server_list` always has at least one entry and
  /// `server_config` (the active config) carries the entry's id.
  Future<void> _ensureServerList(SharedPreferences prefs) async {
    if (prefs.containsKey(_serversKey)) {
      await _migratePlaintextPrefixes(prefs);
      return;
    }

    Map<String, dynamic> json;
    try {
      final existing = prefs.getString(_configKey);
      json = existing != null
          ? jsonDecode(existing) as Map<String, dynamic>
          : ServerConfig.defaultConfig().toJson();
    } catch (e) {
      debugPrint('Error reading config during migration: $e');
      json = ServerConfig.defaultConfig().toJson();
    }

    var id = json['id'] as String? ?? '';
    if (id.isEmpty) {
      id = newServerId();
      json['id'] = id;
    }

    // A pre-0.3.3 config may still carry the password as plaintext inside
    // the JSON — it MUST reach the keystore before we strip it, otherwise
    // it is lost forever (loadConfig's own migration runs after this).
    final legacyPlaintext = json['password'] as String? ?? '';
    json.remove('password');

    // Migrate the password to the per-server key: plaintext-in-JSON first,
    // else the legacy single-server keystore entry (kept for downgrade
    // safety).
    try {
      final password = legacyPlaintext.isNotEmpty
          ? legacyPlaintext
          : await _secureStorage.read(key: _passwordKey);
      if (password != null && password.isNotEmpty) {
        await _secureStorage.write(key: _pwKey(id), value: password);
      }
    } catch (e) {
      debugPrint('Secure storage migration failed: $e');
    }

    await prefs.setString(_configKey, jsonEncode(json));
    await prefs.setString(_serversKey, jsonEncode([json]));
    await prefs.setString(_activeServerKey, id);
    debugPrint('Migrated single config to server list (id: $id)');

    // The stored JSON may still carry a plaintext prefix — move it to the
    // keystore right away.
    await _migratePlaintextPrefixes(prefs);
  }

  bool _prefixMigrationDone = false;

  /// One-time migration: the client random prefix used to be stored as
  /// plaintext inside the server-list / active-config JSON. Move each value
  /// to its per-server keystore key and strip the field from the JSON.
  Future<void> _migratePlaintextPrefixes(SharedPreferences prefs) async {
    if (_prefixMigrationDone) return;
    _prefixMigrationDone = true;
    try {
      final servers = _decodeServers(prefs);
      var changed = false;
      for (final s in servers) {
        if (!s.containsKey('clientRandomPrefix')) continue;
        final prefix = s.remove('clientRandomPrefix') as String? ?? '';
        final id = s['id'] as String? ?? '';
        if (prefix.isNotEmpty && id.isNotEmpty) {
          await _secureStorage.write(key: _prefixKey(id), value: prefix);
        }
        changed = true;
      }
      if (changed) {
        await prefs.setString(_serversKey, jsonEncode(servers));
      }

      // The active-config copy carries the same plaintext value.
      final raw = prefs.getString(_configKey);
      if (raw != null) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        if (json.containsKey('clientRandomPrefix')) {
          final prefix = json.remove('clientRandomPrefix') as String? ?? '';
          final id = json['id'] as String? ?? '';
          if (prefix.isNotEmpty && id.isNotEmpty) {
            await _secureStorage.write(key: _prefixKey(id), value: prefix);
          }
          await prefs.setString(_configKey, jsonEncode(json));
          changed = true;
        }
      }
      if (changed) {
        debugPrint('Migrated client random prefixes to secure storage');
      }
    } catch (e) {
      // Retry on the next call rather than silently losing prefixes.
      _prefixMigrationDone = false;
      debugPrint('Client random prefix migration failed: $e');
    }
  }

  List<Map<String, dynamic>> _decodeServers(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_serversKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => e as Map<String, dynamic>)
          .toList();
    } catch (e) {
      debugPrint('Error decoding server list: $e');
      return [];
    }
  }

  // Synchronously readable snapshot for hot UI paths (the Home switcher
  // rebuilt a FutureBuilder with a NEW future on every rebuild, which made
  // its open animation stutter). Filled on first loadServers() and kept
  // fresh by every mutation.
  List<ServerConfig>? _serversCache;
  String _activeIdCache = '';

  List<ServerConfig> get serversCache => _serversCache ?? const [];
  String get activeServerIdCache => _activeIdCache;

  void _refreshServersCache(SharedPreferences prefs) {
    final wasEmpty = _serversCache == null;
    _serversCache = _decodeServers(prefs).map(ServerConfig.fromJson).toList();
    _activeIdCache = prefs.getString(_activeServerKey) ?? '';
    // First fill happens lazily from build paths — notify outside build.
    if (wasEmpty) scheduleMicrotask(notifyListeners);
  }

  /// All saved servers (passwords are not loaded — they stay in the keystore).
  Future<List<ServerConfig>> loadServers() async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureServerList(prefs);
    _refreshServersCache(prefs);
    return List.of(serversCache);
  }

  /// Id of the currently active server.
  Future<String> getActiveServerId() async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureServerList(prefs);
    return prefs.getString(_activeServerKey) ?? '';
  }

  /// Make [id] the active server. Its connection fields (host, credentials,
  /// protocol tweaks) replace the current ones, while app-wide settings
  /// (DNS, log level, VPN mode, split tunneling) are preserved, so switching
  /// servers never wipes the user's routing setup. Unknown id → no-op.
  Future<void> switchServer(String id) async {
    ServerConfig? entry;
    for (final s in await loadServers()) {
      if (s.id == id) entry = s;
    }
    if (entry == null) return;

    final current = await loadConfig();
    String password = '';
    try {
      // Same fallback chain as loadConfig, so a server whose per-id key was
      // never written (failed migration) can still recover the legacy value.
      password = await _secureStorage.read(key: _pwKey(id)) ??
          await _secureStorage.read(key: _passwordKey) ??
          '';
    } catch (e) {
      debugPrint('Secure storage read failed: $e');
    }

    await saveConfig(current.copyWith(
      id: entry.id,
      name: entry.name,
      hostname: entry.hostname,
      address: entry.address,
      port: entry.port,
      hasIpv6: entry.hasIpv6,
      username: entry.username,
      password: password,
      skipVerification: entry.skipVerification,
      upstreamProtocol: entry.upstreamProtocol,
      antiDpi: entry.antiDpi,
      customSni: entry.customSni,
      clientRandomPrefix: await _readPrefix(id),
      postQuantumGroupEnabled: entry.postQuantumGroupEnabled,
    ));
  }

  /// Full config of one saved server, password included, WITHOUT switching
  /// to it. Null when the id is unknown.
  Future<ServerConfig?> loadServerEntry(String id) async {
    ServerConfig? entry;
    for (final s in await loadServers()) {
      if (s.id == id) entry = s;
    }
    if (entry == null) return null;
    String password = '';
    try {
      password = await _secureStorage.read(key: _pwKey(id)) ??
          await _secureStorage.read(key: _passwordKey) ??
          '';
    } catch (e) {
      debugPrint('Secure storage read failed: $e');
    }
    return entry.copyWith(
      password: password,
      clientRandomPrefix: await _readPrefix(id),
    );
  }

  /// Upsert one server's connection fields (and password) WITHOUT changing
  /// which server is active — the Servers screen edits any entry in place.
  /// Editing the ACTIVE server routes through saveConfig so the active
  /// config, globals and listeners stay in sync.
  Future<void> saveServerEntry(ServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureServerList(prefs);
    final cfg =
        config.id.isEmpty ? config.copyWith(id: newServerId()) : config;

    if (prefs.getString(_activeServerKey) == cfg.id) {
      final current = await loadConfig();
      await saveConfig(current.copyWith(
        id: cfg.id,
        name: cfg.name,
        hostname: cfg.hostname,
        address: cfg.address,
        port: cfg.port,
        hasIpv6: cfg.hasIpv6,
        username: cfg.username,
        password: cfg.password,
        skipVerification: cfg.skipVerification,
        upstreamProtocol: cfg.upstreamProtocol,
        antiDpi: cfg.antiDpi,
        customSni: cfg.customSni,
        clientRandomPrefix: cfg.clientRandomPrefix,
        postQuantumGroupEnabled: cfg.postQuantumGroupEnabled,
      ));
      return;
    }

    // Non-active entry: same empty-password guard as saveConfig. The prefix
    // is written as-is — empty is a real value (no connection filtering).
    try {
      if (cfg.password.isNotEmpty) {
        await _secureStorage.write(key: _pwKey(cfg.id), value: cfg.password);
      } else if (await _secureStorage.read(key: _pwKey(cfg.id)) == null) {
        await _secureStorage.write(key: _pwKey(cfg.id), value: '');
      }
      await _secureStorage.write(
          key: _prefixKey(cfg.id), value: cfg.clientRandomPrefix);
    } catch (e) {
      debugPrint('Secure storage write failed: $e');
    }
    final json = cfg.toJson()
      ..remove('password')
      ..remove('clientRandomPrefix');
    final servers = _decodeServers(prefs);
    final idx = servers.indexWhere((s) => s['id'] == cfg.id);
    if (idx >= 0) {
      servers[idx] = json;
    } else {
      servers.add(json);
    }
    await prefs.setString(_serversKey, jsonEncode(servers));
    _refreshServersCache(prefs);
    notifyListeners();
  }

  /// Add a fully-specified server (from the Add-server dialog) and switch to
  /// it. Unlike the old placeholder flow, nothing is committed until the user
  /// confirms real values.
  Future<ServerConfig> addServerConfig(ServerConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureServerList(prefs);
    final entry = config.copyWith(id: newServerId());
    final servers = _decodeServers(prefs);
    servers.add(entry.toJson()
      ..remove('password')
      ..remove('clientRandomPrefix'));
    await prefs.setString(_serversKey, jsonEncode(servers));
    try {
      await _secureStorage.write(key: _pwKey(entry.id), value: entry.password);
      await _secureStorage.write(
          key: _prefixKey(entry.id), value: entry.clientRandomPrefix);
    } catch (e) {
      debugPrint('Secure storage write failed: $e');
    }
    await switchServer(entry.id);
    return entry;
  }

  /// Read-modify-write helpers for the app-global settings. They go through
  /// saveConfig so the active config, the server list and listeners all stay
  /// in sync.
  Future<void> setGlobalDns(String dns) async {
    final current = await loadConfig();
    await saveConfig(current.copyWith(dns: dns));
  }

  Future<void> setGlobalLogLevel(String level) async {
    final current = await loadConfig();
    await saveConfig(current.copyWith(logLevel: level));
  }

  /// Delete a server entry and its stored password. The last remaining
  /// server cannot be deleted. Deleting the active server switches to the
  /// first remaining one.
  Future<void> deleteServer(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureServerList(prefs);
    final servers = _decodeServers(prefs);
    if (servers.length <= 1) return;
    servers.removeWhere((s) => s['id'] == id);
    if (servers.isEmpty) return; // unknown id shrank nothing; guard anyway
    await prefs.setString(_serversKey, jsonEncode(servers));
    try {
      await _secureStorage.delete(key: _pwKey(id));
      await _secureStorage.delete(key: _prefixKey(id));
    } catch (e) {
      debugPrint('Secure storage delete failed: $e');
    }
    if (prefs.getString(_activeServerKey) == id) {
      await switchServer(servers.first['id'] as String? ?? '');
    } else {
      _refreshServersCache(prefs);
      notifyListeners();
    }
  }

  /// Load the active server configuration from local storage
  Future<ServerConfig> loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _ensureServerList(prefs);
      final jsonString = prefs.getString(_configKey);

      if (jsonString != null) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        final id = json['id'] as String? ?? '';

        // App-global settings: seed the single keys from the active config
        // once, then always read from them — server entries may carry stale
        // per-entry values from older versions.
        if (!prefs.containsKey(_appDnsKey)) {
          await prefs.setString(
              _appDnsKey, json['dns'] as String? ?? '8.8.8.8');
        }
        if (!prefs.containsKey(_appLogLevelKey)) {
          await prefs.setString(
              _appLogLevelKey, json['logLevel'] as String? ?? 'info');
        }
        json['dns'] = prefs.getString(_appDnsKey);
        json['logLevel'] = prefs.getString(_appLogLevelKey);

        // Read the password from secure storage. A keystore hiccup must not
        // nuke the rest of the config (the outer catch would return defaults),
        // so degrade to an empty password instead. Fall back to the legacy
        // single-server key only when the per-server key was never written.
        String password = '';
        try {
          password = await _secureStorage.read(key: _pwKey(id)) ??
              await _secureStorage.read(key: _passwordKey) ??
              '';
        } catch (e) {
          debugPrint('Secure storage read failed: $e');
        }

        // Migrate legacy plaintext password stored inside the JSON
        if (json.containsKey('password')) {
          final legacyPassword = json['password'] as String? ?? '';
          if (legacyPassword.isNotEmpty) {
            password = legacyPassword;
            await _secureStorage.write(key: _pwKey(id), value: legacyPassword);
          }
          // Strip the plaintext password and overwrite the stored JSON
          json.remove('password');
          await prefs.setString(_configKey, jsonEncode(json));
          debugPrint('Migrated plaintext password to secure storage');
        }

        // Rebuild config with the recovered secrets. The prefix was stripped
        // from the JSON by _migratePlaintextPrefixes and lives per server in
        // the keystore, like the password.
        json['password'] = password;
        json['clientRandomPrefix'] = await _readPrefix(id);
        return ServerConfig.fromJson(json);
      }
    } catch (e) {
      debugPrint('Error loading config: $e');
    }

    // Return default config if loading fails
    return ServerConfig.defaultConfig();
  }

  /// Save the active server configuration to local storage and sync it into
  /// the server list (upsert by id; the saved server becomes the active one).
  Future<void> saveConfig(ServerConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _ensureServerList(prefs);

      var cfg = config;
      if (cfg.id.isEmpty) {
        // Legacy callers build configs from scratch without an id — adopt
        // the currently active identity instead of forking a new entry.
        cfg = cfg.copyWith(
            id: prefs.getString(_activeServerKey) ?? newServerId());
      }

      final json = cfg.toJson();
      // Log counts, not the lists themselves — they can hold thousands of
      // entries and stringifying them on every save is pure waste.
      debugPrint('Saving config - vpnMode: ${json['vpnMode']}, '
          'domains: ${cfg.splitTunnelDomains.length}, '
          'apps: ${cfg.splitTunnelApps.length}');

      // App-global settings live in their own keys, not in server entries.
      await prefs.setString(_appDnsKey, cfg.dns);
      await prefs.setString(_appLogLevelKey, cfg.logLevel);

      // Store the password in secure storage, never in SharedPreferences.
      // NEVER clobber a stored password with an empty string: '' means
      // "unknown" in every internal path (list entries and deploy fallbacks
      // never carry passwords), and Settings validates non-empty anyway.
      if (cfg.password.isNotEmpty) {
        await _secureStorage.write(key: _pwKey(cfg.id), value: cfg.password);
      } else if (await _secureStorage.read(key: _pwKey(cfg.id)) == null) {
        await _secureStorage.write(key: _pwKey(cfg.id), value: '');
      }
      json.remove('password');

      // The client random prefix goes to the keystore too. Unlike the
      // password it is written as-is: '' is a legitimate value (no connection
      // filtering) and every internal path carries the real stored prefix.
      await _secureStorage.write(
          key: _prefixKey(cfg.id), value: cfg.clientRandomPrefix);
      json.remove('clientRandomPrefix');

      await prefs.setString(_configKey, jsonEncode(json));

      final servers = _decodeServers(prefs);
      final idx = servers.indexWhere((s) => s['id'] == cfg.id);
      if (idx >= 0) {
        servers[idx] = json;
      } else {
        servers.add(json);
      }
      await prefs.setString(_serversKey, jsonEncode(servers));
      await prefs.setString(_activeServerKey, cfg.id);
      _refreshServersCache(prefs);
      notifyListeners();
    } catch (e) {
      debugPrint('Error saving config: $e');
      rethrow;
    }
  }

  /// Get path to client directory
  Future<String> getClientDirectory() async {
    String baseDir;

    if (Platform.isMacOS) {
      // On macOS, the executable is inside .app/Contents/MacOS/
      // We need to go up to the directory containing the .app bundle
      final exePath = Platform.resolvedExecutable;
      var dir = File(exePath).parent;
      // Walk up until we exit the .app bundle
      while (dir.path.contains('.app')) {
        dir = dir.parent;
      }
      baseDir = dir.path;
    } else {
      baseDir = Directory.current.path;
    }

    final clientDir = p.join(baseDir, 'client');

    // Create directory if it doesn't exist
    final dir = Directory(clientDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    return clientDir;
  }

  /// Get path to Trusty client executable
  Future<String> getTrustTunnelExecutable() async {
    final clientDir = await getClientDirectory();

    if (Platform.isWindows) {
      final clientExe = p.join(clientDir, 'trusttunnel_client.exe');
      if (await File(clientExe).exists()) return clientExe;
      return p.join(clientDir, 'trusttunnel.exe');
    } else {
      final clientBin = p.join(clientDir, 'trusttunnel_client');
      if (await File(clientBin).exists()) return clientBin;
      return p.join(clientDir, 'trusttunnel');
    }
  }

  /// Check if Trusty client binary exists
  Future<bool> isTrustTunnelInstalled() async {
    final exePath = await getTrustTunnelExecutable();
    return File(exePath).exists();
  }

  /// Get path to config.toml file
  Future<String> getConfigFilePath() async {
    final clientDir = await getClientDirectory();
    return p.join(clientDir, _configFileName);
  }

  /// Write TOML config file for Trusty client
  Future<void> writeConfigFile(ServerConfig config) async {
    try {
      final configPath = await getConfigFilePath();
      final file = File(configPath);

      debugPrint('Config validation: hostname=${config.hostname}, address=${config.address}, username=${config.username}');
      debugPrint('Writing TOML - vpnMode: ${config.vpnMode}, '
          'domains: ${config.splitTunnelDomains.length}, '
          'apps: ${config.splitTunnelApps.length}');

      // Validate config before generating TOML
      if (config.hostname.isEmpty) {
        throw Exception(L10n.tr.configErrorHostnameEmpty);
      }
      if (config.address.isEmpty) {
        throw Exception(L10n.tr.configErrorAddressEmpty);
      }
      if (config.username.isEmpty) {
        throw Exception(L10n.tr.configErrorUsernameEmpty);
      }

      // Merge enabled routing lists into the exclusions (auto-refreshing
      // stale ones within a hard time budget so connect never hangs).
      var effective = config;
      final listEntries = await collectRoutingEntries(config.vpnMode);
      if (listEntries.isNotEmpty) {
        effective = config.copyWith(
          splitTunnelDomains:
              {...config.splitTunnelDomains, ...listEntries}.toList(),
        );
        debugPrint('Merged ${listEntries.length} routing list entries');
      }
      lastMergedExclusionCount = effective.splitTunnelDomains.length;
      if (lastMergedExclusionCount > mergedExclusionsSoftLimit) {
        debugPrint('Merged exclusions ($lastMergedExclusionCount) exceed '
            'the soft limit of $mergedExclusionsSoftLimit');
      }

      final toml = effective.toToml();
      await file.writeAsString(toml);

      // Restrict permissions to the owner since the TOML holds the password.
      // On Windows the user profile dir ACLs already restrict access.
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', configPath]);
      }

      debugPrint('Config file written successfully to: $configPath');
    } catch (e, stackTrace) {
      debugPrint('Error writing config file: $e');
      debugPrint('Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Delete TOML config file
  Future<void> deleteConfigFile() async {
    try {
      final configPath = await getConfigFilePath();
      final file = File(configPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('Error deleting config file: $e');
    }
  }

  /// Export configuration to JSON file. Secrets (password, client random
  /// prefix) never leave the keystore — the exported file is plaintext.
  Future<void> exportConfig(ServerConfig config, String filePath) async {
    try {
      final file = File(filePath);
      final json = config.toJson()
        ..remove('password')
        ..remove('clientRandomPrefix');
      await file.writeAsString(jsonEncode(json));
    } catch (e) {
      debugPrint('Error exporting config: $e');
      rethrow;
    }
  }

  /// Import configuration from JSON file. Accepts both old exports that
  /// carried secrets inline and new secret-free ones (missing fields default
  /// to empty in [ServerConfig.fromJson]).
  Future<ServerConfig> importConfig(String filePath) async {
    try {
      final file = File(filePath);
      final jsonString = await file.readAsString();
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return ServerConfig.fromJson(json);
    } catch (e) {
      debugPrint('Error importing config: $e');
      rethrow;
    }
  }

  /// Load domain groups from local storage
  Future<DomainGroupsData> loadDomainGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_domainGroupsKey);

      if (jsonString != null) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        return DomainGroupsData.fromJson(json);
      }
    } catch (e) {
      debugPrint('Error loading domain groups: $e');
    }

    return DomainGroupsData();
  }

  /// Save domain groups to local storage
  Future<void> saveDomainGroups(DomainGroupsData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = jsonEncode(data.toJson());
      await prefs.setString(_domainGroupsKey, jsonString);
    } catch (e) {
      debugPrint('Error saving domain groups: $e');
      rethrow;
    }
  }

  // --- Routing lists: ready-made "route via VPN / bypass VPN" sets ---------
  // The built-in "blocked in Russia" preset plus user-added lists from a URL
  // (GitHub raw etc., auto-updating) or a local file. Entries are validated,
  // cached under client/routing_lists/<id>.lst and merged into the
  // exclusions at connect time according to each list's appliesTo mode.

  static const String _routingListsKey = 'routing_lists';

  // Legacy single-preset keys (pre-0.4.0), migrated into _routingListsKey.
  static const String _presetEnabledKey = 'routing_preset_enabled';
  static const String _presetUpdatedKey = 'routing_preset_updated';
  static const String _presetCountKey = 'routing_preset_count';
  static const String _presetFileName = 'routing_preset.lst';

  static const String builtinRoutingListId = 'ru-blocked';

  static const List<String> routingPresetUrls = [
    'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst',
    'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/telegram.lst',
    'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/discord.lst',
  ];

  /// Refresh lists not updated for this long automatically at connect time.
  static const Duration routingListMaxAge = Duration(hours: 24);

  /// Hard ceiling on how long connect may wait for list refreshes.
  static const Duration _routingRefreshBudget = Duration(seconds: 8);

  static const int _maxListBytes = 5 * 1024 * 1024;
  static const int _maxListEntries = 100000;

  /// Soft ceiling on merged exclusions: above this the config still works,
  /// but tunnel setup slows down noticeably, so the app warns instead of
  /// blocking the connect.
  static const int mergedExclusionsSoftLimit = 20000;

  /// Total exclusion count of the last [writeConfigFile] merge — the connect
  /// path turns counts above [mergedExclusionsSoftLimit] into a warning.
  int lastMergedExclusionCount = 0;

  /// Parse a downloaded routing list: one domain / IP / CIDR per line,
  /// `#` comments and blank lines ignored, ".tld"-style entries normalized
  /// to a bare suffix. Case-insensitive de-duplication.
  static List<String> parseRoutingList(String body) {
    final result = <String>[];
    final seen = <String>{};
    for (var line in const LineSplitter().convert(body)) {
      line = line.trim().toLowerCase();
      final comment = line.indexOf('#');
      if (comment >= 0) line = line.substring(0, comment).trim();
      while (line.startsWith('.')) {
        line = line.substring(1);
      }
      if (line.isEmpty) continue;
      if (seen.add(line)) result.add(line);
    }
    return result;
  }

  /// Split parsed lines into valid exclusions and a skipped-count. Accepts
  /// what [classifyExclusion] accepts plus bare TLD suffixes ("ua", from
  /// ".ua"-style lines) which the client matches as domain suffixes.
  static (List<String>, int) validateRoutingEntries(List<String> parsed) {
    final valid = <String>[];
    var skipped = 0;
    for (final e in parsed) {
      if (classifyExclusion(e) != ExclusionKind.invalid ||
          RegExp(r'^[a-z]{2,}$').hasMatch(e)) {
        valid.add(e);
      } else {
        skipped++;
      }
    }
    return (valid, skipped);
  }

  List<RoutingList> _decodeRoutingLists(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_routingListsKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((e) => RoutingList.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('Error decoding routing lists: $e');
      return [];
    }
  }

  Future<void> _saveRoutingLists(
      SharedPreferences prefs, List<RoutingList> lists) async {
    await prefs.setString(
        _routingListsKey, jsonEncode(lists.map((l) => l.toJson()).toList()));
  }

  /// One-time migration: wrap the legacy single preset into the lists model
  /// (or create the built-in entry disabled on fresh installs).
  Future<void> _ensureRoutingLists(SharedPreferences prefs) async {
    if (prefs.containsKey(_routingListsKey)) return;

    final builtin = RoutingList(
      id: builtinRoutingListId,
      name: 'Default',
      type: 'builtin',
      urls: routingPresetUrls,
      enabled: prefs.getBool(_presetEnabledKey) ?? false,
      appliesTo: 'selective',
      lastUpdatedIso: prefs.getString(_presetUpdatedKey) ?? '',
      entryCount: prefs.getInt(_presetCountKey) ?? 0,
    );

    // Move the legacy cache file into the new per-list cache location.
    try {
      final legacy = File(p.join(await getClientDirectory(), _presetFileName));
      if (await legacy.exists()) {
        final target = File(await _routingListCachePath(builtin.id));
        await target.writeAsString(await legacy.readAsString());
        await legacy.delete();
      }
    } catch (e) {
      debugPrint('Routing preset cache migration failed: $e');
    }

    await _saveRoutingLists(prefs, [builtin]);
    await prefs.remove(_presetEnabledKey);
    await prefs.remove(_presetUpdatedKey);
    await prefs.remove(_presetCountKey);
  }

  Future<String> _routingListCachePath(String id) async {
    final dir = Directory(p.join(await getClientDirectory(), 'routing_lists'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return p.join(dir.path, '$id.lst');
  }

  Future<List<RoutingList>> loadRoutingLists() async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureRoutingLists(prefs);
    final lists = _decodeRoutingLists(prefs);
    // One-time rename of the built-in list's original label.
    final idx = lists.indexWhere(
        (l) => l.isBuiltin && l.name == 'Sites blocked in Russia');
    if (idx >= 0) {
      lists[idx] = lists[idx].copyWith(name: 'Default');
      await _saveRoutingLists(prefs, lists);
    }
    return lists;
  }

  Future<void> _updateRoutingList(
      String id, RoutingList Function(RoutingList) change) async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureRoutingLists(prefs);
    final lists = _decodeRoutingLists(prefs);
    final idx = lists.indexWhere((l) => l.id == id);
    if (idx < 0) return;
    lists[idx] = change(lists[idx]);
    await _saveRoutingLists(prefs, lists);
    notifyListeners();
  }

  Future<void> setRoutingListEnabled(String id, bool enabled) =>
      _updateRoutingList(id, (l) => l.copyWith(enabled: enabled));

  Future<void> setRoutingListAppliesTo(String id, String appliesTo) =>
      _updateRoutingList(id, (l) => l.copyWith(appliesTo: appliesTo));

  static Future<String> _httpGet(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url));
      final response =
          await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
    } finally {
      client.close();
    }
  }

  /// Fetch a URL and enforce the size cap (also guards geosite includes).
  Future<String> _fetchBody(String url) async {
    final body = await _fetchUrl(url);
    if (body.length > _maxListBytes) {
      throw Exception('List is too large (> 5 MB)');
    }
    return body;
  }

  /// Fetch and validate a routing source without saving anything — used by
  /// the add-list dialog's Check step and by [refreshRoutingList].
  /// Returns (valid entries, skipped count, per-source errors).
  Future<(List<String>, int, List<String>)> fetchRoutingSource({
    List<String> urls = const [],
    String filePath = '',
    String format = 'plain',
  }) async {
    final entries = <String>{};
    var skipped = 0;
    final errors = <String>[];

    // The cache stores the flat parsed output, so format-specific parsing
    // (including geosite `include:` sub-fetches) happens only here. 'geoip'
    // is line-wise identical to 'plain' (CIDR per line, # comments).
    Future<void> addBody(String body, {String sourceUrl = ''}) async {
      if (body.length > _maxListBytes) {
        throw Exception('List is too large (> 5 MB)');
      }
      final parsed = format == 'geosite'
          ? await parseGeositeList(
              body,
              fetchCategory: (category) => sourceUrl.isEmpty
                  ? throw Exception('include: requires a URL source')
                  : _fetchBody(geositeSiblingUrl(sourceUrl, category)),
            )
          : parseRoutingList(body);
      final (valid, bad) = validateRoutingEntries(parsed);
      skipped += bad;
      entries.addAll(valid);
    }

    if (filePath.isNotEmpty) {
      await addBody(await File(filePath).readAsString());
    } else {
      for (final url in urls) {
        try {
          await addBody(await _fetchBody(url), sourceUrl: url);
        } catch (e) {
          // Partial success: one dead mirror must not kill the refresh.
          errors.add('$url: $e');
        }
      }
    }

    if (entries.isEmpty) {
      throw Exception(errors.isNotEmpty
          ? 'All sources failed: ${errors.first}'
          : 'The source contains no valid entries');
    }
    // Enforced OUTSIDE the per-source try so it cannot be swallowed as a
    // source error.
    if (entries.length > _maxListEntries) {
      throw Exception('List has too many entries (> $_maxListEntries)');
    }
    return (entries.toList(), skipped, errors);
  }

  /// Re-download (or re-read) a list, refresh its cache and metadata.
  /// On failure the cache is kept, lastError is recorded, and the error is
  /// rethrown for the caller's UI.
  Future<void> refreshRoutingList(String id) async {
    final lists = await loadRoutingLists();
    RoutingList? list;
    for (final l in lists) {
      if (l.id == id) list = l;
    }
    if (list == null) return;

    try {
      final (entries, _, errors) = await fetchRoutingSource(
        urls: list.type == 'file' ? const [] : list.urls,
        filePath: list.type == 'file' ? list.sourcePath : '',
        format: list.format,
      );

      // A "partial success" that gutted the list (e.g. the main source of
      // the built-in preset returned 500 while the small subnet mirrors
      // succeeded) must not replace a previously complete cache.
      if (errors.isNotEmpty &&
          list.entryCount > 0 &&
          entries.length < list.entryCount ~/ 2) {
        throw Exception(
            'Refresh returned only ${entries.length} of ${list.entryCount} '
            'entries (${errors.length} sources failed) — keeping the '
            'previous version');
      }

      // Write via temp-file + rename so a concurrent connect-time read never
      // observes a truncated half-written cache.
      final file = File(await _routingListCachePath(id));
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(entries.join('\n'));
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
      await _updateRoutingList(
        id,
        (l) => l.copyWith(
          entryCount: entries.length,
          lastUpdatedIso: DateTime.now().toIso8601String(),
          lastError: errors.isEmpty
              ? ''
              : 'Partially updated (${errors.length} sources failed)',
        ),
      );
    } catch (e) {
      await _updateRoutingList(
          id, (l) => l.copyWith(lastError: e.toString()));
      rethrow;
    }
  }

  /// Add a user list from a URL or a local file. Fetches and validates
  /// first — nothing is saved when the source is unusable.
  Future<RoutingList> addRoutingList({
    required String name,
    List<String> urls = const [],
    String filePath = '',
    String format = 'plain',
  }) async {
    final (entries, _, _) = await fetchRoutingSource(
        urls: urls, filePath: filePath, format: format);

    final list = RoutingList(
      id: newServerId(),
      name: name,
      type: filePath.isNotEmpty ? 'file' : 'url',
      urls: urls,
      sourcePath: filePath,
      format: format,
      enabled: true,
      appliesTo: 'selective',
      lastUpdatedIso: DateTime.now().toIso8601String(),
      entryCount: entries.length,
    );

    final file = File(await _routingListCachePath(list.id));
    await file.writeAsString(entries.join('\n'));

    final prefs = await SharedPreferences.getInstance();
    await _ensureRoutingLists(prefs);
    final lists = _decodeRoutingLists(prefs)..add(list);
    await _saveRoutingLists(prefs, lists);
    notifyListeners();
    return list;
  }

  Future<void> deleteRoutingList(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await _ensureRoutingLists(prefs);
    final lists = _decodeRoutingLists(prefs);
    lists.removeWhere((l) => l.id == id && !l.isBuiltin);
    await _saveRoutingLists(prefs, lists);
    try {
      final file = File(await _routingListCachePath(id));
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('Failed to delete routing list cache: $e');
    }
    notifyListeners();
  }

  /// All entries from enabled lists applicable in [mode]. Stale lists
  /// (older than [routingListMaxAge]) and lists whose cache file vanished
  /// are refreshed first, bounded by a hard time budget so connect never
  /// hangs; on failure the cached entries (if any) are used.
  Future<List<String>> collectRoutingEntries(VpnMode mode) async {
    final active = (await loadRoutingLists())
        .where((l) => l.enabled && l.matchesMode(mode))
        .toList();
    if (active.isEmpty) return const [];

    final now = DateTime.now();
    final stale = <String>[];
    for (final l in active) {
      final cacheMissing =
          !await File(await _routingListCachePath(l.id)).exists();
      final tooOld = l.lastUpdated == null ||
          now.difference(l.lastUpdated!) > routingListMaxAge;
      if (cacheMissing || (l.type != 'file' && tooOld)) stale.add(l.id);
    }
    if (stale.isNotEmpty) {
      debugPrint('Refreshing ${stale.length} routing lists before connect');
      try {
        await Future.wait(
          stale.map((id) => refreshRoutingList(id).catchError((e) {
                debugPrint('Routing list $id refresh failed: $e');
              })),
        ).timeout(_routingRefreshBudget);
      } catch (e) {
        debugPrint('Routing list refresh budget exceeded: $e');
      }
    }

    final entries = <String>{};
    for (final l in active) {
      try {
        final file = File(await _routingListCachePath(l.id));
        if (await file.exists()) {
          entries.addAll(parseRoutingList(await file.readAsString()));
        }
      } catch (e) {
        debugPrint('Error reading routing list ${l.id}: $e');
      }
    }
    return entries.toList();
  }

  /// Migrate flat splitTunnelDomains to domain groups (one-time)
  Future<DomainGroupsData> migrateFlatDomainsToGroups() async {
    final prefs = await SharedPreferences.getInstance();

    // If groups already exist, no migration needed
    if (prefs.containsKey(_domainGroupsKey)) {
      return loadDomainGroups();
    }

    // Load existing config to get flat domains
    final config = await loadConfig();
    final flatDomains = config.splitTunnelDomains;

    // Move all flat domains to standalone
    final data = DomainGroupsData(
      standaloneDomains: List.from(flatDomains),
    );

    if (flatDomains.isNotEmpty) {
      await saveDomainGroups(data);
    }

    return data;
  }
}

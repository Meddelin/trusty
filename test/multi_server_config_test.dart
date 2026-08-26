import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/services/config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory fake of flutter_secure_storage's method channel.
  final secureStore = <String, String>{};
  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    secureStore.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final args =
          (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return secureStore[key];
        case 'write':
          secureStore[key!] = args['value'] as String? ?? '';
          return null;
        case 'delete':
          secureStore.remove(key);
          return null;
        case 'readAll':
          return Map<String, String>.from(secureStore);
        case 'deleteAll':
          secureStore.clear();
          return null;
        case 'containsKey':
          return secureStore.containsKey(key);
      }
      return null;
    });
  });

  test('legacy single config migrates into a one-entry server list', () async {
    final legacy = ServerConfig(
      hostname: 'old.example.com',
      address: '1.2.3.4',
      username: 'user1',
      password: '',
      dns: 'tls://1.1.1.1',
    ).toJson()
      ..remove('id')
      ..remove('password');
    SharedPreferences.setMockInitialValues({
      'server_config': jsonEncode(legacy),
    });
    secureStore['vpn_password'] = 'secret';

    final service = ConfigService();
    final config = await service.loadConfig();

    expect(config.hostname, 'old.example.com');
    expect(config.password, 'secret');
    expect(config.id, isNotEmpty);

    final servers = await service.loadServers();
    expect(servers, hasLength(1));
    expect(servers.single.id, config.id);
    expect(await service.getActiveServerId(), config.id);
    // Password re-keyed per server, legacy key kept for downgrade safety.
    expect(secureStore['vpn_password_${config.id}'], 'secret');
    expect(secureStore['vpn_password'], 'secret');
  });

  test('pre-0.3.3 plaintext password inside the JSON survives migration',
      () async {
    // Oldest format: password as plaintext INSIDE server_config, nothing in
    // the keystore. The server-list migration must not strip it before it
    // reaches secure storage.
    final legacy = ServerConfig(
      hostname: 'old.example.com',
      address: '1.2.3.4',
      username: 'user1',
      password: 'plain-secret',
    ).toJson()
      ..remove('id');
    SharedPreferences.setMockInitialValues({
      'server_config': jsonEncode(legacy),
    });

    final service = ConfigService();
    final config = await service.loadConfig();

    expect(config.password, 'plain-secret');
    expect(secureStore['vpn_password_${config.id}'], 'plain-secret');
  });

  test('saveConfig never clobbers a stored password with an empty string',
      () async {
    final service = ConfigService();
    await service.saveConfig(ServerConfig(
      hostname: 'a.example.com',
      address: '1.1.1.1',
      username: 'ua',
      password: 'pa',
    ));
    final id = await service.getActiveServerId();

    // Internal paths (deploy fallback, list entries) carry '' passwords —
    // that must mean "unknown", not "erase".
    final current = await service.loadConfig();
    await service.saveConfig(current.copyWith(password: ''));

    expect(secureStore['vpn_password_$id'], 'pa');
    expect((await service.loadConfig()).password, 'pa');
  });

  test('switching servers keeps app-wide settings and swaps credentials',
      () async {
    final service = ConfigService();

    // Server A with user routing setup.
    await service.saveConfig(ServerConfig(
      hostname: 'a.example.com',
      address: '1.1.1.1',
      username: 'ua',
      password: 'pa',
      dns: 'https://dns.adguard-dns.com/dns-query, 8.8.8.8',
      vpnMode: VpnMode.selective,
      splitTunnelDomains: ['youtube.com'],
      splitTunnelApps: ['game.exe'],
    ));
    final idA = await service.getActiveServerId();

    // Add server B via the add-server dialog flow (becomes active).
    await service.addServerConfig(ServerConfig(
      name: 'Backup',
      hostname: 'b.example.com',
      address: '2.2.2.2',
      username: 'ub',
      password: 'pb',
    ));
    final config = await service.loadConfig();
    final idB = config.id;

    expect(idB, isNot(idA));
    expect(config.hostname, 'b.example.com');
    expect(config.name, 'Backup');
    expect(config.password, 'pb');
    // App-wide settings survived the switch.
    expect(config.dns, 'https://dns.adguard-dns.com/dns-query, 8.8.8.8');
    expect(config.vpnMode, VpnMode.selective);
    expect(config.splitTunnelDomains, ['youtube.com']);
    expect(config.splitTunnelApps, ['game.exe']);

    // Global settings are single-keyed: changing DNS while B is active
    // changes it for A as well.
    await service.setGlobalDns('tls://1.1.1.1');

    // Switch back to A: connection fields and password restored, global
    // DNS reflects the latest value.
    await service.switchServer(idA);
    final back = await service.loadConfig();
    expect(back.id, idA);
    expect(back.hostname, 'a.example.com');
    expect(back.password, 'pa');
    expect(back.dns, 'tls://1.1.1.1');
    expect(back.splitTunnelDomains, ['youtube.com']);

    expect(await service.loadServers(), hasLength(2));
  });

  test('saving a config with a new id adds a server instead of overwriting',
      () async {
    final service = ConfigService();
    await service.saveConfig(ServerConfig(
      hostname: 'a.example.com',
      address: '1.1.1.1',
      username: 'ua',
      password: 'pa',
    ));
    final idA = await service.getActiveServerId();

    // What applyToClientConfig does after deploying to a fresh VPS.
    final current = await service.loadConfig();
    await service.saveConfig(current.copyWith(
      id: ConfigService.newServerId(),
      hostname: 'b.example.com',
      address: '2.2.2.2',
      username: 'ub',
      password: 'pb',
    ));

    final servers = await service.loadServers();
    expect(servers, hasLength(2));
    expect(servers.map((s) => s.hostname),
        containsAll(['a.example.com', 'b.example.com']));
    // The new server is active; the old one (and its password) is intact.
    final active = await service.loadConfig();
    expect(active.hostname, 'b.example.com');
    expect(secureStore['vpn_password_$idA'], 'pa');
  });

  test('deleting the active server switches to the remaining one', () async {
    final service = ConfigService();
    await service.saveConfig(ServerConfig(
      hostname: 'a.example.com',
      address: '1.1.1.1',
      username: 'ua',
      password: 'pa',
    ));
    final idA = await service.getActiveServerId();
    final current = await service.loadConfig();
    await service.saveConfig(current.copyWith(
      id: ConfigService.newServerId(),
      hostname: 'b.example.com',
      password: 'pb',
    ));
    final idB = await service.getActiveServerId();

    await service.deleteServer(idB);

    expect(await service.loadServers(), hasLength(1));
    final active = await service.loadConfig();
    expect(active.id, idA);
    expect(active.hostname, 'a.example.com');
    expect(active.password, 'pa');
    expect(secureStore.containsKey('vpn_password_$idB'), isFalse);

    // The last server cannot be deleted.
    await service.deleteServer(idA);
    expect(await service.loadServers(), hasLength(1));
  });

  test('plaintext client random prefixes migrate into the keystore', () async {
    // Pre-keystore format: the prefix sits as plaintext inside both the
    // server list and the active config JSON.
    final entry = ServerConfig(
      id: 'srv1',
      hostname: 'a.example.com',
      address: '1.1.1.1',
      username: 'ua',
      password: '',
      clientRandomPrefix: 'aabbccdd/ff00ff00',
    ).toJson()
      ..remove('password');
    SharedPreferences.setMockInitialValues({
      'server_config': jsonEncode(entry),
      'server_list': jsonEncode([entry]),
      'active_server_id': 'srv1',
    });

    final service = ConfigService();
    final config = await service.loadConfig();

    expect(config.clientRandomPrefix, 'aabbccdd/ff00ff00');
    expect(secureStore['client_random_prefix_srv1'], 'aabbccdd/ff00ff00');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('server_config'), isNot(contains('aabbccdd')));
    expect(prefs.getString('server_list'), isNot(contains('aabbccdd')));
  });

  test('saveConfig keeps the prefix out of SharedPreferences and round-trips',
      () async {
    final service = ConfigService();
    await service.saveConfig(ServerConfig(
      hostname: 'a.example.com',
      address: '1.1.1.1',
      username: 'ua',
      password: 'pa',
      clientRandomPrefix: 'deadbeef/ff00ff00',
    ));
    final id = await service.getActiveServerId();

    expect(secureStore['client_random_prefix_$id'], 'deadbeef/ff00ff00');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('server_config'), isNot(contains('deadbeef')));
    expect(prefs.getString('server_list'), isNot(contains('deadbeef')));
    expect(
        (await service.loadConfig()).clientRandomPrefix, 'deadbeef/ff00ff00');

    // Unlike the password, clearing the prefix is a legitimate edit —
    // an empty value must actually stick.
    final current = await service.loadConfig();
    await service.saveConfig(current.copyWith(clientRandomPrefix: ''));
    expect((await service.loadConfig()).clientRandomPrefix, isEmpty);
  });

  test('switching servers swaps the keystore-held prefix', () async {
    final service = ConfigService();
    await service.saveConfig(ServerConfig(
      hostname: 'a.example.com',
      address: '1.1.1.1',
      username: 'ua',
      password: 'pa',
      clientRandomPrefix: 'aaaa1111/ff00ff00',
    ));
    final idA = await service.getActiveServerId();

    await service.addServerConfig(ServerConfig(
      hostname: 'b.example.com',
      address: '2.2.2.2',
      username: 'ub',
      password: 'pb',
    ));
    expect((await service.loadConfig()).clientRandomPrefix, isEmpty);

    await service.switchServer(idA);
    expect(
        (await service.loadConfig()).clientRandomPrefix, 'aaaa1111/ff00ff00');
  });

  test('exportConfig omits secrets; importConfig accepts old files with them',
      () async {
    final dir = await Directory.systemTemp.createTemp('trusty_test');
    addTearDown(() => dir.delete(recursive: true));
    final service = ConfigService();

    final path = p.join(dir.path, 'export.json');
    await service.exportConfig(
      ServerConfig(
        hostname: 'h',
        address: 'a',
        username: 'u',
        password: 'secret-pw',
        clientRandomPrefix: 'feedface/ff00ff00',
      ),
      path,
    );
    final raw = await File(path).readAsString();
    expect(raw, isNot(contains('secret-pw')));
    expect(raw, isNot(contains('feedface')));
    final imported = await service.importConfig(path);
    expect(imported.hostname, 'h');
    expect(imported.password, isEmpty);
    expect(imported.clientRandomPrefix, isEmpty);

    // Old exports carried the secrets inline — they still import.
    final legacyPath = p.join(dir.path, 'legacy.json');
    await File(legacyPath).writeAsString(jsonEncode(ServerConfig(
      hostname: 'h',
      address: 'a',
      username: 'u',
      password: 'old-pw',
      clientRandomPrefix: 'cafebabe/ff00ff00',
    ).toJson()));
    final legacy = await service.importConfig(legacyPath);
    expect(legacy.password, 'old-pw');
    expect(legacy.clientRandomPrefix, 'cafebabe/ff00ff00');
  });

  test('multiple DNS upstreams are emitted as a TOML list', () {
    final cfg = ServerConfig(
      hostname: 'h',
      address: 'a',
      username: 'u',
      password: 'p',
      dns: 'https://dns.adguard-dns.com/dns-query, 8.8.8.8 tls://1.1.1.1',
    );
    expect(
      cfg.toToml(),
      contains('dns_upstreams = ["https://dns.adguard-dns.com/dns-query", '
          '"8.8.8.8", "tls://1.1.1.1"]'),
    );
  });

  test('empty DNS field yields empty upstreams', () {
    final cfg = ServerConfig(
      hostname: 'h',
      address: 'a',
      username: 'u',
      password: 'p',
      dns: '',
    );
    expect(cfg.toToml(), contains('dns_upstreams = []'));
  });

  test('server id survives a json round-trip', () {
    final cfg = ServerConfig(
      id: 'abc42',
      hostname: 'h',
      address: 'a',
      username: 'u',
      password: 'p',
    );
    expect(ServerConfig.fromJson(cfg.toJson()).id, 'abc42');
  });

  test('parseRoutingList strips comments, leading dots and duplicates', () {
    final entries = ConfigService.parseRoutingList(
      '# comment\n'
      '.ua\n'
      'YouTube.com\n'
      'youtube.com\n'
      '\n'
      '1.2.3.0/24 # inline comment\n',
    );
    expect(entries, ['ua', 'youtube.com', '1.2.3.0/24']);
  });
}

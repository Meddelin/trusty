import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/services/config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ServerConfig cfg({String mode = 'tun', int port = 1080}) => ServerConfig(
        hostname: 'vpn.example.com',
        address: '1.2.3.4',
        username: 'u',
        password: 'p',
        connectionMode: mode,
        socksPort: port,
      );

  group('toToml listener section', () {
    test('socks5 mode emits [listener.socks] bound to loopback', () {
      final toml = cfg(mode: 'socks5').toToml();
      expect(toml, contains('[listener.socks]'));
      expect(toml, contains('address = "127.0.0.1:1080"'));
      expect(toml, isNot(contains('[listener.tun]')));
      // The rest of the config is unaffected by the listener choice.
      expect(toml, contains('[endpoint]'));
      expect(toml, contains('vpn_mode = "general"'));
    });

    test('socks5 mode uses the configured port', () {
      final toml = cfg(mode: 'socks5', port: 9150).toToml();
      expect(toml, contains('address = "127.0.0.1:9150"'));
    });

    test('tun mode (default) emits the exact TUN listener block', () {
      final toml = cfg().toToml();
      expect(toml, isNot(contains('[listener.socks]')));
      // Byte-exact tail: the TUN config must not change for existing users.
      expect(
        toml,
        endsWith('''
[listener]

[listener.tun]
# Name of the interface used for connections made by the VPN client.
# On Linux and Windows, it is detected automatically if not specified.
# On macOS, it defaults to `en0` if not specified.
# On Windows, an interface index as shown by `route print`, written as a string, may be used instead of a name.
bound_if = ""
# Routes in CIDR notation to set to the virtual interface
included_routes = ["0.0.0.0/0", "2000::/3"]
# Routes in CIDR notation to exclude from routing through the virtual interface
excluded_routes = ["0.0.0.0/8", "10.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3"]
# MTU size on the interface
mtu_size = 1280
# Allow changing system DNS servers
change_system_dns = true
'''),
      );
    });

    test('socks5 mode rejects an out-of-range port', () {
      expect(() => cfg(mode: 'socks5', port: 0).toToml(), throwsException);
      expect(() => cfg(mode: 'socks5', port: 65536).toToml(), throwsException);
    });

    test('tun mode ignores the socks port entirely', () {
      expect(() => cfg(port: 0).toToml(), returnsNormally);
    });
  });

  group('connection mode json', () {
    test('mode and port survive a round-trip', () {
      final back =
          ServerConfig.fromJson(cfg(mode: 'socks5', port: 9150).toJson());
      expect(back.connectionMode, 'socks5');
      expect(back.socksPort, 9150);
      expect(back.isSocksMode, isTrue);
      expect(back.socksProxyAddress, '127.0.0.1:9150');
    });

    test('absent keys (pre-0.4.0 config) default to tun/1080', () {
      final json = cfg().toJson()
        ..remove('connectionMode')
        ..remove('socksPort');
      final back = ServerConfig.fromJson(json);
      expect(back.connectionMode, 'tun');
      expect(back.socksPort, 1080);
      expect(back.isSocksMode, isFalse);
    });

    test('unknown mode strings fall back to tun', () {
      final json = cfg().toJson()..['connectionMode'] = 'http';
      expect(ServerConfig.fromJson(json).connectionMode, 'tun');
    });
  });

  group('connection mode persistence', () {
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
        }
        return null;
      });
    });

    test('defaults to tun when the key was never written', () async {
      final service = ConfigService();
      final config = await service.loadConfig();
      expect(config.connectionMode, 'tun');
      expect(config.socksPort, 1080);
      expect(service.connectionModeCache, 'tun');
    });

    test('setGlobalConnectionMode/Port persist across service instances',
        () async {
      final service = ConfigService();
      await service.saveConfig(cfg());
      await service.setGlobalConnectionMode('socks5');
      await service.setGlobalSocksPort(9150);

      final fresh = ConfigService();
      final config = await fresh.loadConfig();
      expect(config.connectionMode, 'socks5');
      expect(config.socksPort, 9150);
      expect(fresh.connectionModeCache, 'socks5');
      expect(fresh.socksPortCache, 9150);
    });

    test('mode is app-global: switching servers keeps it', () async {
      final service = ConfigService();
      await service.saveConfig(cfg());
      final idA = await service.getActiveServerId();
      await service.setGlobalConnectionMode('socks5');

      await service.addServerConfig(ServerConfig(
        hostname: 'b.example.com',
        address: '2.2.2.2',
        username: 'ub',
        password: 'pb',
      ));
      expect((await service.loadConfig()).connectionMode, 'socks5');

      await service.switchServer(idA);
      expect((await service.loadConfig()).connectionMode, 'socks5');
    });

    test('stale per-entry copies in stored JSON are ignored', () async {
      final service = ConfigService();
      // The active entry claims socks5 in its own JSON, but the app-global
      // key was never written — the global default (tun) must win.
      await service.saveConfig(cfg(mode: 'socks5'));
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('app_connection_mode');

      final fresh = ConfigService();
      expect((await fresh.loadConfig()).connectionMode, 'tun');
    });
  });
}

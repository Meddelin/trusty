import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/models/server_setup_config.dart';
import 'package:trusty/models/setup_step.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/services/server_setup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // In-memory fake of flutter_secure_storage's method channel — the deploy
  // result keeps its generated prefix in the keystore.
  final secureStore = <String, String>{};
  const channel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUp(() {
    secureStore.clear();
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

  group('ServerSetupResult', () {
    test('JSON round trip keeps every field', () {
      const result = ServerSetupResult(
        host: '203.0.113.5',
        domain: 'vpn.example.com',
        listenPort: 8443,
        vpnUsername: 'alice',
        clientRandomPrefix: 'aabbccdd/ff00ff00',
      );

      final restored = ServerSetupResult.fromJson(result.toJson());

      expect(restored.host, '203.0.113.5');
      expect(restored.domain, 'vpn.example.com');
      expect(restored.listenPort, 8443);
      expect(restored.vpnUsername, 'alice');
      expect(restored.clientRandomPrefix, 'aabbccdd/ff00ff00');
    });

    test('fromConfig snapshots deployed values and drops the password', () {
      final config = ServerSetupConfig(
        host: '203.0.113.5',
        domain: 'vpn.example.com',
        listenPort: 443,
        vpnUsername: 'alice',
        vpnPassword: 'top-secret',
        clientRandomPrefix: 'aabbccdd/ff00ff00',
      );

      final result = ServerSetupResult.fromConfig(config);

      expect(result.domain, 'vpn.example.com');
      expect(result.clientRandomPrefix, 'aabbccdd/ff00ff00');
      expect(result.toJson().values, isNot(contains('top-secret')));
    });
  });

  group('form defaults persistence', () {
    test('round trip restores non-secret fields, never the passwords',
        () async {
      SharedPreferences.setMockInitialValues({});
      final config = ServerSetupConfig(
        host: '203.0.113.5',
        sshPort: 2222,
        sshUsername: 'admin',
        sshPassword: 'ssh-secret',
        useKeyAuth: true,
        sshKeyPath: r'C:\keys\id_ed25519',
        domain: 'vpn.example.com',
        email: 'me@example.com',
        listenPort: 8443,
        vpnUsername: 'alice',
        vpnPassword: 'vpn-secret',
        generateClientRandomPrefix: true,
      );

      await ServerSetupService.saveFormDefaults(config);
      final restored = await ServerSetupService.loadFormDefaults();

      expect(restored, isNotNull);
      expect(restored!.host, '203.0.113.5');
      expect(restored.sshPort, 2222);
      expect(restored.sshUsername, 'admin');
      expect(restored.useKeyAuth, isTrue);
      expect(restored.sshKeyPath, r'C:\keys\id_ed25519');
      expect(restored.domain, 'vpn.example.com');
      expect(restored.email, 'me@example.com');
      expect(restored.listenPort, 8443);
      expect(restored.vpnUsername, 'alice');
      expect(restored.generateClientRandomPrefix, isTrue);
      expect(restored.sshPassword, isEmpty);
      expect(restored.vpnPassword, isEmpty);

      // The raw stored blob must not contain either secret.
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('deploy_form_config');
      expect(raw, isNotNull);
      expect(raw, isNot(contains('ssh-secret')));
      expect(raw, isNot(contains('vpn-secret')));
    });

    test('loadFormDefaults returns null when nothing was saved', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await ServerSetupService.loadFormDefaults(), isNull);
    });
  });

  group('persisted deploy result', () {
    test('legacy result with an inline prefix migrates it to the keystore',
        () async {
      SharedPreferences.setMockInitialValues({
        'deploy_last_result':
            '{"host":"203.0.113.5","domain":"vpn.example.com",'
                '"listenPort":8443,"vpnUsername":"alice",'
                '"clientRandomPrefix":"aabbccdd/ff00ff00"}',
      });
      final service = ServerSetupService();
      expect(service.lastResult, isNull);

      await service.loadPersistedResult();

      final result = service.lastResult;
      expect(result, isNotNull);
      expect(result!.host, '203.0.113.5');
      expect(result.domain, 'vpn.example.com');
      expect(result.listenPort, 8443);
      expect(result.vpnUsername, 'alice');
      expect(result.clientRandomPrefix, 'aabbccdd/ff00ff00');

      // The plaintext copy is gone; the keystore holds the prefix now.
      expect(secureStore['deploy_last_prefix'], 'aabbccdd/ff00ff00');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('deploy_last_result'),
          isNot(contains('aabbccdd')));
    });

    test('loadPersistedResult reads the prefix back from the keystore',
        () async {
      SharedPreferences.setMockInitialValues({
        'deploy_last_result':
            '{"host":"203.0.113.5","domain":"vpn.example.com",'
                '"listenPort":8443,"vpnUsername":"alice"}',
      });
      secureStore['deploy_last_prefix'] = 'aabbccdd/ff00ff00';
      final service = ServerSetupService();

      await service.loadPersistedResult();

      expect(service.lastResult!.clientRandomPrefix, 'aabbccdd/ff00ff00');
    });

    test('loadPersistedResult tolerates a corrupt blob', () async {
      SharedPreferences.setMockInitialValues(
          {'deploy_last_result': 'not-json'});
      final service = ServerSetupService();

      await service.loadPersistedResult();

      expect(service.lastResult, isNull);
    });

    test('loadPersistedResult is a no-op when nothing was persisted',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = ServerSetupService();

      await service.loadPersistedResult();

      expect(service.lastResult, isNull);
    });
  });

  group('applyToClientConfig', () {
    /// Persist a deploy result and apply it, the post-restart flow (no
    /// in-memory config, password unknown).
    Future<void> applyPersistedResult(
        ConfigService configService, Map<String, Object> result) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('deploy_last_result', jsonEncode(result));
      final setup = ServerSetupService();
      await setup.loadPersistedResult();
      await setup.applyToClientConfig(configService);
    }

    test('a NEW server never inherits per-server fields of the active one',
        () async {
      SharedPreferences.setMockInitialValues({});
      final configService = ConfigService();
      // Active server A with every per-server field set away from defaults.
      await configService.saveConfig(ServerConfig(
        hostname: 'a.example.com',
        address: '1.1.1.1',
        username: 'ua',
        password: 'pa',
        hasIpv6: false,
        skipVerification: true,
        upstreamProtocol: 'http3',
        antiDpi: true,
        customSni: 'sni.a.example.com',
        postQuantumGroupEnabled: false,
        clientRandomPrefix: 'aaaa1111/ff00ff00',
        vpnMode: VpnMode.selective,
        splitTunnelDomains: const ['youtube.com'],
      ));

      await applyPersistedResult(configService, {
        'host': '203.0.113.5',
        'domain': 'vpn-b.example.com',
        'listenPort': 8443,
        'vpnUsername': 'alice',
      });

      final active = await configService.loadConfig();
      expect(active.hostname, 'vpn-b.example.com');
      expect(active.address, '203.0.113.5');
      expect(active.port, 8443);
      expect(active.username, 'alice');
      // Fresh server → factory defaults; nothing borrowed from A. A's
      // customSni here would even break TLS against B's certificate.
      expect(active.hasIpv6, isTrue);
      expect(active.skipVerification, isFalse);
      expect(active.upstreamProtocol, 'http2');
      expect(active.antiDpi, isFalse);
      expect(active.customSni, isEmpty);
      expect(active.postQuantumGroupEnabled, isTrue);
      expect(active.clientRandomPrefix, isEmpty);
      // App-global settings do carry over.
      expect(active.vpnMode, VpnMode.selective);
      expect(active.splitTunnelDomains, ['youtube.com']);
    });

    test('re-deploying an existing server keeps ITS per-server fields',
        () async {
      SharedPreferences.setMockInitialValues({});
      final configService = ConfigService();
      // Server B — the future deploy target — has its own settings.
      await configService.saveConfig(ServerConfig(
        hostname: 'vpn-b.example.com',
        address: '2.2.2.2',
        username: 'ub',
        password: 'pb',
        customSni: 'sni.b.example.com',
        upstreamProtocol: 'http3',
      ));
      final idB = await configService.getActiveServerId();
      // Server A becomes active with different settings.
      final current = await configService.loadConfig();
      await configService.saveConfig(current.copyWith(
        id: ConfigService.newServerId(),
        hostname: 'a.example.com',
        address: '1.1.1.1',
        username: 'ua',
        password: 'pa',
        customSni: '',
        upstreamProtocol: 'http2',
        antiDpi: true,
      ));

      await applyPersistedResult(configService, {
        'host': '2.2.2.2',
        'domain': 'vpn-b.example.com',
        'listenPort': 443,
        'vpnUsername': 'ub',
      });

      final active = await configService.loadConfig();
      expect(active.id, idB);
      expect(active.customSni, 'sni.b.example.com');
      expect(active.upstreamProtocol, 'http3');
      expect(active.antiDpi, isFalse,
          reason: "A's antiDpi must not leak into B");
      expect(active.password, 'pb',
          reason: 'the stored password survives a re-deploy');
    });
  });

  group('cancelInstallation', () {
    test('is a no-op when no installation is running', () async {
      SharedPreferences.setMockInitialValues({});
      final service = ServerSetupService();

      await service.cancelInstallation();

      expect(service.errorMessage, isNull);
      expect(service.currentStep, SetupStep.idle);
    });
  });
}

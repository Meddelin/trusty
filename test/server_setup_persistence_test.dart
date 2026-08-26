import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/server_setup_config.dart';
import 'package:trusty/models/setup_step.dart';
import 'package:trusty/services/server_setup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    test('loadPersistedResult restores the last successful deploy', () async {
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

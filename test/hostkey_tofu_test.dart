import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/server_setup_config.dart';
import 'package:trusty/services/server_setup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final config = ServerSetupConfig(host: '203.0.113.5', sshPort: 22);
  final keyA = Uint8List.fromList([0xaa, 0xbb, 0xcc, 0xdd]);
  final keyB = Uint8List.fromList([0x11, 0x22, 0x33, 0x44]);

  test('TOFU trusts and remembers the first key, rejects a changed one',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = ServerSetupService();

    expect(await service.verifyHostKey(config, 'ssh-ed25519', keyA), isTrue);
    expect(await service.verifyHostKey(config, 'ssh-ed25519', keyA), isTrue);
    expect(service.hostKeyMismatch, isFalse);

    expect(await service.verifyHostKey(config, 'ssh-ed25519', keyB), isFalse);
    expect(service.hostKeyMismatch, isTrue);
  });

  test('trustNewHostKey forgets the stored key so the new one is accepted',
      () async {
    SharedPreferences.setMockInitialValues({});
    final service = ServerSetupService();

    await service.verifyHostKey(config, 'ssh-ed25519', keyA);
    expect(await service.verifyHostKey(config, 'ssh-ed25519', keyB), isFalse);

    await service.trustNewHostKey();
    expect(service.hostKeyMismatch, isFalse);
    expect(await service.verifyHostKey(config, 'ssh-ed25519', keyB), isTrue);
  });
}

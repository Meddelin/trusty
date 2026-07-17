import 'package:flutter_test/flutter_test.dart';

import 'package:trusty/models/server_setup_config.dart';

void main() {
  group('validateForInstall', () {
    test('rejects domain with shell metacharacters', () {
      final config = ServerSetupConfig(
        domain: 'a.com; rm -rf /',
        email: 'admin@example.com',
      );
      expect(config.validateForInstall(), isNotNull);
    });

    test('accepts a normal domain + email', () {
      final config = ServerSetupConfig(
        domain: 'vpn.example.com',
        email: 'admin@example.com',
      );
      expect(config.validateForInstall(), isNull);
    });
  });

  test('TOML escaper neutralizes quotes and newlines in credentials', () {
    final config = ServerSetupConfig(
      vpnUsername: 'user',
      vpnPassword: 'pa"ss\nword',
    );

    final toml = config.generateCredentialsToml();

    // The escaped password must stay on a single quoted line.
    expect(toml.contains('password = "pa\\"ss\\nword"'), isTrue);
    // The raw newline must not leak into the TOML structure.
    expect(toml.contains('pa"ss\nword'), isFalse);
  });
}

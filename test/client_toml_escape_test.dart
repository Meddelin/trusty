import 'package:flutter_test/flutter_test.dart';

import 'package:trusty/models/server_config.dart';

void main() {
  test('toToml escapes TOML injection in password', () {
    final config = ServerConfig(
      hostname: 'vpn.example.com',
      address: '127.0.0.1',
      username: 'user',
      password: 'pa"ss\nskip_verification = true',
    );

    final toml = config.toToml();

    // The raw injected line must NOT appear unescaped on its own line.
    expect(toml.contains('\nskip_verification = true\n'), isFalse);

    // The password line must keep the quote and newline escaped, neutralizing
    // the injection so it stays inside the password's quoted value.
    expect(
      toml.contains('password = "pa\\"ss\\nskip_verification = true"'),
      isTrue,
    );
  });
}

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

  test('toToml escapes injection in prefix, loglevel and upstream protocol',
      () {
    // The prefix is a free-text field; loglevel/upstream_protocol come from
    // dropdowns but importConfig accepts arbitrary strings from JSON files.
    final config = ServerConfig(
      hostname: 'vpn.example.com',
      address: '127.0.0.1',
      username: 'user',
      password: 'pw',
      clientRandomPrefix: 'aa"\nskip_verification = true',
      logLevel: 'info"\ninjected_a = 1',
      upstreamProtocol: 'http2"\ninjected_b = 2',
    );

    final toml = config.toToml();

    expect(toml, isNot(contains('\nskip_verification = true\n')));
    expect(toml, isNot(contains('\ninjected_a')));
    expect(toml, isNot(contains('\ninjected_b')));
    expect(
      toml,
      contains('client_random = "aa\\"\\nskip_verification = true"'),
    );
    expect(toml, contains('loglevel = "info\\"\\ninjected_a = 1"'));
    expect(toml, contains('upstream_protocol = "http2\\"\\ninjected_b = 2"'));
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/models/server_config.dart';

void main() {
  test('toToml writes the client random as the client field "client_random"', () {
    final cfg = ServerConfig(
      hostname: 'vpn.example.com',
      address: '127.0.0.1',
      username: 'u',
      password: 'p',
      clientRandomPrefix: 'deadbeef/aa55aa55',
    );
    final toml = cfg.toToml();
    // Client config field is `client_random` (NOT `client_random_prefix`,
    // which is the server rules.toml schema).
    expect(toml, contains('client_random = "deadbeef/aa55aa55"'));
    expect(toml, isNot(contains('client_random_prefix')));
  });

  test('clientRandomPrefix survives a json round-trip', () {
    final cfg = ServerConfig(
      hostname: 'h',
      address: 'a',
      username: 'u',
      password: 'p',
      clientRandomPrefix: 'abc123',
    );
    final back = ServerConfig.fromJson(cfg.toJson());
    expect(back.clientRandomPrefix, 'abc123');
  });
}

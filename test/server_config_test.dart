import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/models/server_config.dart';

void main() {
  test('toToml writes the client_random_prefix', () {
    final cfg = ServerConfig(
      hostname: 'vpn.example.com',
      address: '127.0.0.1',
      username: 'u',
      password: 'p',
      clientRandomPrefix: 'deadbeef',
    );
    expect(cfg.toToml(), contains('client_random_prefix = "deadbeef"'));
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

import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/models/server_setup_config.dart';

void main() {
  test('vpn.toml references rules_file only when filtering is enabled', () {
    final off = ServerSetupConfig(listenPort: 443);
    expect(off.generateVpnToml(), isNot(contains('rules_file')));

    final on = ServerSetupConfig(listenPort: 443, generateClientRandomPrefix: true);
    expect(
      on.generateVpnToml(),
      contains('rules_file = "/opt/trusttunnel/rules.toml"'),
    );
  });

  test('rules.toml allows the prefix then denies everyone else (order matters)', () {
    final c = ServerSetupConfig(
      generateClientRandomPrefix: true,
      clientRandomPrefix: 'deadbeef',
    );
    final toml = c.generateRulesToml();

    expect(toml, contains('client_random_prefix = "deadbeef"'));
    expect(toml, contains('action = "allow"'));
    expect(toml, contains('action = "deny"'));
    // Default action is allow, so the allow rule must precede the deny rule.
    expect(toml.indexOf('"allow"'), lessThan(toml.indexOf('"deny"')));
  });
}

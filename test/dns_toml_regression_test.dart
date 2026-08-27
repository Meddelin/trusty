import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/services/config_service.dart';

// Reproduces the exact stored state of a real 0.4.0 install (issue #12
// field report: CLI logged "User DNS servers are empty" despite app_dns
// being set) and asserts the generated TOML carries the DNS upstream.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadConfig + toToml keeps app_dns as a dns_upstreams entry', () async {
    SharedPreferences.setMockInitialValues({
      'server_config':
          '{"id":"srv1","name":"","hostname":"vpn.example.com","address":"203.0.113.10","port":8444,"hasIpv6":true,"username":"u","skipVerification":false,"upstreamProtocol":"http2","antiDpi":false,"dns":"8.8.8.8","logLevel":"info","customSni":"","postQuantumGroupEnabled":true,"connectionMode":"tun","socksPort":1080,"vpnMode":"general","splitTunnelDomains":["claude.ai"],"splitTunnelApps":[]}',
      'server_list':
          '[{"id":"srv1","name":"","hostname":"vpn.example.com","address":"203.0.113.10","port":8444,"hasIpv6":true,"username":"u","skipVerification":false,"upstreamProtocol":"http2","antiDpi":false,"customSni":"","postQuantumGroupEnabled":true}]',
      'active_server_id': 'srv1',
      'app_dns': '8.8.8.8',
      'app_log_level': 'info',
      'app_connection_mode': 'tun',
      'app_socks_port': 1080,
    });

    final service = ConfigService();
    final ServerConfig config = await service.loadConfig();

    expect(config.dns, '8.8.8.8');
    expect(config.dnsUpstreamList, ['8.8.8.8']);

    final toml = config.toToml();
    expect(toml, contains('dns_upstreams = ["8.8.8.8"]'));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/models/vpn_status.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/services/vpn_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed CLI launch removes the TOML with the plaintext password',
      () async {
    SharedPreferences.setMockInitialValues({});
    final tmp = Directory.systemTemp.createTempSync('trusty_vpn_test');
    final oldCwd = Directory.current;
    Directory.current = tmp;
    addTearDown(() {
      Directory.current = oldCwd;
      tmp.deleteSync(recursive: true);
    });

    // A dummy client binary that cannot be executed → Process.start throws
    // and connect() fails before any process exists.
    final clientDir = Directory(p.join(tmp.path, 'client'))..createSync();
    final exeName =
        Platform.isWindows ? 'trusttunnel_client.exe' : 'trusttunnel_client';
    File(p.join(clientDir.path, exeName)).writeAsStringSync('not a binary');

    final configService = ConfigService();
    final vpn = VpnService(configService);
    // SOCKS5 mode: no admin/TUN/Wintun handling on any platform, so the
    // launch attempt is reached directly.
    final config = ServerConfig(
      hostname: 'vpn.example.com',
      address: '127.0.0.1',
      username: 'user',
      password: 'secret-pw',
      connectionMode: 'socks5',
    );

    await vpn.connect(config);

    expect(vpn.status, VpnStatus.error);
    expect(
      File(p.join(clientDir.path, 'trusttunnel_client.toml')).existsSync(),
      isFalse,
      reason: 'the config file holds the plaintext password and must not '
          'outlive a failed launch',
    );
  });
}

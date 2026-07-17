import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/services/vpn_service.dart';

void main() {
  group('VpnService.sudoersUnsafeReason', () {
    test('rejects a path containing a single quote', () {
      expect(
        VpnService.sudoersUnsafeReason("/Users/bob's app/x"),
        isNotNull,
      );
    });

    test('accepts a normal absolute binary path', () {
      expect(
        VpnService.sudoersUnsafeReason(
            '/Applications/Trusty.app/Contents/MacOS/trusttunnel_client'),
        isNull,
      );
    });

    test('rejects shell metacharacters used for injection', () {
      expect(VpnService.sudoersUnsafeReason('a; rm -rf /'), isNotNull);
      expect(VpnService.sudoersUnsafeReason(r'a$(whoami)'), isNotNull);
    });

    test('rejects whitespace (unescaped spaces are invalid in sudoers)', () {
      expect(
        VpnService.sudoersUnsafeReason('/Applications/My App.app/bin'),
        contains('space'),
      );
      expect(VpnService.sudoersUnsafeReason('a\tb'), contains('tab'));
    });
  });
}

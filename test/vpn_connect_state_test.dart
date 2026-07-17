import 'package:flutter_test/flutter_test.dart';

import 'package:trusty/services/vpn_service.dart';

void main() {
  group('remainingAdapterWait', () {
    test('returns zero when no disconnect is pending', () {
      expect(
        VpnService.remainingAdapterWait(null, DateTime(2026, 6, 22, 12, 0, 0)),
        Duration.zero,
      );
    });

    test('returns zero when the busy window has already elapsed', () {
      final now = DateTime(2026, 6, 22, 12, 0, 10);
      final busyUntil = DateTime(2026, 6, 22, 12, 0, 5);
      expect(VpnService.remainingAdapterWait(busyUntil, now), Duration.zero);
    });

    test('returns the remaining time when still busy', () {
      final now = DateTime(2026, 6, 22, 12, 0, 0);
      final busyUntil = DateTime(2026, 6, 22, 12, 0, 3);
      expect(
        VpnService.remainingAdapterWait(busyUntil, now),
        const Duration(seconds: 3),
      );
    });

    test('is never negative right at the boundary', () {
      final t = DateTime(2026, 6, 22, 12, 0, 0);
      expect(VpnService.remainingAdapterWait(t, t), Duration.zero);
    });
  });

  group('isConnectedMarker', () {
    test('detects VPN_SS_CONNECTED anywhere in the line', () {
      expect(
        VpnService.isConnectedMarker('2026-06-22 INFO VPN_SS_CONNECTED tun up'),
        isTrue,
      );
    });

    test('detects "Successfully connected to endpoint"', () {
      expect(
        VpnService.isConnectedMarker('Successfully connected to endpoint 1.2.3.4'),
        isTrue,
      );
    });

    test('ignores unrelated log lines', () {
      expect(VpnService.isConnectedMarker('System DNS proxy request failed'), isFalse);
      expect(VpnService.isConnectedMarker('connecting...'), isFalse);
    });
  });
}

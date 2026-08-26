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

  group('classifyStartupFailure', () {
    test('detects a busy Wintun adapter on Windows in TUN mode', () {
      expect(
        VpnService.classifyStartupFailure(
          'error wintun adapter is already in use',
          windows: true,
          socksMode: false,
        ),
        StartupFailure.wintunBusy,
      );
    });

    test('detects access-denied on Windows in TUN mode', () {
      expect(
        VpnService.classifyStartupFailure(
          'createfile failed: access is denied',
          windows: true,
          socksMode: false,
        ),
        StartupFailure.accessDenied,
      );
      expect(
        VpnService.classifyStartupFailure(
          'failed with code 0x5',
          windows: true,
          socksMode: false,
        ),
        StartupFailure.accessDenied,
      );
    });

    test('access-denied wins over wintun-busy (matches the old order)', () {
      expect(
        VpnService.classifyStartupFailure(
          'wintun: access denied, adapter already exists',
          windows: true,
          socksMode: false,
        ),
        StartupFailure.accessDenied,
      );
    });

    test('SOCKS5 mode never reports TUN-specific failures', () {
      // Same log lines that would trigger admin/adapter hints in TUN mode.
      for (final logs in [
        'error wintun adapter is already in use',
        'createfile failed: access is denied',
      ]) {
        expect(
          VpnService.classifyStartupFailure(
            logs,
            windows: true,
            socksMode: true,
          ),
          StartupFailure.generic,
        );
      }
      expect(
        VpnService.classifyStartupFailure(
          'tun_open: operation not permitted',
          windows: false,
          socksMode: true,
        ),
        StartupFailure.generic,
      );
    });

    test('detects a lost TUN permission on macOS/Linux in TUN mode', () {
      expect(
        VpnService.classifyStartupFailure(
          'tun_open failed: (1) operation not permitted',
          windows: false,
          socksMode: false,
        ),
        StartupFailure.tunPermissionLost,
      );
    });

    test('unrelated logs are generic', () {
      expect(
        VpnService.classifyStartupFailure(
          'failed to ping location',
          windows: true,
          socksMode: false,
        ),
        StartupFailure.generic,
      );
      expect(
        VpnService.classifyStartupFailure(
          'failed to ping location',
          windows: false,
          socksMode: false,
        ),
        StartupFailure.generic,
      );
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

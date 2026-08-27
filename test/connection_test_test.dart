import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trusty/utils/connection_test.dart';

void main() {
  test('unreachable port reports a clear failure (no network needed)',
      () async {
    // Nothing listens on this loopback port → connection refused fast.
    final result = await testServerConnection(
      address: '127.0.0.1',
      port: 1,
      hostname: 'vpn.example.com',
      timeout: const Duration(seconds: 2),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('Cannot reach'));
  });

  test('TCP works but no TLS on the port → handshake failure', () async {
    // A plain TCP server that accepts the socket but never speaks TLS: the
    // TCP connect succeeds, the TLS handshake does not.
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((s) {/* accept, stay silent */});
    addTearDown(server.close);

    final result = await testServerConnection(
      address: '127.0.0.1',
      port: server.port,
      hostname: 'vpn.example.com',
      timeout: const Duration(seconds: 2),
    );
    expect(result.ok, isFalse);
    expect(result.message, contains('TLS handshake failed'));
  });

  group('connection filtering', () {
    test('a silent endpoint reads as filtering when a prefix is configured',
        () async {
      // A filtering server accepts the TCP connection, reads the ClientHello
      // and closes without a byte in reply — no TLS alert at all. Reproduce
      // that by accepting and immediately destroying.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) => socket.destroy());
      addTearDown(server.close);

      final filtered = await testServerConnection(
        address: server.address.address,
        port: server.port,
        hostname: 'vpn.example.com',
        hasFilteringPrefix: true,
        timeout: const Duration(seconds: 3),
      );
      expect(filtered.ok, isTrue, reason: 'a filtering server is not a fault');
      expect(filtered.filtered, isTrue);
      expect(filtered.message, contains('connection filtering'));

      // The same endpoint without a configured prefix is still a real failure:
      // nothing explains the silence.
      final plain = await testServerConnection(
        address: server.address.address,
        port: server.port,
        hostname: 'vpn.example.com',
        timeout: const Duration(seconds: 3),
      );
      expect(plain.ok, isFalse);
      expect(plain.filtered, isFalse);
    });
  });
}

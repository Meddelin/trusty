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
}

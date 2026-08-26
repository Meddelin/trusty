import 'dart:async';
import 'dart:io';

/// Outcome of a server reachability check.
class ConnectionTestResult {
  /// The host is reachable and completed a TLS handshake.
  final bool ok;

  /// The presented TLS certificate validated for the hostname. Only
  /// meaningful when [ok] is true.
  final bool certValid;

  final String message;

  const ConnectionTestResult(this.ok, this.certValid, this.message);
}

/// Lightweight reachability check for a server entry: TCP-connect to
/// address:port, then a TLS handshake with the hostname as SNI. Confirms the
/// host is reachable and speaks TLS on that port.
///
/// It does NOT verify VPN credentials — that needs the full TrustTunnel
/// handshake — but it catches the common configuration mistakes: wrong IP,
/// wrong port, firewall, no TLS listener, certificate mismatch.
Future<ConnectionTestResult> testServerConnection({
  required String address,
  required int port,
  required String hostname,
  Duration timeout = const Duration(seconds: 8),
}) async {
  Socket socket;
  try {
    socket = await Socket.connect(address, port, timeout: timeout);
  } on SocketException catch (e) {
    final reason = e.osError?.message ?? e.message;
    return ConnectionTestResult(
        false, false, 'Cannot reach $address:$port — $reason');
  } catch (e) {
    return ConnectionTestResult(
        false, false, 'Cannot reach $address:$port — $e');
  }

  var certValid = true;
  try {
    final secure = await SecureSocket.secure(
      socket,
      // SNI/validation host: the hostname (so an IP-addressed endpoint still
      // presents the right certificate), falling back to the address.
      host: hostname.isNotEmpty ? hostname : address,
      onBadCertificate: (_) {
        certValid = false;
        return true; // continue the handshake; we report validity separately
      },
    ).timeout(timeout);
    await secure.close();
  } catch (e) {
    socket.destroy();
    return ConnectionTestResult(
        false, false, 'Reached $address:$port but the TLS handshake failed — $e');
  }

  if (certValid) {
    return ConnectionTestResult(true, true,
        'Success — $address:$port is reachable and completed a TLS handshake.');
  }
  return ConnectionTestResult(
      true,
      false,
      'Reachable, but the TLS certificate is not valid for "$hostname". '
      'That is expected only if this server uses "skip certificate verification".');
}

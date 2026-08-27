import 'dart:async';
import 'dart:io';

/// Outcome of a server reachability check.
class ConnectionTestResult {
  /// The host is reachable and behaved as expected for this server entry.
  final bool ok;

  /// The presented TLS certificate validated for the hostname. Only
  /// meaningful when the handshake actually completed, i.e. [ok] is true and
  /// [filtered] is false.
  final bool certValid;

  /// The endpoint accepted the connection and then answered an unmarked
  /// handshake with nothing at all — the signature of connection filtering.
  /// Not a fault: it is what the filter is for.
  final bool filtered;

  final String message;

  const ConnectionTestResult(
    this.ok,
    this.certValid,
    this.message, {
    this.filtered = false,
  });
}

/// Lightweight reachability check for a server entry: TCP-connect to
/// address:port, then a TLS handshake with the hostname as SNI. Confirms the
/// host is reachable and speaks TLS on that port.
///
/// It does NOT verify VPN credentials — that needs the full TrustTunnel
/// handshake — but it catches the common configuration mistakes: wrong IP,
/// wrong port, firewall, no TLS listener, certificate mismatch.
///
/// Pass [hasFilteringPrefix] when the server entry carries a client random
/// prefix. Such a server answers only handshakes marked with it, and this
/// probe is deliberately unmarked: the endpoint reads the ClientHello and
/// closes without a single byte in reply, not even a TLS alert. Reporting
/// that as a failure would cry wolf on the most locked-down setup there is,
/// so it is reported as reachable-and-filtering instead.
Future<ConnectionTestResult> testServerConnection({
  required String address,
  required int port,
  required String hostname,
  bool hasFilteringPrefix = false,
  Duration timeout = const Duration(seconds: 8),
}) async {
  Socket socket;
  try {
    socket = await Socket.connect(address, port, timeout: timeout);
  } on SocketException catch (e) {
    final reason = e.osError?.message ?? e.message;
    return ConnectionTestResult(
        false, false, 'Cannot reach $address:$port ($reason)');
  } catch (e) {
    return ConnectionTestResult(
        false, false, 'Cannot reach $address:$port ($e)');
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
    if (hasFilteringPrefix) {
      return ConnectionTestResult(
        true,
        false,
        'Reached $address:$port. The server ignored an unmarked handshake, '
        'which is what connection filtering does. Your client sends the '
        'prefix, this check cannot.',
        filtered: true,
      );
    }
    return ConnectionTestResult(
        false, false, 'Reached $address:$port but the TLS handshake failed ($e)');
  }

  if (certValid) {
    return ConnectionTestResult(true, true,
        'Success: $address:$port is reachable and completed a TLS handshake.');
  }
  return ConnectionTestResult(
      true,
      false,
      'Reachable, but the TLS certificate is not valid for "$hostname". '
      'That is expected only if this server uses "skip certificate verification".');
}

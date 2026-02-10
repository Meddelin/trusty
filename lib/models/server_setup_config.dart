/// Configuration for remote server setup via SSH
class ServerSetupConfig {
  // SSH connection
  String host;
  int sshPort;
  String sshUsername;
  String sshPassword;
  String? sshKeyPath;
  bool useKeyAuth;

  // Server / TLS
  String domain;
  String email;
  int listenPort;

  // VPN account
  String vpnUsername;
  String vpnPassword;

  ServerSetupConfig({
    this.host = '',
    this.sshPort = 22,
    this.sshUsername = 'root',
    this.sshPassword = '',
    this.sshKeyPath,
    this.useKeyAuth = false,
    this.domain = '',
    this.email = '',
    this.listenPort = 443,
    this.vpnUsername = '',
    this.vpnPassword = '',
  });

  /// Serialize non-sensitive fields for persistence
  Map<String, dynamic> toJson() {
    return {
      'host': host,
      'sshPort': sshPort,
      'sshUsername': sshUsername,
      'useKeyAuth': useKeyAuth,
      'sshKeyPath': sshKeyPath,
      'domain': domain,
      'email': email,
      'listenPort': listenPort,
      'vpnUsername': vpnUsername,
      // Passwords are NOT saved
    };
  }

  factory ServerSetupConfig.fromJson(Map<String, dynamic> json) {
    return ServerSetupConfig(
      host: json['host'] as String? ?? '',
      sshPort: json['sshPort'] as int? ?? 22,
      sshUsername: json['sshUsername'] as String? ?? 'root',
      useKeyAuth: json['useKeyAuth'] as bool? ?? false,
      sshKeyPath: json['sshKeyPath'] as String?,
      domain: json['domain'] as String? ?? '',
      email: json['email'] as String? ?? '',
      listenPort: json['listenPort'] as int? ?? 443,
      vpnUsername: json['vpnUsername'] as String? ?? '',
    );
  }

  /// Generate vpn.toml content
  String generateVpnToml() {
    return 'listen_address = "0.0.0.0:$listenPort"\n'
        'credentials_file = "/opt/trusttunnel/credentials.toml"\n';
  }

  /// Generate credentials.toml content
  String generateCredentialsToml() {
    return '[[client]]\n'
        'username = "$vpnUsername"\n'
        'password = "$vpnPassword"\n';
  }

  /// Generate hosts.toml content
  String generateHostsToml() {
    return '[[main_hosts]]\n'
        'hostname = "$domain"\n'
        'cert_chain_path = "/etc/letsencrypt/live/$domain/fullchain.pem"\n'
        'private_key_path = "/etc/letsencrypt/live/$domain/privkey.pem"\n';
  }
}

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

  // Connection filtering: generate a TLS client_random_prefix, allow only
  // clients that send it (deny everyone else). [clientRandomPrefix] is filled
  // in by the installer and carried over to the client config.
  bool generateClientRandomPrefix;
  String clientRandomPrefix;

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
    this.generateClientRandomPrefix = false,
    this.clientRandomPrefix = '',
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
      'generateClientRandomPrefix': generateClientRandomPrefix,
      // Passwords and the generated prefix are NOT saved
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
      generateClientRandomPrefix:
          json['generateClientRandomPrefix'] as bool? ?? false,
    );
  }

  /// Generate vpn.toml content
  String generateVpnToml() {
    final rules = generateClientRandomPrefix
        ? 'rules_file = "/opt/trusttunnel/rules.toml"\n'
        : '';
    return 'listen_address = "0.0.0.0:$listenPort"\n'
        'credentials_file = "/opt/trusttunnel/credentials.toml"\n'
        '$rules'
        '\n'
        '[listen_protocols.http1]\n'
        '[listen_protocols.http2]\n'
        '[listen_protocols.quic]\n';
  }

  /// Generate rules.toml content for client_random_prefix filtering.
  /// Rules are evaluated in order and the default action is allow, so the
  /// trailing deny blocks everyone who doesn't send the matching prefix.
  String generateRulesToml() {
    return '# Allow only clients sending the matching TLS client random\n'
        '# prefix; deny everyone else (probes, scanners).\n'
        '[[rule]]\n'
        'client_random_prefix = "$clientRandomPrefix"\n'
        'action = "allow"\n\n'
        '[[rule]]\n'
        'action = "deny"\n';
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

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

  /// Escape a string for safe inclusion inside a TOML basic string ("...").
  /// Prevents injection of config keys or breaking the TOML structure
  /// when an interpolated value contains quotes, backslashes or newlines.
  String _tomlEscape(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  /// Validate user-controlled fields before they are interpolated into shell
  /// commands run as root over SSH. Returns an error message, or null if OK.
  ///
  /// This is the primary mitigation for command injection via `domain`/`email`:
  /// `domain` must be a valid hostname and `email` a simple address, and
  /// neither may contain shell metacharacters (belt-and-suspenders check).
  String? validateForInstall() {
    // Reject any shell metacharacter outright as a defense-in-depth check.
    final shellMeta = RegExp(r'''[;&|`$(){}<>\\'"\s*?\[\]!#~]''');

    final d = domain.trim();
    if (d.isEmpty) {
      return 'Domain cannot be empty.';
    }
    if (d.length > 253) {
      return 'Domain is too long.';
    }
    if (shellMeta.hasMatch(d)) {
      return 'Domain contains invalid characters.';
    }
    // Hostname: dot-separated labels of 1-63 chars, alphanumeric with
    // internal hyphens, no leading/trailing dot or hyphen.
    final hostnameRegex = RegExp(
        r'^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$');
    if (!hostnameRegex.hasMatch(d)) {
      return 'Invalid domain: $domain';
    }

    final e = email.trim();
    if (e.isEmpty) {
      return 'Email cannot be empty.';
    }
    if (e.length > 254) {
      return 'Email is too long.';
    }
    if (shellMeta.hasMatch(e)) {
      return 'Email contains invalid characters.';
    }
    // Simple, conservative email check.
    final emailRegex = RegExp(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$');
    if (!emailRegex.hasMatch(e)) {
      return 'Invalid email: $email';
    }

    return null;
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
        'username = "${_tomlEscape(vpnUsername)}"\n'
        'password = "${_tomlEscape(vpnPassword)}"\n';
  }

  /// Generate hosts.toml content
  String generateHostsToml() {
    final d = _tomlEscape(domain);
    return '[[main_hosts]]\n'
        'hostname = "$d"\n'
        'cert_chain_path = "/etc/letsencrypt/live/$d/fullchain.pem"\n'
        'private_key_path = "/etc/letsencrypt/live/$d/privkey.pem"\n';
  }
}

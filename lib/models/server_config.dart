/// VPN mode for split tunneling
enum VpnMode {
  /// Route all traffic through VPN except exclusions
  general,
  /// Route only specified traffic through VPN
  selective,
}

/// Server configuration model for Trusty VPN
class ServerConfig {
  /// Stable identity of the server entry in the saved server list.
  /// Empty only for transient objects; assigned on save/migration.
  final String id;

  /// Optional user-given display name; [displayLabel] falls back to hostname.
  final String name;
  final String hostname;
  final String address;
  final int port;
  final bool hasIpv6;
  final String username;
  final String password;
  final bool skipVerification;
  final String upstreamProtocol;
  final bool antiDpi;
  final String dns;
  final String logLevel;
  final String customSni;
  final String clientRandomPrefix;
  final bool postQuantumGroupEnabled;

  /// App-global (like [dns]/[logLevel]): 'tun' (full-system VPN through a
  /// virtual adapter) or 'socks5' (local proxy, no adapter/wintun needed).
  final String connectionMode;

  /// Local SOCKS5 proxy port; the listener binds to 127.0.0.1 only.
  final int socksPort;

  // Split tunneling settings
  final VpnMode vpnMode;
  final List<String> splitTunnelDomains;
  final List<String> splitTunnelApps;

  ServerConfig({
    this.id = '',
    this.name = '',
    required this.hostname,
    required this.address,
    this.port = 443,
    this.hasIpv6 = true,
    required this.username,
    required this.password,
    this.skipVerification = false,
    this.upstreamProtocol = 'http2',
    this.antiDpi = false,
    this.dns = '8.8.8.8',
    this.logLevel = 'info',
    this.customSni = '',
    this.clientRandomPrefix = '',
    this.postQuantumGroupEnabled = true,
    this.connectionMode = 'tun',
    this.socksPort = 1080,
    this.vpnMode = VpnMode.general,
    this.splitTunnelDomains = const [],
    this.splitTunnelApps = const [],
  });

  /// Default configuration with placeholder values
  /// Users must configure their own server details
  factory ServerConfig.defaultConfig() {
    return ServerConfig(
      hostname: 'vpn.example.com',
      address: '127.0.0.1',
      port: 443,
      hasIpv6: true,
      username: 'your-username',
      password: '',
      skipVerification: false,
      upstreamProtocol: 'http2',
      antiDpi: false,
      dns: '8.8.8.8',
      logLevel: 'info',
      customSni: '',
      clientRandomPrefix: '',
      postQuantumGroupEnabled: true,
      vpnMode: VpnMode.general,
      splitTunnelDomains: [],
      splitTunnelApps: [],
    );
  }

  /// Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'hostname': hostname,
      'address': address,
      'port': port,
      'hasIpv6': hasIpv6,
      'username': username,
      'password': password,
      'skipVerification': skipVerification,
      'upstreamProtocol': upstreamProtocol,
      'antiDpi': antiDpi,
      'dns': dns,
      'logLevel': logLevel,
      'customSni': customSni,
      'clientRandomPrefix': clientRandomPrefix,
      'postQuantumGroupEnabled': postQuantumGroupEnabled,
      'connectionMode': connectionMode,
      'socksPort': socksPort,
      'vpnMode': vpnMode.name,
      'splitTunnelDomains': splitTunnelDomains,
      'splitTunnelApps': splitTunnelApps,
    };
  }

  /// Create from JSON
  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    // Ensure non-null strings with proper fallbacks
    final hostname = json['hostname'] as String? ?? 'vpn.example.com';
    final address = json['address'] as String? ?? '127.0.0.1';
    final username = json['username'] as String? ?? 'your-username';
    final password = json['password'] as String? ?? '';
    final upstreamProtocol = json['upstreamProtocol'] as String? ?? 'http2';
    final dns = json['dns'] as String? ?? '8.8.8.8';
    final logLevel = json['logLevel'] as String? ?? 'info';
    final customSni = json['customSni'] as String? ?? '';
    final clientRandomPrefix = json['clientRandomPrefix'] as String? ?? '';
    final postQuantumGroupEnabled = json['postQuantumGroupEnabled'] as bool? ?? true;

    return ServerConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      hostname: hostname,
      address: address,
      port: json['port'] as int? ?? 443,
      hasIpv6: json['hasIpv6'] as bool? ?? true,
      username: username,
      password: password,
      skipVerification: json['skipVerification'] as bool? ?? false,
      upstreamProtocol: upstreamProtocol,
      antiDpi: json['antiDpi'] as bool? ?? false,
      dns: dns,
      logLevel: logLevel,
      customSni: customSni,
      clientRandomPrefix: clientRandomPrefix,
      postQuantumGroupEnabled: postQuantumGroupEnabled,
      // Unknown values (and absent keys, i.e. pre-0.4.0 configs) mean TUN.
      connectionMode:
          json['connectionMode'] == 'socks5' ? 'socks5' : 'tun',
      socksPort: json['socksPort'] as int? ?? 1080,
      vpnMode: VpnMode.values.firstWhere(
        (e) => e.name == json['vpnMode'],
        orElse: () => VpnMode.general,
      ),
      splitTunnelDomains: (json['splitTunnelDomains'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ?? [],
      splitTunnelApps: (json['splitTunnelApps'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ?? [],
    );
  }

  /// Escape a string for safe inclusion inside a TOML basic string ("...").
  /// Prevents injection of config keys or breaking the TOML structure.
  String _tomlEscape(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t');
  }

  /// Generate TOML config file content
  String toToml() {
    // Validate critical fields - ensure they're not null or empty.
    // Escape values for safe inclusion in TOML basic strings.
    final h = _tomlEscape(hostname);
    final a = _tomlEscape(address);
    final u = _tomlEscape(username);

    if (hostname.isEmpty) {
      throw Exception('Hostname cannot be empty');
    }
    if (address.isEmpty) {
      throw Exception('Address cannot be empty');
    }
    if (username.isEmpty) {
      throw Exception('Username cannot be empty');
    }
    if (isSocksMode && (socksPort < 1 || socksPort > 65535)) {
      throw Exception('SOCKS5 port must be between 1 and 65535');
    }

    // Generate DNS upstreams list. The field accepts several upstreams
    // separated by commas/whitespace (e.g. plain IP + DoH fallback).
    final upstreams = dnsUpstreamList;
    final dnsUpstreams = upstreams.isEmpty
        ? '[]'
        : '[${upstreams.map((u) => '"${_tomlEscape(u)}"').join(', ')}]';

    // Generate exclusions list from domains and apps
    final domains = splitTunnelDomains;
    final apps = splitTunnelApps;
    final allExclusions = [...domains, ...apps];
    final exclusionsStr = allExclusions.isEmpty
        ? '[]'
        : '[\n${allExclusions.map((e) => '  "${_tomlEscape(e)}"').join(',\n')}\n]';

    // Safe access to all fields. Every interpolated string goes through
    // _tomlEscape — loglevel/upstream_protocol come from dropdowns in the UI
    // but importConfig accepts arbitrary strings, and the prefix is a
    // free-text field.
    final ll = _tomlEscape(logLevel);
    final vm = vpnMode.name;
    final p = port;
    final ipv6 = hasIpv6;
    final pwd = _tomlEscape(password);
    final skipVerif = skipVerification;
    final upProto = _tomlEscape(upstreamProtocol);
    final dpi = antiDpi;
    final crp = _tomlEscape(clientRandomPrefix);
    final pqg = postQuantumGroupEnabled;

    // Exactly one listener table may be present — the CLI rejects configs
    // that specify both [listener.tun] and [listener.socks].
    // (The first line after ''' is a deliberate blank: Dart strips the
    // newline right after the opening quotes.)
    final listenerSection = isSocksMode
        ? '''

[listener.socks]
# IP address and port to bind the SOCKS5 proxy.
# Loopback only: the proxy is never reachable from other machines.
address = "$socksProxyAddress"
'''
        : '''

[listener.tun]
# Name of the interface used for connections made by the VPN client.
# On Linux and Windows, it is detected automatically if not specified.
# On macOS, it defaults to `en0` if not specified.
# On Windows, an interface index as shown by `route print`, written as a string, may be used instead of a name.
bound_if = ""
# Routes in CIDR notation to set to the virtual interface
included_routes = ["0.0.0.0/0", "2000::/3"]
# Routes in CIDR notation to exclude from routing through the virtual interface
excluded_routes = ["0.0.0.0/8", "10.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3"]
# MTU size on the interface
mtu_size = 1280
# Allow changing system DNS servers
change_system_dns = true
''';

    return '''# Logging level [info, debug, trace]
loglevel = "$ll"

# VPN mode.
# Defines client connections routing policy:
# * general: route through a VPN endpoint all connections except ones which destinations are in exclusions,
# * selective: route through a VPN endpoint only the connections which destinations are in exclusions.
vpn_mode = "$vm"

# When disabled, all connection requests are routed directly to target hosts
# in case connection to VPN endpoint is lost. This helps not to break an
# Internet connection if user has poor connectivity to an endpoint.
# When enabled, incoming connection requests which should be routed through
# an endpoint will not be routed directly in that case.
killswitch_enabled = true

# When the kill switch is enabled, on platforms where inbound connections are blocked by the
# kill switch, allow inbound connections to these local ports. An array of integers.
killswitch_allow_ports = []

# When enabled, a post-quantum group may be used for key exchange
# in TLS handshakes initiated by the VPN client.
post_quantum_group_enabled = $pqg

# Domains and addresses which should be routed in a special manner.
# Supported syntax:
#   * domain name
#   * ip address
#   * CIDR range
#   * process name (e.g., chrome.exe)
exclusions = $exclusionsStr

# DNS upstreams.
# If specified, the library intercepts and routes plain DNS queries
# going through the endpoint to the DNS resolvers.
# One of the following kinds:
#   * 8.8.8.8:53 -- plain DNS
#   * tcp://8.8.8.8:53 -- plain DNS over TCP
#   * tls://1.1.1.1 -- DNS-over-TLS
#   * https://dns.adguard.com/dns-query -- DNS-over-HTTPS
#   * sdns://... -- DNS stamp (see https://dnscrypt.info/stamps-specifications)
#   * quic://dns.adguard.com:8853 -- DNS-over-QUIC
dns_upstreams = $dnsUpstreams

# The set of endpoint connection settings
[endpoint]
# Endpoint host name, used for TLS session establishment
hostname = "$h"
# Endpoint addresses.
# The exact address is selected by the pinger. Absence of IPv6 addresses in
# the list makes the VPN client reject IPv6 connections which must be routed
# through the endpoint with unreachable code.
addresses = ["$a:$p"]
# Whether IPv6 traffic can be routed through the endpoint
has_ipv6 = $ipv6
# Username for authorization
username = "$u"
# Password for authorization
password = "$pwd"
# TLS client random prefix and mask (hex, format: prefix[/mask])
client_random = "$crp"
# Skip the endpoint certificate verification?
# That is, any certificate is accepted with this one set to true.
skip_verification = $skipVerif
# Endpoint certificate in PEM format.
# If not specified, the endpoint certificate is verified using the system storage.
certificate = ""
# Protocol to be used to communicate with the endpoint [http2, http3]
upstream_protocol = "$upProto"
# Is anti-DPI measures should be enabled
anti_dpi = $dpi
# Custom SNI value for TLS handshake (leave empty to use hostname)
custom_sni = "${_tomlEscape(customSni)}"


# Defines the way to listen to network traffic by the kind of the nested table.
# Possible types:
#   * socks: SOCKS5 proxy with UDP support,
#   * tun: TUN device.
[listener]
$listenerSection''';
  }

  /// What lists and dropdowns show for this server.
  String get displayLabel => name.isNotEmpty ? name : hostname;

  /// True while the config still carries the factory placeholder values —
  /// connecting with these would "succeed" against 127.0.0.1 and show a
  /// green circle with no tunnel.
  bool get isPlaceholder =>
      hostname == 'vpn.example.com' || username == 'your-username';

  /// DNS upstreams parsed from the [dns] field (comma/whitespace separated).
  List<String> get dnsUpstreamList => dns
      .split(RegExp(r'[\s,]+'))
      .where((s) => s.isNotEmpty)
      .toList();

  bool get isSocksMode => connectionMode == 'socks5';

  /// Where the SOCKS5 listener binds (and what apps must be pointed at).
  String get socksProxyAddress => '127.0.0.1:$socksPort';

  /// Create a copy with updated fields
  ServerConfig copyWith({
    String? id,
    String? name,
    String? hostname,
    String? address,
    int? port,
    bool? hasIpv6,
    String? username,
    String? password,
    bool? skipVerification,
    String? upstreamProtocol,
    bool? antiDpi,
    String? dns,
    String? logLevel,
    String? customSni,
    String? clientRandomPrefix,
    bool? postQuantumGroupEnabled,
    String? connectionMode,
    int? socksPort,
    VpnMode? vpnMode,
    List<String>? splitTunnelDomains,
    List<String>? splitTunnelApps,
  }) {
    return ServerConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      hostname: hostname ?? this.hostname,
      address: address ?? this.address,
      port: port ?? this.port,
      hasIpv6: hasIpv6 ?? this.hasIpv6,
      username: username ?? this.username,
      password: password ?? this.password,
      skipVerification: skipVerification ?? this.skipVerification,
      upstreamProtocol: upstreamProtocol ?? this.upstreamProtocol,
      antiDpi: antiDpi ?? this.antiDpi,
      dns: dns ?? this.dns,
      logLevel: logLevel ?? this.logLevel,
      customSni: customSni ?? this.customSni,
      clientRandomPrefix: clientRandomPrefix ?? this.clientRandomPrefix,
      postQuantumGroupEnabled: postQuantumGroupEnabled ?? this.postQuantumGroupEnabled,
      connectionMode: connectionMode ?? this.connectionMode,
      socksPort: socksPort ?? this.socksPort,
      vpnMode: vpnMode ?? this.vpnMode,
      splitTunnelDomains: splitTunnelDomains ?? this.splitTunnelDomains,
      splitTunnelApps: splitTunnelApps ?? this.splitTunnelApps,
    );
  }
}

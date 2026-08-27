import 'server_config.dart';

/// A ready-made routing list: a set of domains/IPs/CIDRs merged into the
/// exclusions at connect time. Sources: the built-in "blocked in Russia"
/// preset, a user-added URL (GitHub raw etc., auto-updating), or a local
/// file. Entries are cached in `client/routing_lists/<id>.lst`.
class RoutingList {
  final String id;
  final String name;

  /// 'builtin' | 'url' | 'file'
  final String type;

  /// Source URLs for builtin/url lists (several are allowed and merged).
  final List<String> urls;

  /// Source path for file lists.
  final String sourcePath;

  /// Source format: 'plain' (one domain/IP/CIDR per line), 'geosite'
  /// (v2fly domain-list-community category) or 'geoip' (v2fly per-country
  /// CIDR list, line-wise identical to plain). Lists saved before formats
  /// existed have no stored value and default to 'plain'.
  final String format;

  final bool enabled;

  /// Which VPN mode the list applies in: 'selective' | 'general' | 'both'.
  /// In selective mode entries are routed THROUGH the VPN; in general mode
  /// they BYPASS it — a list usually only makes sense in one of them.
  final String appliesTo;

  /// ISO-8601 timestamp of the last successful refresh ('' = never).
  final String lastUpdatedIso;
  final int entryCount;

  /// Human-readable reason of the last refresh failure ('' = none).
  final String lastError;

  const RoutingList({
    required this.id,
    required this.name,
    required this.type,
    this.urls = const [],
    this.sourcePath = '',
    this.format = 'plain',
    this.enabled = false,
    this.appliesTo = 'selective',
    this.lastUpdatedIso = '',
    this.entryCount = 0,
    this.lastError = '',
  });

  bool get isBuiltin => type == 'builtin';

  DateTime? get lastUpdated => DateTime.tryParse(lastUpdatedIso);

  bool matchesMode(VpnMode mode) =>
      appliesTo == 'both' || appliesTo == mode.name;

  factory RoutingList.fromJson(Map<String, dynamic> json) {
    return RoutingList(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'url',
      urls: (json['urls'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      sourcePath: json['sourcePath'] as String? ?? '',
      format: json['format'] as String? ?? 'plain',
      enabled: json['enabled'] as bool? ?? false,
      appliesTo: json['appliesTo'] as String? ?? 'selective',
      lastUpdatedIso: json['lastUpdatedIso'] as String? ?? '',
      entryCount: json['entryCount'] as int? ?? 0,
      lastError: json['lastError'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'urls': urls,
        'sourcePath': sourcePath,
        'format': format,
        'enabled': enabled,
        'appliesTo': appliesTo,
        'lastUpdatedIso': lastUpdatedIso,
        'entryCount': entryCount,
        'lastError': lastError,
      };

  RoutingList copyWith({
    String? name,
    bool? enabled,
    String? appliesTo,
    String? lastUpdatedIso,
    int? entryCount,
    String? lastError,
  }) {
    return RoutingList(
      id: id,
      name: name ?? this.name,
      type: type,
      urls: urls,
      sourcePath: sourcePath,
      format: format,
      enabled: enabled ?? this.enabled,
      appliesTo: appliesTo ?? this.appliesTo,
      lastUpdatedIso: lastUpdatedIso ?? this.lastUpdatedIso,
      entryCount: entryCount ?? this.entryCount,
      lastError: lastError ?? this.lastError,
    );
  }
}

/// A curated catalog entry for the add-list dialog: a ready source URL and
/// format, so common lists are one pick instead of a hunt for raw URLs.
class RoutingPreset {
  final String name;

  /// Most presets are a single source; a few merge several.
  final List<String> urls;

  /// 'plain' | 'geosite' | 'geoip' (see [RoutingList.format]).
  final String format;

  RoutingPreset(this.name, String url, this.format) : urls = [url];

  RoutingPreset.multi(this.name, this.urls, this.format);
}

const String _geositeBase =
    'https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/';
const String _geoipBase =
    'https://raw.githubusercontent.com/v2fly/geoip/release/text/';

/// Presets offered by the add-list dialog: the maintained "blocked in Russia"
/// set, v2fly community domain categories, and per-country IP blocks. Nothing
/// is added for you — a fresh install starts with no routing lists at all.
final List<RoutingPreset> routingPresets = [
  RoutingPreset.multi(
    'Sites blocked in Russia',
    [
      'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst',
      'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/telegram.lst',
      'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/discord.lst',
    ],
    'plain',
  ),
  RoutingPreset('YouTube', '${_geositeBase}youtube', 'geosite'),
  RoutingPreset('Discord', '${_geositeBase}discord', 'geosite'),
  RoutingPreset('Meta (Facebook / Instagram)', '${_geositeBase}meta', 'geosite'),
  RoutingPreset('Telegram', '${_geositeBase}telegram', 'geosite'),
  RoutingPreset('Twitter / X', '${_geositeBase}twitter', 'geosite'),
  RoutingPreset('Netflix', '${_geositeBase}netflix', 'geosite'),
  RoutingPreset('OpenAI', '${_geositeBase}openai', 'geosite'),
  RoutingPreset('Google', '${_geositeBase}google', 'geosite'),
  RoutingPreset('Russia (IP ranges)', '${_geoipBase}ru.txt', 'geoip'),
  RoutingPreset('Ukraine (IP ranges)', '${_geoipBase}ua.txt', 'geoip'),
  RoutingPreset('United States (IP ranges)', '${_geoipBase}us.txt', 'geoip'),
  RoutingPreset('Netherlands (IP ranges)', '${_geoipBase}nl.txt', 'geoip'),
  RoutingPreset('Germany (IP ranges)', '${_geoipBase}de.txt', 'geoip'),
];

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
      enabled: enabled ?? this.enabled,
      appliesTo: appliesTo ?? this.appliesTo,
      lastUpdatedIso: lastUpdatedIso ?? this.lastUpdatedIso,
      entryCount: entryCount ?? this.entryCount,
      lastError: lastError ?? this.lastError,
    );
  }
}

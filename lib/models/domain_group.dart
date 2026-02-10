/// A named group of related domains for split tunneling
class DomainGroup {
  final String id;
  final String name;
  final String primaryDomain;
  final List<String> domains;

  DomainGroup({
    required this.id,
    required this.name,
    required this.primaryDomain,
    required this.domains,
  });

  factory DomainGroup.fromJson(Map<String, dynamic> json) {
    return DomainGroup(
      id: json['id'] as String,
      name: json['name'] as String,
      primaryDomain: json['primaryDomain'] as String,
      domains: List<String>.from(json['domains'] ?? []),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'primaryDomain': primaryDomain,
      'domains': domains,
    };
  }

  DomainGroup copyWith({
    String? id,
    String? name,
    String? primaryDomain,
    List<String>? domains,
  }) {
    return DomainGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      primaryDomain: primaryDomain ?? this.primaryDomain,
      domains: domains ?? this.domains,
    );
  }
}

/// Container for all domain groups and standalone domains
class DomainGroupsData {
  static const int currentVersion = 1;

  final int version;
  final List<DomainGroup> groups;
  final List<String> standaloneDomains;

  DomainGroupsData({
    this.version = currentVersion,
    this.groups = const [],
    this.standaloneDomains = const [],
  });

  factory DomainGroupsData.fromJson(Map<String, dynamic> json) {
    return DomainGroupsData(
      version: json['version'] ?? currentVersion,
      groups: (json['groups'] as List<dynamic>?)
              ?.map((g) => DomainGroup.fromJson(g as Map<String, dynamic>))
              .toList() ??
          [],
      standaloneDomains:
          List<String>.from(json['standaloneDomains'] ?? []),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'groups': groups.map((g) => g.toJson()).toList(),
      'standaloneDomains': standaloneDomains,
    };
  }

  /// Flatten all domains from groups and standalone into a single list
  List<String> flattenDomains() {
    final all = <String>{};
    for (final group in groups) {
      all.addAll(group.domains);
    }
    all.addAll(standaloneDomains);
    return all.toList();
  }

  DomainGroupsData copyWith({
    int? version,
    List<DomainGroup>? groups,
    List<String>? standaloneDomains,
  }) {
    return DomainGroupsData(
      version: version ?? this.version,
      groups: groups ?? this.groups,
      standaloneDomains: standaloneDomains ?? this.standaloneDomains,
    );
  }
}

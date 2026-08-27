import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/domain_group.dart';
import 'package:trusty/models/routing_list.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/utils/exclusion_parser.dart';

/// Performance guardrails for large lists. A real user pastes ~1000 domains;
/// geosite/geoip presets bring tens of thousands of entries. Each test checks
/// BOTH correctness and wall time. Time bounds are 10–50x the expected cost
/// on a developer machine so they never flap on slow CI — they only catch
/// accidental quadratic behavior, which overshoots by orders of magnitude.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const timeout = Timeout(Duration(minutes: 3));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Point Directory.current (the base of the routing list cache) at a fresh
  /// temp dir for tests that touch cache files.
  Directory useTempCwd() {
    final tmp = Directory.systemTemp.createTempSync('trusty_perf_test');
    final oldCwd = Directory.current;
    Directory.current = tmp;
    addTearDown(() {
      Directory.current = oldCwd;
      tmp.deleteSync(recursive: true);
    });
    return tmp;
  }

  /// A ConfigService that hard-fails on any network access — perf tests must
  /// run fully offline.
  ConfigService offlineService() => ConfigService(
      fetchUrl: (url) async =>
          throw StateError('network disabled in test: $url'));

  Duration timed(void Function() body) {
    final sw = Stopwatch()..start();
    body();
    return sw.elapsed;
  }

  Future<Duration> timedAsync(Future<void> Function() body) async {
    final sw = Stopwatch()..start();
    await body();
    return sw.elapsed;
  }

  /// Reverse of ServerConfig._tomlEscape for verifying the generated TOML.
  String tomlUnescape(String s) {
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c != r'\') {
        out.write(c);
        continue;
      }
      i++;
      switch (s[i]) {
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        default:
          out.write(s[i]); // \\ and \"
      }
    }
    return out.toString();
  }

  /// Entries of the `exclusions = [...]` block of a generated TOML.
  List<String> tomlExclusionLines(String toml) {
    final start = toml.indexOf('exclusions = [');
    expect(start, greaterThanOrEqualTo(0));
    final end = toml.indexOf('\n]', start);
    expect(end, greaterThan(start));
    final block = toml.substring(start + 'exclusions = [\n'.length, end);
    return block.split(',\n');
  }

  // ── 1. TOML generation ───────────────────────────────────────────────────

  test('toToml with 50k mixed exclusions stays fast and lossless', () {
    // 20k ASCII domains + 10k unicode domains + 10k CIDRs + 5k IPs as
    // domains, 5k process names (with quotes/backslashes) as apps.
    final domains = <String>[
      for (var i = 0; i < 20000; i++) 'svc$i.example.com',
      for (var i = 0; i < 10000; i++) 'сайт$i.пример.рф',
      for (var i = 0; i < 10000; i++) '10.${(i >> 8) & 255}.${i & 255}.0/24',
      for (var i = 0; i < 5000; i++) '192.${(i >> 8) & 255}.${i & 255}.7',
    ];
    final apps = <String>[
      for (var i = 0; i < 5000; i++) 'dir\\my "game" $i.exe',
    ];
    final config = ServerConfig.defaultConfig().copyWith(
      splitTunnelDomains: domains,
      splitTunnelApps: apps,
    );

    late String toml;
    final elapsed = timed(() => toml = config.toToml());
    expect(elapsed, lessThan(const Duration(seconds: 10)),
        reason: 'toToml over 50k exclusions must stay roughly linear');

    final lines = tomlExclusionLines(toml);
    expect(lines, hasLength(50000));

    // Escaping must hold for every line: two-space indent, one quoted string,
    // no raw quote/backslash/newline inside. (Collect violations in a plain
    // loop — a per-line expect() over 50k lines dominates the test runtime.)
    final lineRe = RegExp(r'^  "(?:[^"\\]|\\.)*"$');
    final malformed = lines.where((l) => !lineRe.hasMatch(l)).toList();
    expect(malformed, isEmpty);

    // Round the entries back out of the TOML — nothing lost, nothing mangled.
    final decoded = lines
        .map((l) => tomlUnescape(l.substring(3, l.length - 1)))
        .toSet();
    final expected = {...domains, ...apps};
    expect(decoded.length, expected.length);
    expect(decoded.containsAll(expected), isTrue);

    // Output size sanity: linear in the input, not blown up.
    expect(toml.length, lessThan(4 * 1024 * 1024));
  }, timeout: timeout);

  // ── 2. Bulk exclusion import (paste pipeline) ────────────────────────────

  test('importExclusionList handles 50k pasted lines linearly', () {
    // 40k unique valid entries (as URLs / CIDRs / IPs), 5k case-variant
    // duplicates, 5k garbage — one token per line.
    final lines = <String>[
      for (var i = 0; i < 20000; i++) 'https://Site$i.Example.com/path?q=1',
      for (var i = 0; i < 10000; i++) '10.${(i >> 8) & 255}.${i & 255}.0/24',
      for (var i = 0; i < 10000; i++) '192.${(i >> 8) & 255}.${i & 255}.7',
      for (var i = 0; i < 5000; i++) 'SITE$i.EXAMPLE.COM', // dup of URL form
      for (var i = 0; i < 2500; i++) 'bad_token_$i!!',
      for (var i = 0; i < 2500; i++) '300.300.$i.0/99',
    ];
    final raw = lines.join('\n');

    late (List<String>, int) result;
    final elapsed = timed(() => result = importExclusionList(raw, const {}));
    expect(elapsed, lessThan(const Duration(seconds: 15)),
        reason: 'paste import must not be quadratic in the number of lines');

    final (added, invalid) = result;
    expect(added, hasLength(40000));
    expect(invalid, 5000);
    expect(added.toSet(), hasLength(40000), reason: 'no duplicates in output');
    expect(added, contains('site0.example.com'));
    expect(added, contains('10.0.0.0/24'));
    expect(added, contains('192.0.0.7'));

    // Entries already present are skipped, not re-added.
    final existing = {for (var i = 0; i < 1000; i++) 'site$i.example.com'};
    final (addedLess, _) = importExclusionList(raw, existing);
    expect(addedLess, hasLength(39000));
  }, timeout: timeout);

  // ── 3. Geosite / geoip source parsing ────────────────────────────────────

  test('geosite source with 50k lines (incl. includes) parses fast',
      () async {
    const root = 'https://example.com/data/root';
    final rootBody = <String>[
      for (var i = 0; i < 30000; i++) 'g$i.example.com',
      for (var i = 0; i < 5000; i++) 'full:f$i.example.org',
      for (var i = 0; i < 5000; i++) 'domain:d$i.example.net',
      for (var i = 0; i < 5000; i++) 'x$i.example.com @ads',
      for (var i = 0; i < 2000; i++) '# comment $i',
      for (var i = 0; i < 1000; i++) 'regexp:^ads$i\\.',
      for (var i = 0; i < 1000; i++) 'keyword:track$i',
      'include:extra',
    ].join('\n');
    final extraBody = <String>[
      for (var i = 0; i < 4000; i++) 'inc$i.example.com',
      'include:extra2',
    ].join('\n');
    final extra2Body =
        [for (var i = 0; i < 1000; i++) 'deep$i.example.com'].join('\n');

    final service = ConfigService(fetchUrl: (url) async {
      switch (url) {
        case root:
          return rootBody;
        case 'https://example.com/data/extra':
          return extraBody;
        case 'https://example.com/data/extra2':
          return extra2Body;
        default:
          throw StateError('unexpected URL: $url');
      }
    });

    late (List<String>, int, List<String>) result;
    final elapsed = await timedAsync(() async {
      result = await service.fetchRoutingSource(
          urls: const [root], format: 'geosite');
    });
    expect(elapsed, lessThan(const Duration(seconds: 10)));

    final (entries, skipped, errors) = result;
    expect(errors, isEmpty);
    expect(skipped, 0);
    expect(entries, hasLength(50000));
    final set = entries.toSet();
    expect(set, containsAll(['g0.example.com', 'g29999.example.com']));
    expect(set, containsAll(['f0.example.org', 'd4999.example.net']));
    expect(set, contains('x0.example.com'), reason: '@attribute tail cut');
    expect(set, containsAll(['inc3999.example.com', 'deep999.example.com']),
        reason: 'include: chain must be followed');
  }, timeout: timeout);

  test('geoip source with 50k CIDRs validates fast', () async {
    final body = <String>[
      for (var i = 0; i < 45000; i++) '10.${(i >> 8) & 255}.${i & 255}.0/24',
      for (var i = 0; i < 5000; i++)
        '2a00:${(0x1000 + i).toRadixString(16)}::/48',
      for (var i = 0; i < 3000; i++) '# comment $i',
      for (var i = 0; i < 2000; i++) '999.999.$i.0/24', // invalid → skipped
    ].join('\n');

    final service = ConfigService(fetchUrl: (_) async => body);
    late (List<String>, int, List<String>) result;
    final elapsed = await timedAsync(() async {
      result = await service.fetchRoutingSource(
          urls: const ['https://example.com/text/xx.txt'], format: 'geoip');
    });
    expect(elapsed, lessThan(const Duration(seconds: 15)));

    final (entries, skipped, errors) = result;
    expect(errors, isEmpty);
    expect(entries, hasLength(50000));
    expect(skipped, 2000);
    // 44999 = 175*256 + 199 — the last generated IPv4 CIDR.
    expect(entries.toSet(),
        containsAll(['10.0.0.0/24', '10.175.199.0/24', '2a00:1000::/48']));
  }, timeout: timeout);

  // ── 4. Merging routing lists into exclusions ─────────────────────────────

  /// Three enabled file-type lists of 20k entries each; adjacent lists share
  /// 6k entries (30%). Union: m0..m47999 = 48000 distinct.
  Future<void> seedThreeOverlappingLists(Directory tmp) async {
    SharedPreferences.setMockInitialValues({
      'routing_lists': jsonEncode([
        for (var k = 0; k < 3; k++)
          RoutingList(
            id: 'l$k',
            name: 'List $k',
            type: 'file',
            sourcePath: 'src$k',
            enabled: true,
            appliesTo: 'both',
          ).toJson(),
      ]),
    });
    final cacheDir = Directory(p.join(tmp.path, 'client', 'routing_lists'))
      ..createSync(recursive: true);
    for (var k = 0; k < 3; k++) {
      final entries = [
        for (var i = k * 14000; i < k * 14000 + 20000; i++) 'm$i.example.com'
      ];
      File(p.join(cacheDir.path, 'l$k.lst'))
          .writeAsStringSync(entries.join('\n'));
    }
  }

  test('collectRoutingEntries merges 3×20k lists with 30% overlap', () async {
    final tmp = useTempCwd();
    await seedThreeOverlappingLists(tmp);

    late List<String> entries;
    final elapsed = await timedAsync(() async {
      entries = await offlineService().collectRoutingEntries(VpnMode.general);
    });
    expect(elapsed, lessThan(const Duration(seconds: 10)));

    expect(entries, hasLength(48000), reason: 'overlap must de-duplicate');
    // containsAll on a Set is linear; the unordered-equality matcher is not.
    final expected = {for (var i = 0; i < 48000; i++) 'm$i.example.com'};
    expect(entries.toSet().containsAll(expected), isTrue);
  }, timeout: timeout);

  test('writeConfigFile merges user domains + lists and counts them',
      () async {
    final tmp = useTempCwd();
    await seedThreeOverlappingLists(tmp);

    final config = ServerConfig(
      hostname: 'vpn.example.org',
      address: '203.0.113.1',
      username: 'user',
      password: 'pw',
      vpnMode: VpnMode.selective,
      splitTunnelDomains: [
        for (var i = 0; i < 5000; i++) 'u$i.example.com'
      ],
    );

    final service = offlineService();
    final elapsed =
        await timedAsync(() => service.writeConfigFile(config));
    expect(elapsed, lessThan(const Duration(seconds: 20)));

    expect(service.lastMergedExclusionCount, 53000);
    expect(service.lastMergedExclusionCount,
        greaterThan(ConfigService.mergedExclusionsSoftLimit),
        reason: 'this scenario must trip the soft-limit warning');

    final toml =
        File(p.join(tmp.path, 'client', 'trusttunnel_client.toml'))
            .readAsStringSync();
    final lines = tomlExclusionLines(toml);
    expect(lines, hasLength(53000));
    expect(toml, contains('"u4999.example.com"'));
    expect(toml, contains('"m47999.example.com"'));
  }, timeout: timeout);

  // ── 5. JSON round-trips of stored structures ─────────────────────────────

  test('domain groups + config JSON round-trip with 5k domains', () {
    final groups = [
      for (var g = 0; g < 50; g++)
        DomainGroup(
          id: 'g$g',
          name: 'Group $g',
          primaryDomain: 'group$g.example.com',
          domains: [for (var i = 0; i < 50; i++) 'g$g-d$i.example.com'],
        ),
    ];
    final standalone = [for (var i = 0; i < 2500; i++) 's$i.example.com'];
    final data =
        DomainGroupsData(groups: groups, standaloneDomains: standalone);

    late DomainGroupsData dataBack;
    late ServerConfig configBack;
    final config = ServerConfig.defaultConfig()
        .copyWith(splitTunnelDomains: data.flattenDomains());
    final elapsed = timed(() {
      dataBack = DomainGroupsData.fromJson(
          jsonDecode(jsonEncode(data.toJson())) as Map<String, dynamic>);
      configBack = ServerConfig.fromJson(
          jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>);
    });
    expect(elapsed, lessThan(const Duration(seconds: 5)));

    expect(dataBack.groups, hasLength(50));
    expect(dataBack.standaloneDomains, standalone);
    final flatBack = dataBack.flattenDomains();
    expect(flatBack, hasLength(5000));
    expect(flatBack.toSet().containsAll(data.flattenDomains()), isTrue);
    expect(configBack.splitTunnelDomains, config.splitTunnelDomains);

    // RoutingList metadata round-trips too (entries live in the .lst cache).
    final lists = [
      for (var i = 0; i < 200; i++)
        RoutingList(
          id: 'r$i',
          name: 'List $i',
          type: 'url',
          urls: ['https://example.com/$i.lst'],
          format: i.isEven ? 'geosite' : 'geoip',
          enabled: true,
          entryCount: 20000 + i,
          lastUpdatedIso: '2026-08-26T00:00:00.000',
        ),
    ];
    final listsBack = (jsonDecode(
            jsonEncode([for (final l in lists) l.toJson()])) as List)
        .map((e) => RoutingList.fromJson(e as Map<String, dynamic>))
        .toList();
    expect(listsBack, hasLength(200));
    expect(listsBack.last.entryCount, 20199);
    expect(listsBack.first.format, 'geosite');
  }, timeout: timeout);

  // ── 6. Cache file loading ────────────────────────────────────────────────

  test('a 50k-entry .lst cache loads within bounds', () async {
    final tmp = useTempCwd();
    SharedPreferences.setMockInitialValues({
      'routing_lists': jsonEncode([
        const RoutingList(
          id: 'big',
          name: 'Big',
          type: 'file',
          sourcePath: 'src',
          enabled: true,
          appliesTo: 'both',
        ).toJson(),
      ]),
    });
    final cacheDir = Directory(p.join(tmp.path, 'client', 'routing_lists'))
      ..createSync(recursive: true);
    File(p.join(cacheDir.path, 'big.lst')).writeAsStringSync(
        [for (var i = 0; i < 50000; i++) 'c$i.example.com'].join('\n'));

    late List<String> entries;
    final elapsed = await timedAsync(() async {
      entries =
          await offlineService().collectRoutingEntries(VpnMode.selective);
    });
    expect(elapsed, lessThan(const Duration(seconds: 10)));

    expect(entries, hasLength(50000));
    expect(entries.toSet(), contains('c49999.example.com'));
  }, timeout: timeout);
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/routing_list.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/utils/routing_source_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Point Directory.current (the base of the routing list cache) at a fresh
  /// temp dir for tests that touch cache files.
  Directory useTempCwd() {
    final tmp = Directory.systemTemp.createTempSync('trusty_routing_test');
    final oldCwd = Directory.current;
    Directory.current = tmp;
    addTearDown(() {
      Directory.current = oldCwd;
      tmp.deleteSync(recursive: true);
    });
    return tmp;
  }

  test('validateRoutingEntries keeps domains/IPs/CIDRs/TLDs, drops garbage',
      () {
    final (valid, skipped) = ConfigService.validateRoutingEntries([
      'youtube.com',
      '8.8.8.8',
      '92.255.112.0/20',
      'ua', // bare TLD from a ".ua" line — a valid suffix for the client
      'not a domain',
      '10.0.0.0/99',
    ]);
    expect(valid, ['youtube.com', '8.8.8.8', '92.255.112.0/20', 'ua']);
    expect(skipped, 2);
  });

  test('validateRoutingEntries accepts unicode and punycode bare TLDs', () {
    final (valid, skipped) = ConfigService.validateRoutingEntries([
      'рф', // '.рф' after parseRoutingList strips the dot
      'бел',
      'xn--p1ai', // punycode form of .рф
      'com',
      'не тлд', // space — not a label
      '123', // TLDs never start with a digit
    ]);
    expect(valid, ['рф', 'бел', 'xn--p1ai', 'com']);
    expect(skipped, 2);
  });

  test("'.рф'-style lines survive the download pipeline", () async {
    final service =
        ConfigService(fetchUrl: (_) async => '.рф\n.com\nкинопоиск.рф\n');
    final (entries, skipped, errors) = await service.fetchRoutingSource(
      urls: ['https://example.com/l.lst'],
    );
    expect(errors, isEmpty);
    expect(skipped, 0);
    expect(entries.toSet(), {'рф', 'com', 'кинопоиск.рф'});
  });

  test('readBodyCapped aborts an oversized body while it still streams',
      () async {
    var chunksEmitted = 0;
    Stream<List<int>> hugeBody() async* {
      final chunk = List<int>.filled(1024 * 1024, 0x61); // 1 MB of 'a'
      for (var i = 0; i < 100; i++) {
        chunksEmitted++;
        yield chunk;
      }
    }

    await expectLater(
      ConfigService.readBodyCapped(hugeBody()),
      throwsA(predicate((e) => e.toString().contains('too large'))),
    );
    expect(chunksEmitted, lessThan(10),
        reason: 'the size cap must stop consuming the stream right after '
            'the limit, not buffer all 100 MB first');

    expect(
      await ConfigService.readBodyCapped(Stream.value(utf8.encode('ok'))),
      'ok',
    );
  });

  test('RoutingList JSON round trip and mode matching', () {
    const list = RoutingList(
      id: 'x1',
      name: 'My list',
      type: 'url',
      urls: ['https://example.com/a.lst'],
      enabled: true,
      appliesTo: 'selective',
      lastUpdatedIso: '2026-07-18T10:00:00.000',
      entryCount: 42,
    );
    final back = RoutingList.fromJson(list.toJson());
    expect(back.name, 'My list');
    expect(back.urls, ['https://example.com/a.lst']);
    expect(back.entryCount, 42);
    expect(back.lastUpdated, isNotNull);

    expect(back.matchesMode(VpnMode.selective), isTrue);
    expect(back.matchesMode(VpnMode.general), isFalse);
    expect(
      RoutingList(id: 'x2', name: 'b', type: 'url', appliesTo: 'both')
          .matchesMode(VpnMode.general),
      isTrue,
    );
  });

  test('legacy single-preset keys migrate into the built-in list entry',
      () async {
    SharedPreferences.setMockInitialValues({
      'routing_preset_enabled': true,
      'routing_preset_count': 1200,
      'routing_preset_updated': '2026-07-01T00:00:00.000',
    });

    final service = ConfigService();
    final lists = await service.loadRoutingLists();

    expect(lists, hasLength(1));
    final builtin = lists.single;
    expect(builtin.id, ConfigService.builtinRoutingListId);
    expect(builtin.isBuiltin, isTrue);
    expect(builtin.enabled, isTrue);
    expect(builtin.entryCount, 1200);
    expect(builtin.lastUpdatedIso, '2026-07-01T00:00:00.000');
    expect(builtin.urls, ConfigService.routingPresetUrls);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('routing_preset_enabled'), isFalse);
    expect(prefs.containsKey('routing_preset_count'), isFalse);
  });

  test('a fresh install starts with no routing lists at all', () async {
    final service = ConfigService();
    expect(await service.loadRoutingLists(), isEmpty,
        reason: 'nothing is added for the user; the catalogue is the way in');
  });

  test('an install that used the pre-0.4.0 preset keeps it', () async {
    // The legacy keys are the only evidence that the old single preset was
    // in use; without them there is nothing to carry over.
    SharedPreferences.setMockInitialValues({
      'routing_preset_enabled': true,
      'routing_preset_count': 1204,
    });
    final service = ConfigService();
    final lists = await service.loadRoutingLists();
    expect(lists, hasLength(1));
    expect(lists.single.enabled, isTrue, reason: 'it was on before the upgrade');
    expect(lists.single.entryCount, 1204);
    expect(lists.single.isBuiltin, isTrue);
  });

  test('stored builtin list with the old label is renamed to Default',
      () async {
    SharedPreferences.setMockInitialValues({
      'routing_lists': jsonEncode([
        const RoutingList(
          id: ConfigService.builtinRoutingListId,
          name: 'Sites blocked in Russia',
          type: 'builtin',
          enabled: true,
          entryCount: 1200,
        ).toJson(),
      ]),
    });
    final lists = await ConfigService().loadRoutingLists();
    expect(lists.single.name, 'Default');
    expect(lists.single.enabled, isTrue, reason: 'rename must not reset state');
    expect(lists.single.entryCount, 1200);
  });

  test('enable/appliesTo updates persist, and any list can be deleted',
      () async {
    // A clean install has no lists, so migrate one in to have something to
    // act on.
    SharedPreferences.setMockInitialValues({'routing_preset_enabled': false});
    final service = ConfigService();
    expect(await service.loadRoutingLists(), hasLength(1));

    await service.setRoutingListEnabled(
        ConfigService.builtinRoutingListId, true);
    await service.setRoutingListAppliesTo(
        ConfigService.builtinRoutingListId, 'both');

    var lists = await service.loadRoutingLists();
    expect(lists.single.enabled, isTrue);
    expect(lists.single.appliesTo, 'both');

    await service.deleteRoutingList(ConfigService.builtinRoutingListId);
    lists = await service.loadRoutingLists();
    expect(lists, isEmpty,
        reason: 'a carried-over list is removable like any other; an entry the '
            'user cannot delete is a trap');
  });

  // ── Source formats: v2fly geosite / geoip ───────────────────────────────

  test('stored lists without a format field default to plain', () {
    final legacy = RoutingList.fromJson({
      'id': 'x1',
      'name': 'Old list',
      'type': 'url',
      'urls': ['https://example.com/a.lst'],
    });
    expect(legacy.format, 'plain');

    const geosite =
        RoutingList(id: 'g1', name: 'G', type: 'url', format: 'geosite');
    expect(RoutingList.fromJson(geosite.toJson()).format, 'geosite');
    expect(geosite.copyWith(enabled: true).format, 'geosite',
        reason: 'copyWith must preserve the format');
  });

  test('parseGeositeList: domains, full:/domain:, attributes, comments',
      () async {
    const body = '''
# comment line
example.com
full:exact.example.org
domain:suffix.example.net
regexp:^www\\d+\\.example\\.com\$
keyword:google
tracker.example.com @ads
include:
EXAMPLE.COM
''';
    final result = await parseGeositeList(
      body,
      fetchCategory: (_) async => fail('no includes expected'),
    );
    expect(result, [
      'example.com',
      'exact.example.org',
      'suffix.example.net',
      'tracker.example.com',
    ]);
  });

  test('parseGeositeList: include recursion fetches each category once',
      () async {
    const cats = {
      'a': 'a.com\ninclude:b',
      'b': 'b.com\ninclude:a', // cycle back to a
    };
    final calls = <String>[];
    final result = await parseGeositeList(
      'root.com\ninclude:a',
      fetchCategory: (c) async {
        calls.add(c);
        return cats[c]!;
      },
    );
    expect(result, ['root.com', 'a.com', 'b.com']);
    expect(calls, ['a', 'b'], reason: 'cycle must not refetch a');
  });

  test('parseGeositeList: include depth is capped', () async {
    // Chain c1 → c2 → …; parsing starts at depth 0, so c5 is the deepest
    // category fetched and c6 is silently dropped.
    final result = await parseGeositeList(
      'include:c1',
      fetchCategory: (c) async {
        final i = int.parse(c.substring(1));
        return 'd$i.com\ninclude:c${i + 1}';
      },
    );
    expect(result, ['d1.com', 'd2.com', 'd3.com', 'd4.com', 'd5.com']);
  });

  test('parseGeositeList: failed include propagates', () async {
    expect(
      parseGeositeList('include:x',
          fetchCategory: (_) async => throw Exception('HTTP 404')),
      throwsException,
    );
  });

  test('fetchRoutingSource geosite: includes resolve as sibling URLs',
      () async {
    final fetched = <String>[];
    final service = ConfigService(fetchUrl: (url) async {
      fetched.add(url);
      switch (url) {
        case 'https://example.com/data/youtube':
          return 'youtube.com\nfull:m.youtube.com\ninclude:google\n'
              'regexp:^ads\\.\n';
        case 'https://example.com/data/google':
          return 'google.com @cn\n# maintained upstream\ngoogle.com\n';
        default:
          throw Exception('unexpected URL: $url');
      }
    });

    final (entries, skipped, errors) = await service.fetchRoutingSource(
      urls: ['https://example.com/data/youtube'],
      format: 'geosite',
    );
    expect(errors, isEmpty);
    expect(skipped, 0);
    expect(entries.toSet(), {'youtube.com', 'm.youtube.com', 'google.com'});
    expect(fetched, contains('https://example.com/data/google'));
  });

  test('fetchRoutingSource geoip: CIDR per line, comments skipped', () async {
    final service = ConfigService(
        fetchUrl: (_) async => '# RU blocks\n5.8.0.0/19\n\n5.16.0.0/16\n'
            '2a00:1fa0::/32\n5.8.0.0/19\nnot-a-cidr!\n');
    final (entries, skipped, _) = await service.fetchRoutingSource(
      urls: ['https://example.com/text/ru.txt'],
      format: 'geoip',
    );
    expect(entries.toSet(), {'5.8.0.0/19', '5.16.0.0/16', '2a00:1fa0::/32'});
    expect(entries, hasLength(3), reason: 'duplicate CIDR must collapse');
    expect(skipped, 1);
  });

  test('fetchRoutingSource de-duplicates across overlapping sources',
      () async {
    final service = ConfigService(
        fetchUrl: (url) async => url.endsWith('one')
            ? 'youtube.com\n8.8.8.8'
            : 'YouTube.com\n1.1.1.1');
    final (entries, _, errors) = await service.fetchRoutingSource(
      urls: ['https://example.com/one', 'https://example.com/two'],
    );
    expect(errors, isEmpty);
    expect(entries.toSet(), {'youtube.com', '8.8.8.8', '1.1.1.1'});
    expect(entries, hasLength(3));
  });

  test('refreshRoutingList caches the flat parsed geosite output', () async {
    final tmp = useTempCwd();
    SharedPreferences.setMockInitialValues({
      'routing_lists': jsonEncode([
        const RoutingList(
          id: 'gs',
          name: 'Geosite',
          type: 'url',
          urls: ['https://example.com/data/x'],
          format: 'geosite',
          enabled: true,
        ).toJson(),
      ]),
    });

    final service = ConfigService(
        fetchUrl: (url) async =>
            url.endsWith('/x') ? 'a.com\ninclude:y' : 'b.com\nfull:c.com');
    await service.refreshRoutingList('gs');

    final cache = File(p.join(tmp.path, 'client', 'routing_lists', 'gs.lst'))
        .readAsStringSync();
    expect(cache.split('\n'), ['a.com', 'b.com', 'c.com'],
        reason: 'cache must hold flat entries, not geosite syntax');

    final list = (await service.loadRoutingLists()).single;
    expect(list.entryCount, 3);
    expect(list.lastError, '');
  });

  test('refreshRoutingList replaces an existing cache without a delete gap',
      () async {
    final tmp = useTempCwd();
    SharedPreferences.setMockInitialValues({
      'routing_lists': jsonEncode([
        const RoutingList(
          id: 'u1',
          name: 'U',
          type: 'url',
          urls: ['https://example.com/a.lst'],
          enabled: true,
        ).toJson(),
      ]),
    });

    var body = 'old.com';
    final service = ConfigService(fetchUrl: (_) async => body);
    await service.refreshRoutingList('u1');
    body = 'new.com\nnew2.com';
    await service.refreshRoutingList('u1');

    final cache = File(p.join(tmp.path, 'client', 'routing_lists', 'u1.lst'));
    expect(cache.readAsStringSync().split('\n'), ['new.com', 'new2.com'],
        reason: 'rename must replace the previous cache in place');
    expect(File('${cache.path}.tmp').existsSync(), isFalse);
  });

  test('collectRoutingEntries merges cached lists and de-duplicates',
      () async {
    final tmp = useTempCwd();
    SharedPreferences.setMockInitialValues({
      'routing_lists': jsonEncode([
        const RoutingList(
            id: 'a', name: 'A', type: 'file', sourcePath: 'x', enabled: true)
            .toJson(),
        const RoutingList(
                id: 'b',
                name: 'B',
                type: 'file',
                sourcePath: 'y',
                enabled: true,
                appliesTo: 'both')
            .toJson(),
        const RoutingList(
                id: 'c', name: 'C', type: 'file', sourcePath: 'z')
            .toJson(), // disabled — must not contribute
      ]),
    });

    final cacheDir =
        Directory(p.join(tmp.path, 'client', 'routing_lists'))
          ..createSync(recursive: true);
    File(p.join(cacheDir.path, 'a.lst'))
        .writeAsStringSync('youtube.com\n8.8.8.8');
    File(p.join(cacheDir.path, 'b.lst'))
        .writeAsStringSync('YouTube.com\n1.1.1.1');
    File(p.join(cacheDir.path, 'c.lst')).writeAsStringSync('nope.com');

    final entries =
        await ConfigService().collectRoutingEntries(VpnMode.selective);
    expect(entries.toSet(), {'youtube.com', '8.8.8.8', '1.1.1.1'});
    expect(entries, hasLength(3),
        reason: 'same entry from two lists must merge into one');
  });

  test('preset catalog entries are well-formed', () {
    expect(routingPresets, isNotEmpty);
    for (final preset in routingPresets) {
      expect(preset.name, isNotEmpty);
      expect(preset.urls, isNotEmpty);
      for (final url in preset.urls) {
        expect(Uri.parse(url).isAbsolute, isTrue);
      }
      expect(const {'plain', 'geosite', 'geoip'}, contains(preset.format));
    }
    expect(
      routingPresets
          .where((preset) => preset.format == 'geoip')
          .every((preset) => preset.urls.every((u) => u.endsWith('.txt'))),
      isTrue,
      reason: 'v2fly geoip text releases are per-country .txt files',
    );
    expect(
      routingPresets.where((p) => p.urls.length > 1),
      isNotEmpty,
      reason: 'the blocked-in-Russia preset merges several sources',
    );
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trusty/models/routing_list.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/services/config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

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

  test('fresh install gets the built-in list disabled, named Default',
      () async {
    final service = ConfigService();
    final lists = await service.loadRoutingLists();
    expect(lists, hasLength(1));
    expect(lists.single.enabled, isFalse);
    expect(lists.single.entryCount, 0);
    expect(lists.single.name, 'Default');
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

  test('enable/appliesTo updates persist; builtin cannot be deleted',
      () async {
    final service = ConfigService();
    await service.loadRoutingLists();

    await service.setRoutingListEnabled(
        ConfigService.builtinRoutingListId, true);
    await service.setRoutingListAppliesTo(
        ConfigService.builtinRoutingListId, 'both');

    var lists = await service.loadRoutingLists();
    expect(lists.single.enabled, isTrue);
    expect(lists.single.appliesTo, 'both');

    await service.deleteRoutingList(ConfigService.builtinRoutingListId);
    lists = await service.loadRoutingLists();
    expect(lists, hasLength(1), reason: 'built-in list must survive delete');
  });
}

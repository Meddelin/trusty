// UI scenario tests for the redesigned Split Tunnel screen.
//
// Everything here drives the real `SplitTunnelScreen` with the real
// ConfigService/VpnService from the shared harness: taps, typing, dialogs,
// and — after every save — a read-back through the live ConfigService.
//
// Two environment notes, neither of them a defect in the screen:
//   * Opening the Apps tab kicks off the installed-apps scan on a real
//     isolate. That isolate cannot complete inside the fake-async test zone,
//     so the Apps tab stays in its busy state and `pumpAndSettle` would time
//     out on the spinner — the Apps tests pump by hand instead.
//   * The tests that exercise the screen's dialogs are collected at the very
//     end of the file. That grouping is historical — it dates from when the
//     dialogs disposed their controller mid-transition and the corrupted
//     element tree took every later test down with it — but it is worth
//     keeping: if that regression ever comes back, it stays contained.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trusty/models/routing_list.dart';
import 'package:trusty/screens/split_tunnel_screen.dart';
import 'package:trusty/widgets/app_switch.dart';

import 'harness.dart';

// ── seeding helpers ───────────────────────────────────────────────────────

/// SharedPreferences payload for the domain list the screen reads on boot.
Map<String, Object> seedDomains({
  List<String> standalone = const [],
  List<Map<String, Object>> groups = const [],
}) => {
  'domain_groups': jsonEncode({
    'version': 1,
    'groups': groups,
    'standaloneDomains': standalone,
  }),
};

Map<String, Object> group(String id, String name, List<String> domains) => {
  'id': id,
  'name': name,
  'primaryDomain': domains.first,
  'domains': domains,
};

/// A routing-lists payload. Seeding the key at all also stops the service
/// from running its first-launch migration (which touches `client/`).
Map<String, Object> seedRoutingLists(List<Map<String, Object>> lists) => {
  'routing_lists': jsonEncode(lists),
};

Map<String, Object> routingList({
  required String id,
  required String name,
  String type = 'url',
  bool enabled = false,
  String appliesTo = 'selective',
  int entryCount = 0,
  String lastError = '',
  String lastUpdatedIso = '',
}) => {
  'id': id,
  'name': name,
  'type': type,
  'urls': const ['https://example.invalid/list.lst'],
  'sourcePath': '',
  'format': 'plain',
  'enabled': enabled,
  'appliesTo': appliesTo,
  'lastUpdatedIso': lastUpdatedIso,
  'entryCount': entryCount,
  'lastError': lastError,
};

/// The two lists the side column shows in most of these tests: the built-in
/// preset (already downloaded, so toggling it never hits the network) and one
/// user list.
final _twoLists = seedRoutingLists([
  routingList(
    id: 'builtin',
    name: 'Default',
    type: 'builtin',
    entryCount: 4200,
    lastUpdatedIso: '2026-08-01T10:00:00.000',
  ),
  routingList(id: 'mine', name: 'My list', entryCount: 12),
]);

Map<String, Object> mergePrefs(List<Map<String, Object>> parts) => {
  for (final p in parts) ...p,
};

// ── finders / drivers ─────────────────────────────────────────────────────

Finder fieldWithHint(String hint) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == hint,
  description: 'TextField(hintText: "$hint")',
);

final domainField = fieldWithHint('Enter domain, IP or CIDR');

final appSearchField = find.byWidgetPredicate(
  (w) =>
      w is TextField && (w.decoration?.hintText ?? '').startsWith('Search apps'),
  description: 'app search field',
);

/// The only TextField inside the open dialog.
final dialogField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

/// An `IconButton` wraps its own `Tooltip`, so the button is the tooltip's
/// ancestor.
IconButton buttonWithTooltip(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(IconButton),
          )
          .first,
    );

/// Type [text] into the domain field and press the "+" button.
Future<void> addDomain(WidgetTester tester, String text) async {
  await tester.enterText(domainField, text);
  await tester.tap(find.byTooltip('Add'));
  await tester.pumpAndSettle();
}

/// Snackbars hold a 3–6s timer; let them expire so the test does not end
/// with a pending timer (and so the next assertion sees a clean screen).
Future<void> flushSnackbars(WidgetTester tester, {bool settle = true}) async {
  await tester.pump(const Duration(seconds: 7));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// Lets real (non-faked) IO in the widget under test make progress: each
/// `await` on a file operation needs one turn of the real event loop plus one
/// pump to run the continuation that issues the next one.
Future<void> settleRealIo(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

/// Opens the Apps tab. The tab triggers a real installed-apps scan on an
/// isolate, which never completes inside the fake-async test zone — so this
/// deliberately pumps rather than settles.
Future<void> openAppsTab(WidgetTester tester) async {
  await tester.tap(find.textContaining('Apps ('));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// A tap on the Apps tab, where nothing ever settles (see above).
Future<void> tapOnAppsTab(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  // ── rendering matrix: both windows, both brightnesses, both tabs ────────

  for (final size in [kDefaultWindow, kMinWindow]) {
    for (final brightness in [Brightness.dark, Brightness.light]) {
      final label =
          '${size.width.toInt()}x${size.height.toInt()} ${brightness.name}';

      testWidgets('domains tab lays out at $label', (tester) async {
        await pumpScreen(
          tester,
          const SplitTunnelScreen(),
          size: size,
          brightness: brightness,
          prefs: mergePrefs([
            seedDomains(
              standalone: [
                'vk.com',
                '92.255.112.0/20',
                '1.1.1.1',
                '*.googlevideo.com',
              ],
              groups: [
                group('g1', 'Google', [
                  'google.com',
                  'youtube.com',
                  'gstatic.com',
                ]),
              ],
            ),
            _twoLists,
          ]),
        );

        expect(find.text('Google'), findsOneWidget);
        expect(find.text('vk.com'), findsOneWidget);
        expect(find.text('Default'), findsOneWidget);
        expectNoOverflow(tester);

        // …and with a group expanded, which is the tallest the tab gets.
        await tester.tap(find.text('Google'));
        await tester.pumpAndSettle();
        expect(find.text('gstatic.com'), findsOneWidget);
        expectNoOverflow(tester);
      });

      testWidgets('apps tab lays out at $label', (tester) async {
        await pumpScreen(
          tester,
          const SplitTunnelScreen(),
          size: size,
          brightness: brightness,
          prefs: mergePrefs([_twoLists]),
        );
        await openAppsTab(tester);

        expect(appSearchField, findsOneWidget);
        expect(find.textContaining('Apps'), findsWidgets);
        expectNoOverflow(tester);

        // …and with a query typed, which reveals the extra "+" control and
        // swaps the list for the empty state plus its action button.
        await tester.enterText(appSearchField, 'notepad');
        await tester.pump();
        expectNoOverflow(tester);
      });
    }
  }

  testWidgets('empty screen shows the domains empty state', (tester) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    expect(find.text('No domains added'), findsOneWidget);
    expect(find.text('Domains (0)'), findsOneWidget);
    expect(find.text('Apps (0)'), findsOneWidget);
    expectNoOverflow(tester);
  });

  // ── mode ────────────────────────────────────────────────────────────────

  testWidgets('mode switch flips the header sentence and persists', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    expect(
      find.text('Everything goes through the VPN except your list'),
      findsOneWidget,
    );
    expect(find.text('Domains kept off the VPN'), findsOneWidget);

    await tester.tap(find.text('Selective'));
    await tester.pumpAndSettle();

    expect(find.text('Only your list goes through the VPN'), findsOneWidget);
    expect(find.text('Domains sent through the VPN'), findsOneWidget);
    expect((await config.loadConfig()).vpnMode.name, 'selective');

    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();
    expect(
      find.text('Everything goes through the VPN except your list'),
      findsOneWidget,
    );
    expect((await config.loadConfig()).vpnMode.name, 'general');
    expectNoOverflow(tester);
  });

  testWidgets('proxy mode is stated honestly in the header', (tester) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(),
        _twoLists,
        {'app_connection_mode': 'socks5'},
      ]),
    );

    expect(
      find.textContaining('Proxy mode is active'),
      findsOneWidget,
      reason: 'SOCKS5 changes what these rules can do — the screen says so',
    );
    expect(
      find.text('Everything goes through the proxy except your list'),
      findsOneWidget,
    );
    expectNoOverflow(tester);
  });

  // ── domains tab ─────────────────────────────────────────────────────────

  testWidgets('adding a domain lists it, counts it and persists it', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    await addDomain(tester, 'vk.com');

    expect(find.text('vk.com'), findsOneWidget);
    expect(find.text('No domains added'), findsNothing);
    expect(find.text('Domains (1)'), findsOneWidget);
    // The add confirms itself and offers discovery as a follow-up.
    expect(find.text('Added vk.com'), findsOneWidget);
    expect(find.text('Find related'), findsOneWidget);

    final saved = await config.loadDomainGroups();
    expect(saved.standaloneDomains, ['vk.com']);
    expect((await config.loadConfig()).splitTunnelDomains, contains('vk.com'));

    await flushSnackbars(tester);
    expectNoOverflow(tester);
  });

  testWidgets('a pasted URL is normalised down to its host', (tester) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    await addDomain(tester, 'https://user@VK.com:443/feed?a=1');

    expect(find.text('vk.com'), findsOneWidget);
    expect((await config.loadDomainGroups()).standaloneDomains, ['vk.com']);
    await flushSnackbars(tester);
    expectNoOverflow(tester);
  });

  testWidgets('an IP and a CIDR range are accepted as they are', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    await addDomain(tester, '1.1.1.1');
    await addDomain(tester, '92.255.112.0/20');

    expect(find.text('1.1.1.1'), findsOneWidget);
    expect(find.text('92.255.112.0/20'), findsOneWidget);
    expect(find.text('Domains (2)'), findsOneWidget);
    // No discovery offer for anything that is not a plain domain.
    expect(find.text('Find related'), findsNothing);
    expect((await config.loadDomainGroups()).standaloneDomains, [
      '1.1.1.1',
      '92.255.112.0/20',
    ]);
    await flushSnackbars(tester);
    expectNoOverflow(tester);
  });

  testWidgets('garbage and a bad CIDR are both rejected with a reason', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    await addDomain(tester, 'not a domain!!');
    expect(
      find.text('Not a valid domain, IP or CIDR: "not a domain!!"'),
      findsOneWidget,
    );
    expect(find.text('No domains added'), findsOneWidget);
    await flushSnackbars(tester);

    await addDomain(tester, '10.0.0.0/99');
    expect(
      find.text('Not a valid domain, IP or CIDR: "10.0.0.0/99"'),
      findsOneWidget,
    );
    expect((await config.loadDomainGroups()).standaloneDomains, isEmpty);
    await flushSnackbars(tester);
    expectNoOverflow(tester);
  });

  testWidgets('a duplicate domain is refused, in a group as well', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(
          standalone: ['vk.com'],
          groups: [
            group('g1', 'Google', ['google.com', 'youtube.com']),
          ],
        ),
        _twoLists,
      ]),
    );

    await addDomain(tester, 'VK.com');
    expect(find.text('This domain is already added'), findsOneWidget);
    expect(find.text('vk.com'), findsOneWidget);
    await flushSnackbars(tester);

    // A domain already inside a group counts as a duplicate too.
    await addDomain(tester, 'youtube.com');
    expect(find.text('This domain is already added'), findsOneWidget);
    expect((await config.loadDomainGroups()).standaloneDomains, ['vk.com']);
    await flushSnackbars(tester);
    expectNoOverflow(tester);
  });

  testWidgets('deleting a row removes it from the list and from storage', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(standalone: ['vk.com', 'ya.ru']),
        _twoLists,
      ]),
    );

    expect(find.text('Domains (2)'), findsOneWidget);
    final row = find.ancestor(
      of: find.text('vk.com'),
      matching: find.byType(Row),
    );
    await tester.tap(
      find.descendant(of: row.first, matching: find.byTooltip('Delete')),
    );
    await tester.pumpAndSettle();

    expect(find.text('vk.com'), findsNothing);
    expect(find.text('ya.ru'), findsOneWidget);
    expect(find.text('Domains (1)'), findsOneWidget);
    expect((await config.loadDomainGroups()).standaloneDomains, ['ya.ru']);
    expectNoOverflow(tester);
  });

  // ── groups ──────────────────────────────────────────────────────────────

  testWidgets('a group shows its member count and expands to its members', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(
          standalone: ['vk.com'],
          groups: [
            group('g1', 'Google', ['google.com', 'youtube.com', 'ggpht.com']),
          ],
        ),
        _twoLists,
      ]),
    );

    expect(find.text('Google'), findsOneWidget);
    expect(find.text('3 domains'), findsOneWidget);
    // Both group and loose entries exist, so the "Other" header appears.
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Domains (4)'), findsOneWidget);
    expect(find.text('google.com'), findsNothing);

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();

    expect(find.text('google.com'), findsOneWidget);
    expect(find.text('youtube.com'), findsOneWidget);
    expect(find.text('ggpht.com'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Rename'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Delete'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('removing the last member removes the group itself', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(
          groups: [
            group('g1', 'Solo', ['solo.example']),
          ],
        ),
        _twoLists,
      ]),
    );

    await tester.tap(find.text('Solo'));
    await tester.pumpAndSettle();

    final memberRow = find
        .ancestor(of: find.text('solo.example'), matching: find.byType(Row))
        .first;
    await tester.tap(
      find.descendant(of: memberRow, matching: find.byIcon(Icons.close)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Solo'), findsNothing);
    expect(find.text('No domains added'), findsOneWidget);
    expect((await config.loadDomainGroups()).groups, isEmpty);
    expectNoOverflow(tester);
  });

  testWidgets('deleting a group asks first and honours both answers', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(
          groups: [
            group('g1', 'Google', ['google.com', 'youtube.com']),
          ],
        ),
        _twoLists,
      ]),
    );

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete group?'), findsOneWidget);
    expect(
      find.text('Group "Google" and all its domains will be deleted.'),
      findsOneWidget,
    );

    // Cancel keeps the group.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Google'), findsOneWidget);
    expect((await config.loadDomainGroups()).groups, hasLength(1));

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Google'), findsNothing);
    expect(find.text('No domains added'), findsOneWidget);
    expect((await config.loadDomainGroups()).groups, isEmpty);
    expectNoOverflow(tester);
  });

  // ── apps tab ────────────────────────────────────────────────────────────

  testWidgets('apps tab starts busy: spinner up, rescan disabled', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    expect(find.text('Apps (0)'), findsOneWidget);
    await openAppsTab(tester);

    expect(find.text('Apps kept off the VPN'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    expect(
      buttonWithTooltip(
        tester,
        'Rescan installed apps and running processes',
      ).onPressed,
      isNull,
      reason: 'rescan is disabled while a scan is running',
    );
    expectNoOverflow(tester);
  });

  testWidgets('typing a process name offers the manual add and counts it', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );
    await openAppsTab(tester);

    // No "+" until there is something to add.
    expect(find.byTooltip('Add "notepad.exe" as a process name'), findsNothing);

    await tester.enterText(appSearchField, 'notepad');
    await tester.pump();
    expect(
      find.byTooltip('Add "notepad.exe" as a process name'),
      findsOneWidget,
      reason: 'a bare name is offered as a Windows process name',
    );

    await tapOnAppsTab(
      tester,
      find.byTooltip('Add "notepad.exe" as a process name'),
    );

    expect(find.text('Apps (1)'), findsOneWidget);
    expect(find.text('Selected apps: 1'), findsOneWidget);
    expect(
      tester.widget<TextField>(appSearchField).controller!.text,
      isEmpty,
      reason: 'the query is consumed by the add',
    );
    expect((await config.loadConfig()).splitTunnelApps, ['notepad.exe']);
    expectNoOverflow(tester);
  });

  testWidgets('a selected app the scanner cannot see stays visible and '
      'searchable', (tester) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );
    await openAppsTab(tester);

    for (final name in ['chrome.exe', 'discord.exe']) {
      await tester.enterText(appSearchField, name);
      await tester.pump();
      await tapOnAppsTab(tester, find.byTooltip('Add "$name" as a process name'));
    }

    expect(find.text('Apps (2)'), findsOneWidget);
    expect(find.text('Selected apps: 2'), findsOneWidget);
    expect((await config.loadConfig()).splitTunnelApps, [
      'chrome.exe',
      'discord.exe',
    ]);

    // The rows themselves are behind the scan spinner in this environment,
    // but the search field must still narrow what the tab would show.
    await tester.enterText(appSearchField, 'chr');
    await tester.pump();
    expect(
      find.byTooltip('Add "chr.exe" as a process name'),
      findsOneWidget,
      reason: 'the query is offered as a new process name',
    );
    expectNoOverflow(tester);
  });

  testWidgets('adding the same process name twice is refused', (tester) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );
    await openAppsTab(tester);

    for (var i = 0; i < 2; i++) {
      await tester.enterText(appSearchField, 'notepad.exe');
      await tester.pump();
      await tapOnAppsTab(
        tester,
        find.byTooltip('Add "notepad.exe" as a process name'),
      );
    }

    expect(find.text('"notepad.exe" is already in the list'), findsOneWidget);
    expect(find.text('Apps (1)'), findsOneWidget);
    await flushSnackbars(tester, settle: false);
  });

  // ── routing lists ───────────────────────────────────────────────────────

  testWidgets('the side column lists the routing lists with their state', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(),
        seedRoutingLists([
          routingList(
            id: 'builtin',
            name: 'Default',
            type: 'builtin',
            entryCount: 4200,
            enabled: true,
            lastUpdatedIso: '2026-08-01T10:00:00.000',
          ),
          routingList(id: 'fresh', name: 'Never fetched'),
          routingList(
            id: 'broken',
            name: 'Broken list',
            entryCount: 3,
            lastError: 'HTTP 404',
          ),
        ]),
      ]),
    );

    expect(find.text('Routing lists'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.textContaining('4200 entries'), findsOneWidget);
    expect(find.text('not downloaded yet'), findsOneWidget);
    expect(find.textContaining('update failed'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Add list'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('a routing list can be toggled and the choice persists', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(),
        seedRoutingLists([
          routingList(
            id: 'builtin',
            name: 'Default',
            type: 'builtin',
            entryCount: 4200,
            lastUpdatedIso: '2026-08-01T10:00:00.000',
          ),
        ]),
      ]),
    );

    final toggle = find.byType(AppSwitch);
    expect(tester.widget<AppSwitch>(toggle).value, isFalse);
    // "Update now" only exists once the list is on.
    expect(find.byTooltip('Update now'), findsNothing);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<AppSwitch>(toggle).value, isTrue);
    expect(find.byTooltip('Update now'), findsOneWidget);
    expect((await config.loadRoutingLists()).single.enabled, isTrue);
    expectNoOverflow(tester);
  });

  testWidgets('the options menu retargets a list at a mode and persists it', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(),
        seedRoutingLists([
          routingList(id: 'mine', name: 'My list', entryCount: 12),
        ]),
      ]),
    );

    await tester.tap(find.byTooltip('List options'));
    await tester.pumpAndSettle();

    expect(find.text('Apply this list in:'), findsOneWidget);
    expect(find.text('Selective mode'), findsOneWidget);
    expect(find.text('General mode'), findsOneWidget);
    expect(find.text('Delete list'), findsOneWidget);

    await tester.tap(find.text('Both modes'));
    await tester.pumpAndSettle();

    expect((await config.loadRoutingLists()).single.appliesTo, 'both');
    expectNoOverflow(tester);
  });

  testWidgets('a list carried over from the old preset can be deleted too',
      (tester) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(),
        seedRoutingLists([
          routingList(
            id: 'builtin',
            name: 'Default',
            type: 'builtin',
            entryCount: 10,
          ),
        ]),
      ]),
    );

    await tester.tap(find.byTooltip('List options'));
    await tester.pumpAndSettle();
    // It used to be undeletable, which left the user stuck with an entry they
    // never chose. The catalogue can add it back, so nothing is lost.
    expect(find.text('Delete list'), findsOneWidget);
    expect(find.text('Both modes'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('deleting a user list from its menu removes it', (tester) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(),
        seedRoutingLists([
          routingList(id: 'mine', name: 'My list', entryCount: 12),
          routingList(id: 'other', name: 'Second list', entryCount: 5),
        ]),
      ]),
    );

    await tester.tap(find.byTooltip('List options').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete list'));
    await tester.pump();
    // deleteRoutingList also unlinks the list's cache file. Real file IO only
    // advances while the test lets the real event loop run, and each await in
    // that chain needs its own turn.
    await settleRealIo(tester);
    await tester.pumpAndSettle();

    // Storage first: it tells a stalled reload apart from a lost delete.
    expect((await config.loadRoutingLists()).single.name, 'Second list');
    expect(find.text('My list'), findsNothing);
    expect(find.text('Second list'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('the add-list dialog opens on its preset picker and cancels '
      'without side effects', (tester) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(),
        seedRoutingLists([
          routingList(id: 'mine', name: 'My list', entryCount: 12),
        ]),
      ]),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add list'));
    await tester.pumpAndSettle();

    expect(find.text('Add routing list'), findsOneWidget);
    expect(find.text('Preset'), findsOneWidget);
    expect(find.text('Ready-made list'), findsOneWidget);
    // Nothing picked yet, so neither Check nor Add is live.
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Check'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add'))
          .onPressed,
      isNull,
    );

    // The preset dropdown opens and offers the catalog.
    await tester.tap(find.byType(DropdownButtonFormField<RoutingPreset>));
    await tester.pumpAndSettle();
    expect(find.text('YouTube'), findsWidgets);
    expect(find.text('Russia (IP ranges)'), findsWidgets);
    expectNoOverflow(tester);

    await tester.tap(find.text('YouTube').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add'))
          .onPressed,
      isNotNull,
      reason: 'picking a preset arms the dialog',
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Add routing list'), findsNothing);
    expect(await config.loadRoutingLists(), hasLength(1));
    expectNoOverflow(tester);
  });

  testWidgets('mode change re-labels a list that is inactive in that mode', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(),
        seedRoutingLists([
          routingList(
            id: 'mine',
            name: 'My list',
            entryCount: 12,
            enabled: true,
            appliesTo: 'selective',
          ),
        ]),
      ]),
    );

    // General mode is the default, and the list only applies in Selective.
    expect(find.textContaining('inactive in general mode'), findsOneWidget);

    await tester.tap(find.text('Selective'));
    await tester.pumpAndSettle();
    expect(find.textContaining('inactive in'), findsNothing);
    expectNoOverflow(tester);
  });

  testWidgets('the add-list dialog fits the smallest window', (tester) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      size: kMinWindow,
      brightness: Brightness.light,
      prefs: mergePrefs([
        seedDomains(),
        seedRoutingLists([
          routingList(id: 'mine', name: 'My list', entryCount: 12),
        ]),
      ]),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add list'));
    await tester.pumpAndSettle();
    expect(find.text('Add routing list'), findsOneWidget);
    expectNoOverflow(tester);

    // The URL source is the tallest of the three.
    await tester.tap(find.text('From URL'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (w) => w is TextField && w.maxLines == 4,
        description: 'the URL field',
      ),
      List.generate(4, (i) => 'https://example.invalid/list$i.lst').join('\n'),
    );
    await tester.pumpAndSettle();
    expectNoOverflow(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Add routing list'), findsNothing);
    expectNoOverflow(tester);
  });

  // ── paste-list dialog geometry ──────────────────────────────────────────
  //
  // Split by window size on purpose: the dialog's text area grows to 14
  // lines, which is more than the smallest window can hold, so the field has
  // to stop growing where the window runs out rather than overflow it.

  testWidgets('the paste-list dialog fits the default window', (tester) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    await tester.tap(find.byTooltip('Paste a list'));
    await tester.pumpAndSettle();
    expect(find.text('Paste list'), findsOneWidget);
    expectNoOverflow(tester);

    await tester.enterText(
      dialogField,
      List.generate(20, (i) => 'host$i.example.com').join('\n'),
    );
    await tester.pumpAndSettle();
    expectNoOverflow(tester);
  });

  testWidgets('the paste-list dialog fits the smallest window', (tester) async {
    // Nothing is popped here: this is the layout question on its own.
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      size: kMinWindow,
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    await tester.tap(find.byTooltip('Paste a list'));
    await tester.pumpAndSettle();
    expect(find.text('Paste list'), findsOneWidget);
    expectNoOverflow(tester);

    await tester.enterText(
      dialogField,
      List.generate(20, (i) => 'host$i.example.com').join('\n'),
    );
    await tester.pumpAndSettle();
    expectNoOverflow(tester);
  });

  // ── the screen's own dialogs ────────────────────────────────────────────
  //
  // These used to fail: _importDomainList, _addDomainToGroup and _renameGroup
  // each created a TextEditingController next to `showDialog` and called
  // `controller.dispose()` on the line after the await. showDialog's future
  // completes when the route is popped, NOT when its exit transition has
  // finished, so the dialog's TextField went on rebuilding against a disposed
  // controller and tore the element tree apart mid-frame. The three prompts
  // now share `_TextPromptDialog`, a StatefulWidget that owns its controller
  // for the whole life of the route, and the tests below hold that line.

  testWidgets('closing a group dialog leaves no disposed controller behind', (
    tester,
  ) async {
    // The smallest repro of the old defect: open the rename dialog and
    // dismiss it, with nothing else happening.
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(
          groups: [
            group('g1', 'Google', ['google.com']),
          ],
        ),
        _twoLists,
      ]),
    );

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(find.text('Rename Group'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expectNoOverflow(tester);
  });

  testWidgets('paste-list imports many lines and reports added vs skipped', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(standalone: ['vk.com']),
        _twoLists,
      ]),
    );

    await tester.tap(find.byTooltip('Paste a list'));
    await tester.pumpAndSettle();
    expect(find.text('Paste list'), findsOneWidget);

    await tester.enterText(
      dialogField,
      // three good, one duplicate, two junk
      'ya.ru\n92.255.112.0/20\nalfa.bank\nvk.com\nnot_a_host!\n10.0.0.0/99',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    // State first, so the report can tell a broken frame from a lost save.
    final saved = await config.loadDomainGroups();
    expect(saved.standaloneDomains, [
      'vk.com',
      'ya.ru',
      '92.255.112.0/20',
      'alfa.bank',
    ]);

    expect(find.text('Added 3 entries (2 invalid skipped)'), findsOneWidget);
    expect(find.text('ya.ru'), findsOneWidget);
    expect(find.text('alfa.bank'), findsOneWidget);
    expect(find.text('92.255.112.0/20'), findsOneWidget);
    expect(find.text('Domains (4)'), findsOneWidget);

    await flushSnackbars(tester);
    expectNoOverflow(tester);
  });

  testWidgets('pasting only known entries says there is nothing new', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(standalone: ['vk.com']),
        _twoLists,
      ]),
    );

    await tester.tap(find.byTooltip('Paste a list'));
    await tester.pumpAndSettle();
    await tester.enterText(dialogField, 'vk.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing new to add'), findsOneWidget);
    await flushSnackbars(tester);
    expectNoOverflow(tester);
  });

  testWidgets('cancelling the paste dialog changes nothing', (tester) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([seedDomains(), _twoLists]),
    );

    await tester.tap(find.byTooltip('Paste a list'));
    await tester.pumpAndSettle();
    await tester.enterText(dialogField, 'ya.ru');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect((await config.loadDomainGroups()).standaloneDomains, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('No domains added'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('renaming a group updates the card and storage', (tester) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(
          groups: [
            group('g1', 'Google', ['google.com', 'youtube.com']),
          ],
        ),
        _twoLists,
      ]),
    );

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(find.text('Rename Group'), findsOneWidget);
    await tester.enterText(dialogField, 'Video');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect((await config.loadDomainGroups()).groups.single.name, 'Video');
    expect(find.text('Video'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('adding a domain to a group lands in that group', (tester) async {
    final config = await pumpScreen(
      tester,
      const SplitTunnelScreen(),
      prefs: mergePrefs([
        seedDomains(
          groups: [
            group('g1', 'Google', ['google.com']),
          ],
        ),
        _twoLists,
      ]),
    );

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Add domain to "Google"'), findsOneWidget);
    await tester.enterText(dialogField, 'gstatic.com');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect((await config.loadDomainGroups()).groups.single.domains, [
      'google.com',
      'gstatic.com',
    ]);
    expect(find.text('gstatic.com'), findsOneWidget);
    expect(find.text('2 domains'), findsOneWidget);
    await flushSnackbars(tester);
    expectNoOverflow(tester);
  });
}

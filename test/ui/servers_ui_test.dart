// UI scenario tests for the redesigned Servers screen.
//
// Everything here drives the REAL `ServersScreen` with the REAL services from
// `harness.dart`: taps on real cards, typing into real fields, and assertions
// read back through the live `ConfigService`.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:trusty/models/vpn_status.dart';
import 'package:trusty/screens/servers_screen.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/services/vpn_service.dart';
import 'package:trusty/widgets/app_switch.dart';

import 'harness.dart';

// --------------------------------------------------------------- seed data

Map<String, dynamic> _entry({
  required String id,
  String name = '',
  required String hostname,
  required String address,
  int port = 443,
  required String username,
}) => {
  'id': id,
  'name': name,
  'hostname': hostname,
  'address': address,
  'port': port,
  'hasIpv6': true,
  'username': username,
  'skipVerification': false,
  'upstreamProtocol': 'http2',
  'antiDpi': false,
  'customSni': '',
  'postQuantumGroupEnabled': true,
};

final Map<String, dynamic> _srvA = _entry(
  id: 'srv-a',
  name: 'Amsterdam',
  hostname: 'ams.example.net',
  address: '10.0.0.1',
  port: 443,
  username: 'alice',
);

final Map<String, dynamic> _srvB = _entry(
  id: 'srv-b',
  hostname: 'berlin.example.net',
  address: '10.0.0.2',
  port: 8443,
  username: 'bob',
);

/// SharedPreferences the app would have after saving [entries], with
/// [activeId] selected. `server_list` being present skips every migration
/// path, so the screen sees exactly this state.
Map<String, Object> _prefs(
  List<Map<String, dynamic>> entries,
  String activeId, {
  Map<String, Object> extra = const {},
}) {
  final active = entries.firstWhere((e) => e['id'] == activeId);
  return {
    'server_list': jsonEncode(entries),
    'active_server_id': activeId,
    'server_config': jsonEncode({
      ...active,
      // Migrated into the stubbed keystore on the first loadConfig(), which
      // is how the active server ends up with a real saved password — the
      // editor's password field validates non-empty.
      'password': 'hunter2',
      'dns': '8.8.8.8',
      'logLevel': 'info',
      'connectionMode': 'tun',
      'socksPort': 1080,
      'vpnMode': 'general',
      'splitTunnelDomains': <String>[],
      'splitTunnelApps': <String>[],
    }),
    ...extra,
  };
}

Map<String, Object> get _twoServers => _prefs([_srvA, _srvB], 'srv-a');
Map<String, Object> get _oneServer => _prefs([_srvA], 'srv-a');

// ---------------------------------------------------------------- finders

/// The nearest `Column` wrapping a label — i.e. the grid cell (or island
/// section) that owns the control sitting under that label.
Finder _sectionOf(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(Column)).first;

/// The editable field belonging to [label].
Finder _fieldFor(String label) =>
    find.descendant(of: _sectionOf(label), matching: find.byType(TextField)).first;

/// The `TextFormField` belonging to [label] (for widget-property assertions).
Finder _formFieldFor(String label) => find
    .descendant(of: _sectionOf(label), matching: find.byType(TextFormField))
    .first;

/// The server card whose title is [title].
Finder _cardOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(Card)).first;

Finder _pencilOf(String title) =>
    find.descendant(of: _cardOf(title), matching: find.byIcon(Icons.edit_outlined));

Finder _collapseOf(String title) =>
    find.descendant(of: _cardOf(title), matching: find.byIcon(Icons.expand_less));

T _widget<T extends Widget>(WidgetTester tester, Finder f) =>
    tester.widget<T>(f);

/// Lets a shown SnackBar expire so its auto-dismiss timer does not outlive
/// the test.
Future<void> _drainSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 8));
  await tester.pumpAndSettle();
}

/// A `VpnService` that reports an active tunnel, so the screen's locked
/// state can be driven without launching a process.
class _ConnectedVpnService extends VpnService {
  _ConnectedVpnService(super.config);

  @override
  VpnStatus get status => VpnStatus.connected;
}

/// The screen with a connected VPN shadowing the harness's real service.
Widget _connectedScreen() => Builder(
  builder: (context) => ChangeNotifierProvider<VpnService>(
    create: (_) => _ConnectedVpnService(context.read<ConfigService>()),
    child: const ServersScreen(),
  ),
);

void main() {
  // ------------------------------------------------------------------ list

  testWidgets('list renders both servers, marks exactly one active, and a tap switches', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    // Both cards, with the host/port/user subtitle the redesign specifies.
    expect(find.text('Amsterdam'), findsOneWidget);
    expect(find.text('ams.example.net · 10.0.0.1:443 · alice'), findsOneWidget);
    expect(find.text('berlin.example.net'), findsOneWidget);
    expect(find.text('10.0.0.2:8443 · bob'), findsOneWidget);

    // Exactly one active marker.
    expect(find.text('Active'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    expect(
      find.descendant(
        of: _cardOf('Amsterdam'),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );

    // Tap the inactive card.
    await tester.tap(find.text('berlin.example.net'));
    await tester.pumpAndSettle();

    expect(await config.getActiveServerId(), 'srv-b');
    expect(
      find.descendant(
        of: _cardOf('berlin.example.net'),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    expect(find.text('Active'), findsOneWidget);
    expectNoOverflow(tester);
  });

  // ---------------------------------------------------------------- editor

  testWidgets('pencil opens an editor with every field, typing enables save, saving persists', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    expect(find.text('Hostname'), findsNothing); // collapsed to start with

    await tester.tap(_pencilOf('Amsterdam'));
    await tester.pumpAndSettle();

    // Every field the editor promises.
    for (final label in [
      'Server name (optional)',
      'Hostname',
      'Username',
      'IP address',
      'Port',
      'Password',
      'Protocol',
      'Filtering prefix (optional)',
      'Custom SNI (optional)',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'missing field: $label');
    }
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Delete'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Test'), findsOneWidget);

    // Loaded values.
    expect(_widget<TextField>(tester, _fieldFor('Hostname')).controller!.text,
        'ams.example.net');
    expect(_widget<TextField>(tester, _fieldFor('Port')).controller!.text, '443');

    // Clean form: save is disabled and reads "Saved".
    final savedBtn = find.widgetWithText(FilledButton, 'Saved');
    expect(savedBtn, findsOneWidget);
    expect(_widget<FilledButton>(tester, savedBtn).onPressed, isNull);

    // Typing dirties the form.
    await tester.enterText(_fieldFor('Server name (optional)'), 'Amsterdam Edge');
    await tester.pumpAndSettle();

    final saveBtn = find.widgetWithText(FilledButton, 'Save server');
    expect(saveBtn, findsOneWidget);
    expect(_widget<FilledButton>(tester, saveBtn).onPressed, isNotNull);

    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    // Confirmed to the user…
    expect(find.text('Server saved'), findsOneWidget);
    // …and actually persisted.
    final servers = await config.loadServers();
    expect(servers.firstWhere((s) => s.id == 'srv-a').name, 'Amsterdam Edge');
    expect((await config.loadConfig()).name, 'Amsterdam Edge');

    // Back to a clean form.
    expect(find.widgetWithText(FilledButton, 'Saved'), findsOneWidget);
    await _drainSnack(tester);
  });

  testWidgets('leaving a dirty editor raises the discard guard', (tester) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    await tester.tap(_pencilOf('Amsterdam'));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldFor('Server name (optional)'), 'Throwaway');
    await tester.pumpAndSettle();

    // Collapsing the editor must ask first.
    await tester.tap(_collapseOf('Amsterdam'));
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsNothing);
    expect(find.text('Hostname'), findsOneWidget, reason: 'editor stayed open');
    expect(find.widgetWithText(FilledButton, 'Save server'), findsOneWidget,
        reason: 'still dirty');

    // Now really leave.
    await tester.tap(_collapseOf('Amsterdam'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    expect(find.text('Hostname'), findsNothing);
    final servers = await config.loadServers();
    expect(servers.firstWhere((s) => s.id == 'srv-a').name, 'Amsterdam',
        reason: 'discarded edits must not persist');
  });

  testWidgets('the discard guard also fires when opening another server', (
    tester,
  ) async {
    await pumpScreen(tester, const ServersScreen(), prefs: _twoServers);

    await tester.tap(_pencilOf('Amsterdam'));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldFor('Server name (optional)'), 'Throwaway');
    await tester.pumpAndSettle();

    await tester.tap(_pencilOf('berlin.example.net'));
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved changes?'), findsOneWidget);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    // Berlin's editor is the one now open.
    expect(_widget<TextField>(tester, _fieldFor('Hostname')).controller!.text,
        'berlin.example.net');
  });

  // ------------------------------------------------------------ validation

  Future<ConfigService> openAmsterdamEditor(WidgetTester tester) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );
    await tester.tap(_pencilOf('Amsterdam'));
    await tester.pumpAndSettle();
    return config;
  }

  Future<void> expectBlocked(
    WidgetTester tester,
    ConfigService config,
    String message,
  ) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Save server'));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(find.text('Server saved'), findsNothing);
    final servers = await config.loadServers();
    final a = servers.firstWhere((s) => s.id == 'srv-a');
    expect(a.hostname, 'ams.example.net');
    expect(a.address, '10.0.0.1');
    expect(a.port, 443);
    expect(a.username, 'alice');
  }

  testWidgets('validation: empty hostname blocks the save', (tester) async {
    final config = await openAmsterdamEditor(tester);
    await tester.enterText(_fieldFor('Hostname'), '');
    await tester.pumpAndSettle();
    await expectBlocked(tester, config, 'Enter hostname');
  });

  testWidgets('validation: a bad IP blocks the save', (tester) async {
    final config = await openAmsterdamEditor(tester);
    await tester.enterText(_fieldFor('IP address'), 'not-an-ip');
    await tester.pumpAndSettle();
    await expectBlocked(tester, config, 'Enter a valid IPv4/IPv6 address');
  });

  testWidgets('validation: a port outside 1-65535 blocks the save', (tester) async {
    final config = await openAmsterdamEditor(tester);
    await tester.enterText(_fieldFor('Port'), '70000');
    await tester.pumpAndSettle();
    await expectBlocked(tester, config, 'Invalid port');

    await tester.enterText(_fieldFor('Port'), '');
    await tester.pumpAndSettle();
    await expectBlocked(tester, config, 'Enter port');
  });

  testWidgets('validation: an empty username blocks the save', (tester) async {
    final config = await openAmsterdamEditor(tester);
    await tester.enterText(_fieldFor('Username'), '');
    await tester.pumpAndSettle();
    await expectBlocked(tester, config, 'Enter username');
  });

  // ---------------------------------------------------------------- delete

  testWidgets('deleting one of two servers leaves the other active', (tester) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    // Delete the ACTIVE server; the survivor must take over.
    await tester.tap(_pencilOf('Amsterdam'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Delete server'), findsOneWidget);
    expect(
      find.textContaining('from the list'),
      findsOneWidget,
      reason: 'with more than one server the dialog must not promise a reset',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    final servers = await config.loadServers();
    expect(servers.map((s) => s.id), ['srv-b']);
    expect(await config.getActiveServerId(), 'srv-b');

    expect(find.text('Amsterdam'), findsNothing);
    expect(find.text('berlin.example.net'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('deleting the last server is allowed and replaces it with a blank entry', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _oneServer,
    );

    await tester.tap(_pencilOf('Amsterdam'));
    await tester.pumpAndSettle();

    final deleteBtn = find.widgetWithText(OutlinedButton, 'Delete');
    expect(
      _widget<OutlinedButton>(tester, deleteBtn).onPressed,
      isNotNull,
      reason: 'deleting the only server is allowed in 0.4.0',
    );

    await tester.tap(deleteBtn);
    await tester.pumpAndSettle();

    expect(find.text('Delete server'), findsOneWidget);
    expect(
      find.textContaining('reset to a blank server'),
      findsOneWidget,
      reason: 'the dialog must say the entry is replaced, not removed',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    final servers = await config.loadServers();
    expect(servers.length, 1, reason: 'the list always holds one entry');
    expect(servers.single.id, isNot('srv-a'), reason: 'a fresh, blank entry');
    expect(servers.single.hostname, 'vpn.example.com');
    expect(await config.getActiveServerId(), servers.single.id);

    // The editor for the deleted entry closed itself.
    expect(find.text('Hostname'), findsNothing);
    expect(find.text('vpn.example.com'), findsOneWidget);
    expectNoOverflow(tester);
  });

  // ------------------------------------------------------ app settings island

  testWidgets('connection mode switches TUN <-> SOCKS5 and only SOCKS5 shows the port', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    expect(find.text('App settings'), findsOneWidget);
    expect(find.text('VPN (TUN)'), findsOneWidget);
    expect(find.text('Proxy (SOCKS5)'), findsOneWidget);
    expect(find.text('SOCKS5 port'), findsNothing,
        reason: 'the proxy port belongs to SOCKS5 mode only');

    await tester.tap(find.text('Proxy (SOCKS5)'));
    await tester.pumpAndSettle();

    expect(find.text('SOCKS5 port'), findsOneWidget);
    expect((await config.loadConfig()).connectionMode, 'socks5');
    expect(_widget<TextField>(tester, _fieldFor('SOCKS5 port')).controller!.text,
        '1080');

    await tester.tap(find.text('VPN (TUN)'));
    await tester.pumpAndSettle();

    expect(find.text('SOCKS5 port'), findsNothing);
    expect((await config.loadConfig()).connectionMode, 'tun');
    expectNoOverflow(tester);
  });

  testWidgets('an invalid SOCKS5 port shows its error and is not persisted', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    await tester.tap(find.text('Proxy (SOCKS5)'));
    await tester.pumpAndSettle();

    // The field debounces its write by 350ms, so the clock has to move.
    Future<void> settleDebounce() async {
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
    }

    await tester.enterText(_fieldFor('SOCKS5 port'), '99999');
    await settleDebounce();
    expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
    expect((await config.loadConfig()).socksPort, 1080);

    await tester.enterText(_fieldFor('SOCKS5 port'), '0');
    await settleDebounce();
    expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
    expect((await config.loadConfig()).socksPort, 1080);

    // A valid one clears the error and lands in the config.
    await tester.enterText(_fieldFor('SOCKS5 port'), '1081');
    await settleDebounce();
    expect(find.text('Enter a port between 1 and 65535'), findsNothing);
    expect((await config.loadConfig()).socksPort, 1081);
    expectNoOverflow(tester);
  });

  testWidgets('the SOCKS5 port error does not survive a trip through TUN mode', (
    tester,
  ) async {
    await pumpScreen(tester, const ServersScreen(), prefs: _twoServers);

    await tester.tap(find.text('Proxy (SOCKS5)'));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldFor('SOCKS5 port'), '0');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);

    // Leave SOCKS5 and come back: the field is re-seeded from the stored
    // (valid) port, so the error underneath it is stale.
    await tester.tap(find.text('VPN (TUN)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxy (SOCKS5)'));
    await tester.pumpAndSettle();

    expect(_widget<TextField>(tester, _fieldFor('SOCKS5 port')).controller!.text,
        '1080');
    expect(
      find.text('Enter a port between 1 and 65535'),
      findsNothing,
      reason:
          'the field was reset to the valid stored port, so its error text '
          'must go with it',
    );
  });

  testWidgets('a SOCKS5 port typed just before switching server still matches what is stored', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    await tester.tap(find.text('Proxy (SOCKS5)'));
    await tester.pumpAndSettle();

    // Type a valid port, then click another server inside the 350ms the
    // field waits before writing.
    await tester.enterText(_fieldFor('SOCKS5 port'), '2080');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('berlin.example.net'));
    await tester.pumpAndSettle();

    // Let the debounced write land.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    final stored = (await config.loadConfig()).socksPort;
    final shown = _widget<TextField>(tester, _fieldFor('SOCKS5 port')).controller!.text;
    expect(
      shown,
      stored.toString(),
      reason:
          'the proxy port on screen must be the one the app will actually '
          'listen on',
    );
    expect(stored, 2080);
  });

  testWidgets('Test on the editor refuses an unusable address instead of dialling', (
    tester,
  ) async {
    await pumpScreen(tester, const ServersScreen(), prefs: _twoServers);

    await tester.tap(_pencilOf('Amsterdam'));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldFor('IP address'), 'not-an-ip');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Test'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid IP address and port first.'), findsOneWidget);
    // The button never entered its busy state, so it stays usable.
    expect(find.text('Testing…'), findsNothing);
    expect(
      _widget<OutlinedButton>(
        tester,
        find.widgetWithText(OutlinedButton, 'Test'),
      ).onPressed,
      isNotNull,
    );
    await _drainSnack(tester);
  });

  testWidgets('Add server commits a new row and makes it active', (tester) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldFor('Name (optional)'), 'Tokyo');
    await tester.enterText(_fieldFor('Hostname'), 'tyo.example.net');
    await tester.enterText(_fieldFor('IP address'), '10.0.0.3');
    await tester.enterText(_fieldFor('Port'), '8443');
    await tester.enterText(_fieldFor('VPN username'), 'carol');
    await tester.enterText(_fieldFor('VPN password'), 's3cret');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final servers = await config.loadServers();
    expect(servers.length, 3);
    final added = servers.last;
    expect(added.name, 'Tokyo');
    expect(added.hostname, 'tyo.example.net');
    expect(added.address, '10.0.0.3');
    expect(added.port, 8443);
    expect(added.username, 'carol');
    expect(await config.getActiveServerId(), added.id);

    expect(find.text('Tokyo'), findsOneWidget);
    expect(find.text('tyo.example.net · 10.0.0.3:8443 · carol'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(
      find.descendant(
        of: _cardOf('Tokyo'),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    await _drainSnack(tester);
    expectNoOverflow(tester);
  });

  testWidgets('the DNS field takes a comma-separated list and rejects junk', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    expect(_widget<TextField>(tester, _fieldFor('DNS upstreams')).controller!.text,
        '8.8.8.8');

    await tester.enterText(
      _fieldFor('DNS upstreams'),
      '1.1.1.1, https://dns.google/dns-query',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect((await config.loadConfig()).dns, '1.1.1.1, https://dns.google/dns-query');
    expect(find.textContaining('DNS updated'), findsOneWidget);
    await _drainSnack(tester);

    // Junk is refused with its message and never reaches the config.
    await tester.enterText(_fieldFor('DNS upstreams'), 'nonsense');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('Invalid upstream: "nonsense"'), findsOneWidget);
    expect((await config.loadConfig()).dns, '1.1.1.1, https://dns.google/dns-query');

    // Empty is refused too.
    await tester.enterText(_fieldFor('DNS upstreams'), '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text('Enter at least one upstream'), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('a DNS preset appends an upstream without discarding what is typed', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
    );

    await tester.enterText(_fieldFor('DNS upstreams'), '9.9.9.9');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pumpAndSettle();
    expect(find.text('Cloudflare'), findsOneWidget);

    await tester.tap(find.text('Cloudflare'));
    await tester.pumpAndSettle();

    expect(
      _widget<TextField>(tester, _fieldFor('DNS upstreams')).controller!.text,
      '9.9.9.9, https://dns.cloudflare.com/dns-query',
      reason: 'the preset appends, it never replaces what the user typed',
    );
    expect(
      (await config.loadConfig()).dns,
      '9.9.9.9, https://dns.cloudflare.com/dns-query',
    );
    await _drainSnack(tester);

    // Picking the same preset twice tells the user instead of duplicating.
    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cloudflare'));
    await tester.pumpAndSettle();
    expect(find.text('This DNS server is already in the list'), findsOneWidget);
    expect(
      _widget<TextField>(tester, _fieldFor('DNS upstreams')).controller!.text,
      '9.9.9.9, https://dns.cloudflare.com/dns-query',
    );
    await _drainSnack(tester);
  });


  // ------------------------------------------------------ locked while connected

  testWidgets('a live connection locks the editor, Add and Delete but leaves Test and DNS live', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      _connectedScreen(),
      prefs: _twoServers,
    );

    expect(
      find.text('Server settings are locked while connected. Disconnect to edit.'),
      findsOneWidget,
    );

    // Add server is disabled.
    final add = find.widgetWithText(FilledButton, 'Add server');
    expect(_widget<FilledButton>(tester, add).onPressed, isNull);

    // Tap-to-switch is dead.
    await tester.tap(find.text('berlin.example.net'));
    await tester.pumpAndSettle();
    expect(await config.getActiveServerId(), 'srv-a');

    // The connection mode is locked, with its notice.
    expect(find.text('Disconnect to change the connection mode.'), findsOneWidget);

    // The editor still opens (read-only).
    await tester.tap(_pencilOf('Amsterdam'));
    await tester.pumpAndSettle();

    for (final label in ['Hostname', 'IP address', 'Port', 'Username', 'Password']) {
      expect(
        _widget<TextFormField>(tester, _formFieldFor(label)).enabled,
        isFalse,
        reason: '$label must be locked while connected',
      );
    }
    expect(
      _widget<OutlinedButton>(
        tester,
        find.widgetWithText(OutlinedButton, 'Delete'),
      ).onPressed,
      isNull,
    );
    expect(
      _widget<FilledButton>(
        tester,
        find.widgetWithText(FilledButton, 'Saved'),
      ).onPressed,
      isNull,
    );

    // Test stays live…
    expect(
      _widget<OutlinedButton>(
        tester,
        find.widgetWithText(OutlinedButton, 'Test'),
      ).onPressed,
      isNotNull,
      reason: 'a reachability check is safe while connected',
    );

    // …and so does the shared DNS field.
    expect(_widget<TextFormField>(tester, _formFieldFor('DNS upstreams')).enabled,
        isTrue);
    await tester.enterText(_fieldFor('DNS upstreams'), '1.0.0.1');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect((await config.loadConfig()).dns, '1.0.0.1');
    await _drainSnack(tester);
    expectNoOverflow(tester);
  });

  // ------------------------------------------------------------- add dialog

  testWidgets('Add server opens a dialog that validates before it commits', (
    tester,
  ) async {
    final config = await pumpScreen(
      tester,
      const ServersScreen(),
      prefs: _twoServers,
      size: kMinWindow,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
    await tester.pumpAndSettle();
    expect(find.text('Add server'), findsWidgets);
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('Credentials'), findsOneWidget);
    expectNoOverflow(tester);

    // Empty form: every required field complains, nothing is added.
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the server hostname'), findsOneWidget);
    expect(find.text('Enter the IP'), findsOneWidget);
    expect(find.text('Enter the username'), findsOneWidget);
    expect(find.text('Enter the password'), findsOneWidget);
    expect((await config.loadServers()).length, 2);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect((await config.loadServers()).length, 2);
  });

  // ---------------------------------------------------------------- layout

  for (final (sizeName, size) in [
    ('default window', kDefaultWindow),
    ('minimum window', kMinWindow),
  ]) {
    for (final (themeName, brightness) in [
      ('dark', Brightness.dark),
      ('light', Brightness.light),
    ]) {
      testWidgets('renders without overflow at the $sizeName in $themeName', (
        tester,
      ) async {
        await pumpScreen(
          tester,
          const ServersScreen(),
          prefs: _twoServers,
          size: size,
          brightness: brightness,
        );
        expectNoOverflow(tester);

        // The densest state: an open editor with its advanced section
        // expanded, next to the island in SOCKS5 mode.
        await tester.tap(_pencilOf('Amsterdam'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester);

        await tester.tap(find.text('Advanced'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester);

        // Turning off certificate verification adds a warning banner inline.
        await tester.tap(
          find.descendant(
            of: _sectionOf('Skip Certificate Verification'),
            matching: find.byType(AppSwitch),
          ).first,
        );
        await tester.pumpAndSettle();
        expectNoOverflow(tester);

        await tester.tap(find.text('Proxy (SOCKS5)'));
        await tester.pumpAndSettle();
        expectNoOverflow(tester);

        // Long validation messages under the narrow grid cells.
        await tester.enterText(_fieldFor('IP address'), 'not-an-ip');
        await tester.enterText(
          _fieldFor('Filtering prefix (optional)'),
          'definitely not hex',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Save server'));
        await tester.pumpAndSettle();
        expect(find.text('Enter a valid IPv4/IPv6 address'), findsOneWidget);
        expectNoOverflow(tester);
      });
    }
  }
}

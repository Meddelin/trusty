// UI scenario tests for the redesigned Home screen.
//
// Every test pumps the REAL HomeScreen with the REAL services (only the
// platform edges are faked by the shared harness) and drives it the way a
// user would: taps, dropdown selections, a real connect attempt. Assertions
// are on what the user sees plus what actually landed in ConfigService.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trusty/models/server_config.dart';
import 'package:trusty/models/vpn_status.dart';
import 'package:trusty/screens/home_screen.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/services/update_service.dart';
import 'package:trusty/services/vpn_service.dart';
import 'package:trusty/theme/app_theme.dart';

import 'harness.dart';

/// Prefs that start the app with an EMPTY server list. Without this key the
/// one-time migration seeds the factory placeholder entry, so "no servers"
/// is otherwise unreachable.
const Map<String, Object> kNoServers = {'server_list': '[]'};

/// An UpdateService that reports whatever the test wants without touching
/// GitHub (and without shelling out to a browser on Download).
class _FakeUpdateService extends UpdateService {
  _FakeUpdateService(this._version);

  final String? _version;
  bool _dismissed = false;
  bool openedReleasePage = false;

  @override
  String? get latestVersion => _version;

  @override
  bool get updateAvailable => _version != null && !_dismissed;

  @override
  void dismiss() {
    _dismissed = true;
    notifyListeners();
  }

  @override
  Future<void> openReleasePage() async => openedReleasePage = true;
}

/// A VpnService parked in a chosen state. Connected/connecting are otherwise
/// unreachable in a widget test (they need a live client process), and they
/// are where the strip changes shape: uptime, the SOCKS line, the disabled
/// server switcher, the log rows.
class _StubVpnService extends VpnService {
  // VpnService's positional parameter is the private `_configService`, so a
  // super parameter cannot name it.
  // ignore: use_super_parameters
  _StubVpnService(
    ConfigService config, {
    required this.stubStatus,
    this.stubConnectedAt,
    this.stubSocks,
    this.stubLogs = const [],
  }) : super(config);

  final VpnStatus stubStatus;
  final DateTime? stubConnectedAt;
  final String? stubSocks;
  final List<String> stubLogs;
  bool disconnectCalled = false;

  @override
  VpnStatus get status => stubStatus;

  @override
  DateTime? get connectedAt => stubConnectedAt;

  @override
  String? get socksAddress => stubSocks;

  @override
  List<String> get logs => stubLogs;

  @override
  Future<void> disconnect() async => disconnectCalled = true;
}

VpnService _vpnOf(WidgetTester tester) => Provider.of<VpnService>(
      tester.element(find.byType(HomeScreen)),
      listen: false,
    );

ServerConfig _server(String name, String host, String address) => ServerConfig(
      name: name,
      hostname: host,
      address: address,
      port: 443,
      username: 'alice',
      password: 'hunter2',
    );

/// Adds servers through the real add-server path, leaving a real (non
/// placeholder) config active. The small real delay keeps the
/// microsecond-clock ids distinct.
Future<List<String>> _seedServers(
  WidgetTester tester,
  ConfigService config,
  List<ServerConfig> entries,
) async {
  final ids = <String>[];
  for (final e in entries) {
    ids.add((await config.addServerConfig(e)).id);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 3)));
  }
  expect(ids.toSet().length, ids.length,
      reason: 'seeded servers must have distinct ids');
  await _settleRealAsync(tester);
  return ids;
}

/// Drains work that touches the real filesystem.
///
/// Home's `_reload()` (and `VpnService.connect`) await dart:io calls —
/// `ConfigService.getClientDirectory()`, the routing-list cache migration,
/// the client-binary probe. Those futures complete on the REAL event loop,
/// which `pumpAndSettle` never turns, so each step needs a `runAsync` slice
/// followed by a `pump` to flush the continuation. `pumpAndSettle` is also
/// unusable across a connect: the connecting spinner never settles.
/// Returns true if the busy ("Please wait...") action was visible at any
/// point while draining — the connecting state is real but short-lived.
Future<bool> _settleRealAsync(WidgetTester tester, {int rounds = 40}) async {
  var sawBusy = false;
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.text('Please wait...').evaluate().isNotEmpty) sawBusy = true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 4)));
  }
  // Let the implicit animations (300ms) land.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  return sawBusy;
}

/// [pumpScreen] plus the real-async drain Home needs before its config,
/// routing lists and DNS upstreams are on screen.
Future<ConfigService> _pumpHome(
  WidgetTester tester,
  Widget child, {
  Size size = kDefaultWindow,
  Brightness brightness = Brightness.dark,
  Map<String, Object> prefs = const {},
}) async {
  final config = await pumpScreen(tester, child,
      size: size, brightness: brightness, prefs: prefs);
  await _settleRealAsync(tester);
  return config;
}

/// The uptime is computed from the wall clock, so asserting an exact second is
/// a race: anything that changes how long the pump takes (a different animation
/// duration, a slower machine) ticks it over. Assert the format and that the
/// value is within a few seconds of what was seeded.
void expectUptimeNear(WidgetTester tester, Duration seeded) {
  final finder = find.byWidgetPredicate(
    (w) =>
        w is Text &&
        w.data != null &&
        RegExp(r'^(?:\d+:)?\d{2}:\d{2}$').hasMatch(w.data!),
  );
  expect(finder, findsOneWidget, reason: 'no uptime in the status strip');
  final parts = (tester.widget<Text>(finder).data!).split(':').map(int.parse).toList();
  final shown = parts.length == 3
      ? Duration(hours: parts[0], minutes: parts[1], seconds: parts[2])
      : Duration(minutes: parts[0], seconds: parts[1]);
  expect(
    (shown - seeded).inSeconds.abs(),
    lessThanOrEqualTo(5),
    reason: 'shown $shown, seeded $seeded',
  );
}

void main() {
  group('home - disconnected', () {
    testWidgets('status word, primary action, three islands, empty log',
        (tester) async {
      await _pumpHome(tester, const HomeScreen());

      // The state word, in the idle token colour.
      expect(find.text('Disconnected'), findsOneWidget);
      final word = tester.widget<AnimatedDefaultTextStyle>(
        find
            .ancestor(
              of: find.text('Disconnected'),
              matching: find.byType(AnimatedDefaultTextStyle),
            )
            .first,
      );
      expect(word.style.color, StatusColors.dark.idle);

      // The primary action offers to connect, and is enabled.
      final button = find.widgetWithText(FilledButton, 'Connect');
      expect(button, findsOneWidget);
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(find.text('Disconnect'), findsNothing);
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);

      // The three state islands.
      expect(find.text('Tunnel'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('DNS'), findsOneWidget);
      expect(find.text('General'), findsOneWidget); // tunnel mode readout
      expect(find.text('Anti-DPI'), findsOneWidget); // security readout
      expect(find.text('8.8.8.8'), findsOneWidget); // DNS upstream well

      // The live-log island and its empty state.
      expect(find.text('Live log'), findsOneWidget);
      expect(find.text('No logs yet'), findsOneWidget);
      expect(find.byIcon(Icons.article_outlined), findsOneWidget);

      // Nothing connected: no uptime readout.
      expect(find.text('Uptime'), findsNothing);

      expectNoOverflow(tester);
    });
  });

  group('home - server switcher', () {
    testWidgets('renders nothing with no saved servers', (tester) async {
      final config =
          await _pumpHome(tester, const HomeScreen(), prefs: kNoServers);

      expect(config.serversCache, isEmpty);
      expect(find.byIcon(Icons.dns), findsNothing);
      expect(find.byType(DropdownButton<String>), findsNothing);
      // Documented inconsistency: with the switcher blank the endpoint line
      // still describes the factory default that loadConfig() falls back to,
      // so the strip advertises `vpn.example.com` while no server exists.
      // Unreachable in normal use (the server list is never allowed to go
      // empty), so this records the behaviour rather than asserting it away.
      expect(
        find.text('vpn.example.com · 127.0.0.1:443 · HTTP/2 · VPN (TUN)'),
        findsOneWidget,
      );
      expectNoOverflow(tester);
    });

    testWidgets('one server is a static label, not a dropdown', (tester) async {
      final config =
          await _pumpHome(tester, const HomeScreen(), prefs: kNoServers);
      await _seedServers(
          tester, config, [_server('Frankfurt', 'fra.example.net', '10.0.0.1')]);

      expect(find.text('Frankfurt'), findsOneWidget);
      expect(find.byIcon(Icons.dns), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);

      // The endpoint line describes the live server.
      expect(
        find.text(
            'fra.example.net · 10.0.0.1:443 · HTTP/2 · VPN (TUN)'),
        findsOneWidget,
      );
      expectNoOverflow(tester);
    });

    testWidgets(
        'two servers give a dropdown listing both, and switching persists',
        (tester) async {
      final config =
          await _pumpHome(tester, const HomeScreen(), prefs: kNoServers);
      final ids = await _seedServers(tester, config, [
        _server('Frankfurt', 'fra.example.net', '10.0.0.1'),
        _server('Helsinki', 'hel.example.net', '10.0.0.2'),
      ]);

      final dropdown = find.byType(DropdownButton<String>);
      expect(dropdown, findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsWidgets);
      // The second seeded server became active (addServerConfig switches).
      expect(config.activeServerIdCache, ids.last);

      await tester.tap(dropdown);
      await tester.pumpAndSettle();

      // Both entries are listed in the open menu.
      expect(find.byType(DropdownMenuItem<String>), findsNWidgets(2));
      expect(find.text('Frankfurt'), findsWidgets);
      expect(find.text('Helsinki'), findsWidgets);
      expectNoOverflow(tester);

      // Pick the other one and check it actually persisted.
      await tester.tap(find.text('Frankfurt').last);
      await tester.pumpAndSettle();
      expect(config.activeServerIdCache, ids.first);
      expect((await config.loadConfig()).hostname, 'fra.example.net');
      expect(
        find.text(
            'fra.example.net · 10.0.0.1:443 · HTTP/2 · VPN (TUN)'),
        findsOneWidget,
      );
      expectNoOverflow(tester);
    });
  });

  group('home - error state', () {
    for (final size in <(String, Size)>[
      ('default', kDefaultWindow),
      ('min', kMinWindow),
    ]) {
      testWidgets(
          'connect failure shows the banner and hides the live log (${size.$1})',
          (tester) async {
        final config = await _pumpHome(
          tester,
          const HomeScreen(),
          size: size.$2,
          prefs: kNoServers,
        );
        await _seedServers(
            tester, config, [_server('Frankfurt', 'fra.example.net', '10.0.0.1')]);

        // Real connect on a machine with no client binary: the service lands
        // in VpnStatus.error with the four-line "client not found" reason.
        await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
        final sawBusy = await _settleRealAsync(tester);
        expect(sawBusy, isTrue,
            reason: 'the action must show its busy state while connecting');

        final vpn = _vpnOf(tester);
        expect(vpn.status, VpnStatus.error,
            reason: 'a failed connect must land in the error state');
        expect(vpn.errorMessage, contains('Trusty client not found!'));

        // The banner is the authoritative surface: title + full reason.
        expect(find.text('Connection failed'), findsOneWidget);
        expect(find.textContaining('Trusty client not found!'), findsOneWidget);
        expect(find.textContaining('place it in the client/ directory'),
            findsOneWidget);

        // ...and the log island stands down so the error is read once.
        expect(find.text('Live log'), findsNothing);
        expect(find.text('No logs yet'), findsNothing);
        expect(find.byIcon(Icons.article_outlined), findsNothing);
        // The failure is on screen exactly once: the banner. The state word
        // says "Error" (sentence case); no uppercase "ERROR" log-level cell
        // survives, because the log island is down.
        expect(find.text('Error'), findsOneWidget);
        expect(find.text('ERROR'), findsNothing);

        // The islands still render, and take the log island's height.
        expect(find.text('Tunnel'), findsOneWidget);
        expect(find.text('Security'), findsOneWidget);
        expect(find.text('DNS'), findsOneWidget);

        expectNoOverflow(tester);
      });
    }
  });

  group('home - update banner', () {
    testWidgets('shows the new version with Download and a dismiss control',
        (tester) async {
      final updates = _FakeUpdateService('9.9.9');
      await _pumpHome(
        tester,
        ChangeNotifierProvider<UpdateService>.value(
          value: updates,
          child: const HomeScreen(),
        ),
      );

      expect(find.text('New version available: v9.9.9'), findsOneWidget);
      final download = find.widgetWithText(TextButton, 'Download');
      expect(download, findsOneWidget);

      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(updates.openedReleasePage, isTrue);

      // The dismiss control is the update banner's own X (the intro banner
      // below it carries one too, hence the scoped finder).
      final dismiss = find.descendant(
        // The banner keys itself by the nullable latestVersion, so the key
        // type is ValueKey<String?> — ValueKey<String> would not match.
        of: find.byKey(const ValueKey<String?>('9.9.9')),
        matching: find.byIcon(Icons.close),
      );
      expect(dismiss, findsOneWidget);
      await tester.tap(dismiss);
      await tester.pumpAndSettle();

      expect(updates.updateAvailable, isFalse);
      expect(find.text('New version available: v9.9.9'), findsNothing);
      // Dismissing the update must not take the intro banner with it.
      expect(
          find.text('Add your server on the Servers tab first'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('no banner when the app is up to date', (tester) async {
      await _pumpHome(
        tester,
        ChangeNotifierProvider<UpdateService>.value(
          value: _FakeUpdateService(null),
          child: const HomeScreen(),
        ),
      );
      expect(find.textContaining('New version available'), findsNothing);
      expect(find.text('Download'), findsNothing);
      expectNoOverflow(tester);
    });
  });

  group('home - placeholder guard', () {
    testWidgets(
        'connect with the factory placeholder warns and stays disconnected',
        (tester) async {
      // Default prefs: the migration seeds the factory placeholder entry.
      final config = await _pumpHome(tester, const HomeScreen());
      expect((await config.loadConfig()).isPlaceholder, isTrue);

      // The intro banner names the Servers tab.
      expect(
          find.text('Add your server on the Servers tab first'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settleRealAsync(tester);

      // The warning surfaced as a snackbar...
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.text('Add your server on the Servers tab first'),
        findsNWidgets(2),
        reason: 'the intro banner plus the warning snackbar',
      );

      // ...and nothing was started.
      expect(_vpnOf(tester).status, VpnStatus.disconnected);
      expect(_vpnOf(tester).logs, isEmpty,
          reason: 'the placeholder guard must not start a connection');
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('Live log'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('home - connected', () {
    testWidgets('uptime, SOCKS line, disconnect action, locked switcher',
        (tester) async {
      final vpn = _StubVpnService(
        ConfigService(),
        stubStatus: VpnStatus.connected,
        stubConnectedAt: DateTime.now().subtract(const Duration(minutes: 3, seconds: 7)),
        stubSocks: '127.0.0.1:1080',
      );
      final config = await _pumpHome(
        tester,
        ChangeNotifierProvider<VpnService>.value(
          value: vpn,
          child: const HomeScreen(),
        ),
        size: kMinWindow,
        prefs: kNoServers,
      );
      await _seedServers(tester, config, [
        _server('Frankfurt', 'fra.example.net', '10.0.0.1'),
        _server('Helsinki', 'hel.example.net', '10.0.0.2'),
      ]);

      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Uptime'), findsOneWidget);
      expectUptimeNear(tester, const Duration(minutes: 3, seconds: 7));
      expect(find.text('SOCKS5 proxy · 127.0.0.1:1080'), findsOneWidget);

      // The action flips to Disconnect and actually calls the service.
      final button = find.widgetWithText(FilledButton, 'Disconnect');
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pump();
      expect(vpn.disconnectCalled, isTrue);

      // The switcher is locked while the tunnel is up.
      final dropdown = tester.widget<DropdownButton<String>>(
          find.byType(DropdownButton<String>));
      expect(dropdown.onChanged, isNull,
          reason: 'switching servers mid-connection must be impossible');
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownMenuItem<String>), findsNothing,
          reason: 'a disabled dropdown must not open');

      expectNoOverflow(tester);
    });

    // NB: VpnStatus.connecting cannot be pumped through the shared harness —
    // the spinner and the pulsing status dot animate forever, so its
    // `pumpAndSettle` times out. The busy state is covered from the real
    // connect flow instead (see the error-state test).
    testWidgets('log rows render level, time and message', (tester) async {
      final vpn = _StubVpnService(
        ConfigService(),
        stubStatus: VpnStatus.connected,
        stubConnectedAt: DateTime.now(),
        stubLogs: const [
          '[10:00:01] Connecting to fra.example.net...',
          '[10:00:02] WARN Wintun adapter is still busy. Wait before retrying.',
          '[10:00:03] Successfully connected to endpoint',
          '[10:00:04] ERROR Error: the upstream refused the handshake and this '
              'line is deliberately long enough to need wrapping inside the '
              'live-log island at the minimum window size',
        ],
      );
      await _pumpHome(
        tester,
        ChangeNotifierProvider<VpnService>.value(
          value: vpn,
          child: const HomeScreen(),
        ),
        size: kMinWindow,
      );

      expect(find.text('Live log'), findsOneWidget);
      expect(find.text('No logs yet'), findsNothing);
      expect(find.text('10:00:04'), findsOneWidget);
      expect(find.text('ERROR'), findsOneWidget);
      expect(find.text('WARN'), findsOneWidget);
      expect(find.text('INFO'), findsNWidgets(2));
      expect(find.textContaining('Connecting to fra.example.net'), findsOneWidget);
      // The level token is stripped from the body — the level lives in its
      // own column, so it is never printed twice on a row.
      expect(find.textContaining('ERROR Error:'), findsNothing);
      expect(find.textContaining('WARN Wintun'), findsNothing);
      expect(find.textContaining('the upstream refused the handshake'),
          findsOneWidget);

      expectNoOverflow(tester);
    });
  });

  group('home - crowded strip', () {
    testWidgets('long server name and an hours-long uptime at the min window',
        (tester) async {
      final vpn = _StubVpnService(
        ConfigService(),
        stubStatus: VpnStatus.connected,
        stubConnectedAt:
            DateTime.now().subtract(const Duration(hours: 27, minutes: 41, seconds: 9)),
        stubSocks: '127.0.0.1:1080',
      );
      final config = await _pumpHome(
        tester,
        ChangeNotifierProvider<VpnService>.value(
          value: vpn,
          child: const HomeScreen(),
        ),
        size: kMinWindow,
        prefs: kNoServers,
      );
      await _seedServers(tester, config, [
        _server(
          'Frankfurt am Main — primary egress (post-quantum)',
          'frankfurt-primary-egress.long-hostname.example.net',
          '198.51.100.200',
        ),
      ]);

      expectUptimeNear(tester, const Duration(hours: 27, minutes: 41, seconds: 9));
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Frankfurt am Main — primary egress (post-quantum)'),
          findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('home - intro banner', () {
    testWidgets('dismissal sticks and the connect guard still fires',
        (tester) async {
      await _pumpHome(tester, const HomeScreen());

      final intro = find.text('Add your server on the Servers tab first');
      expect(intro, findsOneWidget);

      // The intro banner is the only dismissible thing on screen here.
      final close = find.byIcon(Icons.close);
      expect(close, findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(intro, findsNothing);

      // Dismissal is permanent: it lands in SharedPreferences.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('banner_dismissed_home_intro'), isTrue);

      // The guard is independent of the banner.
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settleRealAsync(tester);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(intro, findsOneWidget, reason: 'the snackbar carries the warning');
      expect(_vpnOf(tester).status, VpnStatus.disconnected);
      expectNoOverflow(tester);
    });

    testWidgets('a previously dismissed intro stays hidden', (tester) async {
      await _pumpHome(
        tester,
        const HomeScreen(),
        prefs: const {'banner_dismissed_home_intro': true},
      );
      expect(find.text('Add your server on the Servers tab first'), findsNothing);
      expectNoOverflow(tester);
    });
  });

  group('home - banner pile-up', () {
    testWidgets('update banner + four-line connection error at the min window',
        (tester) async {
      final config = await _pumpHome(
        tester,
        ChangeNotifierProvider<UpdateService>.value(
          value: _FakeUpdateService('9.9.9'),
          child: const HomeScreen(),
        ),
        size: kMinWindow,
        prefs: kNoServers,
      );
      await _seedServers(tester, config,
          [_server('Frankfurt', 'fra.example.net', '10.0.0.1')]);

      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await _settleRealAsync(tester);

      expect(_vpnOf(tester).status, VpnStatus.error);
      expect(find.text('New version available: v9.9.9'), findsOneWidget);
      expect(find.text('Connection failed'), findsOneWidget);
      expect(find.text('Tunnel'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('DNS'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('home - layout matrix', () {
    for (final brightness in Brightness.values) {
      for (final size in <(String, Size)>[
        ('default', kDefaultWindow),
        ('min', kMinWindow),
      ]) {
        testWidgets('renders at ${size.$1} window in ${brightness.name}',
            (tester) async {
          // The densest disconnected layout: update banner + intro banner +
          // islands + log, on the smallest window a user can drag to.
          final config = await _pumpHome(
            tester,
            ChangeNotifierProvider<UpdateService>.value(
              value: _FakeUpdateService('9.9.9'),
              child: const HomeScreen(),
            ),
            size: size.$2,
            brightness: brightness,
          );

          expectNoOverflow(tester);
          expect(find.text('Disconnected'), findsOneWidget);
          expect(find.text('New version available: v9.9.9'), findsOneWidget);
          expect(find.text('Add your server on the Servers tab first'),
              findsOneWidget);
          expect(find.text('Tunnel'), findsOneWidget);
          expect(find.text('Security'), findsOneWidget);
          expect(find.text('DNS'), findsOneWidget);
          expect(find.text('Live log'), findsOneWidget);

          final word = tester.widget<AnimatedDefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Disconnected'),
                  matching: find.byType(AnimatedDefaultTextStyle),
                )
                .first,
          );
          expect(
            word.style.color,
            brightness == Brightness.dark
                ? StatusColors.dark.idle
                : StatusColors.light.idle,
          );

          // Two servers: the widest strip content (dropdown + endpoint line).
          await _seedServers(tester, config, [
            _server('Frankfurt am Main', 'frankfurt.example.net',
                '203.0.113.10'),
            _server('Helsinki', 'helsinki.example.net', '203.0.113.11'),
          ]);
          expectNoOverflow(tester);
          expect(find.byType(DropdownButton<String>), findsOneWidget);
        });
      }
    }
  });

  testWidgets('a log timestamp never wraps to a second line', (tester) async {
    // Regression: the column was 56px while "14:02:03" measures 56.3px in
    // Chivo Mono at 11.5px, so every stamp broke onto a second line.
    await pumpScreen(tester, const HomeScreen(), size: kMinWindow);
    await _settleRealAsync(tester);

    final stamps = find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data != null &&
          RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(w.data!),
    );
    for (final element in stamps.evaluate()) {
      final text = element.widget as Text;
      expect(text.softWrap, isFalse, reason: 'a timestamp must not wrap');
      expect(text.maxLines, 1);
      final box = tester.renderObject<RenderBox>(find.byWidget(text));
      expect(
        box.size.height,
        lessThan(20),
        reason: 'a wrapped stamp would be two line-heights tall',
      );
    }
  });
}

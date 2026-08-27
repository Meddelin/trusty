// UI scenario tests for the redesigned Logs screen.
//
// The screen is pumped for real: real ConfigService (backed by the harness's
// mock SharedPreferences), real theme, real localisations, real interaction.
//
// One seam is needed. `VpnService` has no public way to append a log line —
// `_addLog` is private and only the connect/disconnect machinery calls it —
// so the streaming scenarios use a subclass that substitutes the log buffer
// and nothing else (`logs` and `clearLogs` are the entire surface the Logs
// screen reads). Every other behaviour, including the change notifications
// the screen folds on, is the real service's.
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trusty/l10n/app_localizations.dart';
import 'package:trusty/screens/logs_screen.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/services/server_setup_service.dart';
import 'package:trusty/services/update_service.dart';
import 'package:trusty/services/vpn_service.dart';
import 'package:trusty/theme/app_theme.dart';
import 'package:trusty/utils/localization_helper.dart';

import 'harness.dart';

/// The real service with a test-controlled buffer. Only the two members the
/// Logs screen touches are overridden; notifications go through the real
/// `ChangeNotifier`, so the screen's fold/diff path is exercised as shipped.
class _FakeVpnService extends VpnService {
  _FakeVpnService(super.config);

  final List<String> _lines = <String>[];
  final List<void Function(String)> _observers = <void Function(String)>[];

  @override
  List<String> get logs => List.unmodifiable(_lines);

  @override
  void clearLogs() {
    _lines.clear();
    notifyListeners();
  }

  // Same contract as the real `_addLog`: append, then call every observer with
  // the entry, then notify listeners.
  @override
  void addLogObserver(void Function(String) observer) => _observers.add(observer);

  @override
  void removeLogObserver(void Function(String) observer) =>
      _observers.remove(observer);

  void push(String line) {
    _lines.add(line);
    for (final observer in _observers) {
      observer(line);
    }
    notifyListeners();
  }

  void pushAll(Iterable<String> lines) {
    for (final line in lines) {
      _lines.add(line);
      for (final observer in _observers) {
        observer(line);
      }
    }
    notifyListeners();
  }
}

/// Same provider/theme boot as `pumpScreen`, but with the log-buffer seam in
/// place so a test can stream lines through the screen.
Future<({ConfigService config, _FakeVpnService vpn})> pumpLogsWithVpn(
  WidgetTester tester, {
  List<String> logs = const [],
  Size size = kDefaultWindow,
  Brightness brightness = Brightness.dark,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(Map<String, Object>.from(prefs));
  stubPlatformChannels();

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final config = ConfigService();
  final vpn = _FakeVpnService(config);
  vpn.pushAll(logs);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ConfigService>.value(value: config),
        ChangeNotifierProvider<VpnService>.value(value: vpn),
        ChangeNotifierProvider<ServerSetupService>(create: (_) => ServerSetupService()),
        ChangeNotifierProvider<UpdateService>(create: (_) => UpdateService()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(brightness),
        builder: (context, inner) {
          L10n.init(AppLocalizations.of(context)!);
          return inner!;
        },
        home: const Scaffold(body: LogsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(milliseconds: 600));
  return (config: config, vpn: vpn);
}

/// A session that exercises every level. The app's own messages carry their
/// severity as a leading token; a message without one is info.
const _session = <String>[
  '[10:00:01] Starting Trusty client...',
  '[10:00:02] Using config trusttunnel_client.toml',
  '[10:00:03] WARN Wintun adapter still busy, retrying',
  '[10:00:04] ERROR Error: handshake failed',
  '[10:00:05] DEBUG upstream negotiated http2',
  '[10:00:06] Connected successfully!',
];

/// Seeds a stored server entry so `ConfigService.loadConfig` takes the real
/// path (a bare `app_log_level` key is ignored when no server JSON exists).
Map<String, Object> _prefsWithLogLevel(String level) => {
      'server_config': jsonEncode({
        'id': 's1',
        'name': 'Test',
        'hostname': 'vpn.example.com',
        'logLevel': level,
      }),
      'app_log_level': level,
    };

/// The enabled/disabled state of an outlined action, by its label.
bool _actionEnabled(WidgetTester tester, String label) {
  final button = tester.widget<OutlinedButton>(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(OutlinedButton),
    ).first,
  );
  return button.onPressed != null;
}

void main() {
  setUpAll(loadShippedFonts);
  group('logs · empty state', () {
    testWidgets('renders the empty copy and disables copy/clear', (tester) async {
      await pumpScreen(tester, const LogsScreen());

      expect(find.text('No logs yet'), findsOneWidget);
      expect(find.text('Connect to VPN to see logs'), findsOneWidget);
      expect(find.textContaining('0 lines'), findsOneWidget);

      expect(_actionEnabled(tester, 'Copy logs'), isFalse,
          reason: 'nothing to copy when the buffer is empty');
      expect(_actionEnabled(tester, 'Clear logs'), isFalse,
          reason: 'nothing to clear when the buffer is empty');

      expectNoOverflow(tester);
    });

    testWidgets('empty state survives the minimum window, dark', (tester) async {
      await pumpScreen(tester, const LogsScreen(), size: kMinWindow);
      expect(find.text('No logs yet'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('empty state survives the minimum window, light', (tester) async {
      await pumpScreen(tester, const LogsScreen(),
          size: kMinWindow, brightness: Brightness.light);
      expect(find.text('No logs yet'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('logs · streaming', () {
    testWidgets('lines pushed after the first frame appear in the console',
        (tester) async {
      final ctx = await pumpLogsWithVpn(tester);
      expect(find.text('No logs yet'), findsOneWidget);

      ctx.vpn.push('[10:00:01] Starting Trusty client...');
      await tester.pumpAndSettle();

      expect(find.text('No logs yet'), findsNothing);
      expect(find.text('Starting Trusty client...'), findsOneWidget);
      // The stamp is pulled into its own dim column.
      expect(find.text('10:00:01'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('a level colours its line and the counters follow',
        (tester) async {
      await pumpLogsWithVpn(tester, logs: _session);

      // Every line is rendered, stamp and level token stripped: the level
      // is drawn once, in its own column.
      expect(find.text('Error: handshake failed'), findsOneWidget);
      expect(find.text('Wintun adapter still busy, retrying'), findsOneWidget);
      expect(find.text('upstream negotiated http2'), findsOneWidget);

      // ERROR/WARN tokens in the level column.
      expect(find.text('ERROR'), findsOneWidget);
      expect(find.text('WARN'), findsOneWidget);
      expect(find.text('DEBUG'), findsOneWidget);

      final errorText =
          tester.widget<Text>(find.text('Error: handshake failed'));
      expect(errorText.style?.color, StatusColors.dark.error,
          reason: 'an error line must be tinted with the error status colour');

      final warnText = tester
          .widget<Text>(find.text('Wintun adapter still busy, retrying'));
      expect(warnText.style?.color, StatusColors.dark.connecting,
          reason: 'a warning line must be tinted with the warning colour');

      // Counters: total behind the info glyph, error count beside it.
      expect(find.textContaining('6 lines'), findsOneWidget);
      expect(find.text('errors'), findsOneWidget);

      expectNoOverflow(tester);
    });

    testWidgets('the error counter is hidden when nothing failed',
        (tester) async {
      await pumpLogsWithVpn(tester, logs: const [
        '[10:00:01] Starting Trusty client...',
        '[10:00:02] Connected successfully!',
      ]);

      expect(find.textContaining('2 lines'), findsOneWidget);
      expect(find.text('errors'), findsNothing);
      expectNoOverflow(tester);
    });
  });

  group('logs · filters', () {
    testWidgets('chips carry live counts and filter the console',
        (tester) async {
      await pumpLogsWithVpn(tester, logs: _session);

      expect(find.text('All'), findsOneWidget);
      expect(find.text('Errors (1)'), findsOneWidget);
      expect(find.text('Warnings (1)'), findsOneWidget);

      await tester.tap(find.text('Errors (1)'));
      await tester.pumpAndSettle();

      expect(find.text('Error: handshake failed'), findsOneWidget);
      expect(find.text('Wintun adapter still busy, retrying'), findsNothing);
      expect(find.text('Starting Trusty client...'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      expect(find.text('Wintun adapter still busy, retrying'), findsOneWidget);
      expect(find.text('Starting Trusty client...'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('a filter with no matches shows its own empty text',
        (tester) async {
      await pumpLogsWithVpn(tester, logs: const [
        '[10:00:01] Starting Trusty client...',
        '[10:00:02] Connected successfully!',
      ]);

      await tester.tap(find.text('Warnings (0)'));
      await tester.pumpAndSettle();

      expect(find.text('No warnings'), findsOneWidget);
      expect(find.text('No logs yet'), findsNothing,
          reason: 'the generic empty state is wrong when lines exist');

      await tester.tap(find.text('Errors (0)'));
      await tester.pumpAndSettle();
      expect(find.text('No errors'), findsOneWidget);

      expectNoOverflow(tester);
    });

    testWidgets('counts update while a filter is active', (tester) async {
      final ctx = await pumpLogsWithVpn(tester, logs: _session);

      await tester.tap(find.text('Errors (1)'));
      await tester.pumpAndSettle();

      ctx.vpn.push('[10:00:07] ERROR Error: connection reset');
      await tester.pumpAndSettle();

      expect(find.text('Errors (2)'), findsOneWidget);
      expect(find.text('Error: connection reset'), findsOneWidget);
      expect(find.text('Starting Trusty client...'), findsNothing);
      expectNoOverflow(tester);
    });
  });

  group('logs · client log level', () {
    testWidgets('shows the level stored in the config', (tester) async {
      await pumpScreen(tester, const LogsScreen(),
          prefs: _prefsWithLogLevel('trace'));

      expect(find.text('Log level'), findsOneWidget);
      final dropdown =
          tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
      expect(dropdown.value, 'trace');
      expectNoOverflow(tester);
    });

    testWidgets('opening it and picking a level persists through ConfigService',
        (tester) async {
      final config = await pumpScreen(tester, const LogsScreen(),
          prefs: _prefsWithLogLevel('info'));

      expect(
        tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>)).value,
        'info',
      );

      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();

      // The menu is open: every level is offered twice (button + menu).
      expect(find.text('debug'), findsWidgets);
      await tester.tap(find.text('debug').last);
      await tester.pumpAndSettle();

      expect(
        tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>)).value,
        'debug',
      );

      final saved = await config.loadConfig();
      expect(saved.logLevel, 'debug',
          reason: 'the level must reach the persisted config');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('app_log_level'), 'debug');
      expectNoOverflow(tester);
    });
  });

  group('logs · clear', () {
    testWidgets('asks for confirmation and cancelling keeps the lines',
        (tester) async {
      await pumpLogsWithVpn(tester, logs: _session);

      await tester.tap(find.text('Clear logs'));
      await tester.pumpAndSettle();

      expect(find.text('Clear logs?'), findsOneWidget);
      expect(
        find.text('All log entries will be deleted. This action cannot be undone.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Clear logs?'), findsNothing);
      expect(find.text('Error: handshake failed'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('confirming empties the console and reports it', (tester) async {
      final ctx = await pumpLogsWithVpn(tester, logs: _session);

      await tester.tap(find.text('Clear logs'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
      await tester.pumpAndSettle();

      expect(ctx.vpn.logs, isEmpty);
      expect(find.text('No logs yet'), findsOneWidget);
      expect(find.textContaining('0 lines'), findsOneWidget);
      expect(find.text('Logs cleared'), findsOneWidget,
          reason: 'the user gets a confirmation snackbar');

      // And the actions go back to disabled.
      expect(_actionEnabled(tester, 'Copy logs'), isFalse);
      expect(_actionEnabled(tester, 'Clear logs'), isFalse);
      expectNoOverflow(tester);
    });

    testWidgets('copy is enabled with lines and reports success',
        (tester) async {
      await pumpLogsWithVpn(tester, logs: _session);

      expect(_actionEnabled(tester, 'Copy logs'), isTrue);
      await tester.tap(find.text('Copy logs'));
      await tester.pumpAndSettle();

      expect(find.text('Logs copied to clipboard'), findsOneWidget);
      expectNoOverflow(tester);
    });
  });

  group('logs · auto-scroll', () {
    testWidgets('the toggle flips its label', (tester) async {
      await pumpLogsWithVpn(tester, logs: _session);

      expect(find.text('Auto-scroll enabled'), findsOneWidget);
      expect(find.text('Auto-scroll disabled'), findsNothing);

      await tester.tap(find.text('Auto-scroll enabled'));
      await tester.pumpAndSettle();

      expect(find.text('Auto-scroll disabled'), findsOneWidget);
      expect(find.text('Auto-scroll enabled'), findsNothing);

      await tester.tap(find.text('Auto-scroll disabled'));
      await tester.pumpAndSettle();
      expect(find.text('Auto-scroll enabled'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('on: opening Logs mid-session shows the newest lines',
        (tester) async {
      // The tab is opened after connecting, so the screen mounts with a full
      // buffer. Auto-scroll says "enabled" — the console must be at the end.
      await pumpLogsWithVpn(
        tester,
        logs: [
          for (var i = 0; i < 80; i++) '[10:00:00] warming up line $i',
        ],
      );

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(find.text('Auto-scroll enabled'), findsOneWidget);
      expect(position.pixels, position.maxScrollExtent,
          reason: 'auto-scroll is on, so the newest line must be in view');
    });

    testWidgets('on: streaming from empty keeps the newest line in view',
        (tester) async {
      final ctx = await pumpLogsWithVpn(tester);

      for (var i = 0; i < 80; i++) {
        ctx.vpn.push('[10:00:00] warming up line $i');
        await tester.pump(const Duration(milliseconds: 16));
      }
      ctx.vpn.push('[10:00:30] Connected successfully!');
      await tester.pumpAndSettle();

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(position.pixels, position.maxScrollExtent,
          reason: 'auto-scroll is on, so the newest line must be in view');
      expectNoOverflow(tester);
    });

    testWidgets('on: a new line after a big backlog reaches the true bottom',
        (tester) async {
      final ctx = await pumpLogsWithVpn(
        tester,
        logs: [
          for (var i = 0; i < 80; i++) '[10:00:00] warming up line $i',
        ],
      );

      ctx.vpn.push('[10:00:30] Connected successfully!');
      await tester.pumpAndSettle();

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(position.pixels, position.maxScrollExtent,
          reason: 'auto-scroll is on, so the newest line must be in view');
      expect(find.text('Connected successfully!'), findsOneWidget);
      expectNoOverflow(tester);
    });

    testWidgets('off: a new line leaves the viewport where the user put it',
        (tester) async {
      final ctx = await pumpLogsWithVpn(
        tester,
        logs: [
          for (var i = 0; i < 80; i++) '[10:00:00] warming up line $i',
        ],
      );

      await tester.tap(find.text('Auto-scroll enabled'));
      await tester.pumpAndSettle();

      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(0);
      await tester.pumpAndSettle();

      ctx.vpn.push('[10:00:30] Connected successfully!');
      await tester.pumpAndSettle();

      expect(position.pixels, 0,
          reason: 'auto-scroll is off; the console must not jump under the user');
      expectNoOverflow(tester);
    });
  });

  group('logs · minimum window regression', () {
    // This screen used to throw on every build: the verbosity dropdown is a
    // non-flex child of the filter Row, so `isExpanded: true` asserted on the
    // unbounded width constraint. Assert it lays out clean at the smallest
    // window a user can drag to, in both brightnesses, with a long line that
    // stresses the console row's Expanded message column.
    const longLine =
        '[10:00:09] ERROR Error: dial tcp 198.51.100.24:443: connectex: a connection '
        'attempt failed because the connected party did not properly respond after '
        'a period of time, or established connection failed because connected host '
        'has failed to respond (attempt 3 of 5)';

    for (final brightness in Brightness.values) {
      testWidgets('renders clean at kMinWindow · ${brightness.name}',
          (tester) async {
        await pumpLogsWithVpn(
          tester,
          logs: [..._session, longLine],
          size: kMinWindow,
          brightness: brightness,
          prefs: _prefsWithLogLevel('debug'),
        );

        // Chrome, filters and the verbosity control all present at 850px.
        expect(find.text('Connection Logs'), findsOneWidget);
        expect(find.text('Filter'), findsOneWidget);
        expect(find.text('Console'), findsOneWidget);
        expect(find.text('All'), findsOneWidget);
        expect(find.text('Log level'), findsOneWidget);
        expect(find.byType(DropdownButton<String>), findsOneWidget);
        expect(find.text('Errors (2)'), findsOneWidget);

        expectNoOverflow(tester);
      });
    }

    testWidgets('three-digit filter counts still fit the filter row at kMinWindow',
        (tester) async {
      // A real 500-line session: the chips grow to "Errors (140)" /
      // "Warnings (180)", which is the widest the filter row ever gets.
      await pumpLogsWithVpn(
        tester,
        logs: [
          for (var i = 0; i < 140; i++)
            '[10:00:00] ERROR Error: upstream reset $i',
          for (var i = 0; i < 180; i++)
            '[10:00:00] WARN retrying handshake $i',
          for (var i = 0; i < 180; i++) '[10:00:00] routed packet $i',
        ],
        size: kMinWindow,
      );

      expect(find.text('Errors (140)'), findsOneWidget);
      expect(find.text('Warnings (180)'), findsOneWidget);
      expect(find.text('Log level'), findsOneWidget);
      expect(find.textContaining('500 lines'), findsOneWidget);
      expect(find.text('140'), findsOneWidget, reason: 'the error counter');
      expectNoOverflow(tester);
    });

    testWidgets('the console still scrolls a long session at kMinWindow',
        (tester) async {
      await pumpLogsWithVpn(
        tester,
        logs: [
          for (var i = 0; i < 60; i++)
            '[10:0${i ~/ 10}:${(i % 10).toString().padLeft(2, '0')}] '
                'routed 10.0.0.$i through the tunnel',
        ],
        size: kMinWindow,
      );

      expect(find.textContaining('60 lines'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expectNoOverflow(tester);
    });
  });
}

/// Loads the fonts the app actually ships (`pubspec.yaml` → Geologica /
/// ChivoMono / JetBrainsMono) so widths in these tests are the
/// widths a user sees. Without this, flutter_test lays every glyph out as a
/// full em, which is far wider than Geologica at the same size — enough to
/// report a filter-row overflow at 850px that does not exist on a real
/// machine. Must run from `setUpAll`: real file IO cannot complete inside a
/// `testWidgets` body's fake-async zone.
Future<void> loadShippedFonts() async {
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final path in files) {
      loader.addFont(
        io.File(path).readAsBytes().then((bytes) => bytes.buffer.asByteData()),
      );
    }
    await loader.load();
  }

  await load('Geologica', [
    'assets/fonts/Geologica-Light.ttf',
    'assets/fonts/Geologica-Regular.ttf',
    'assets/fonts/Geologica-Medium.ttf',
    'assets/fonts/Geologica-SemiBold.ttf',
    'assets/fonts/Geologica-Bold.ttf',
  ]);
  await load('ChivoMono', [
    'assets/fonts/ChivoMono-Regular.ttf',
    'assets/fonts/ChivoMono-Medium.ttf',
  ]);
  await load('JetBrainsMono', ['assets/fonts/JetBrainsMono-Regular.ttf']);
}

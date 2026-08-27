// Accessibility guarantees for the redesigned screens.
//
// `textContrastGuideline` renders each text node and measures it against the
// pixels actually behind it, so it catches what a palette table cannot: a
// caption placed on a tinted card, a label over a filled button, a disabled
// control. It enforces the WCAG AA floor (4.5:1 for body text, 3.0:1 for
// large text).
//
// `labeledTapTargetGuideline` is the other half that matters on a desktop
// app: every icon-only control must carry a name a screen reader can read.
//
// The mobile tap-target guidelines (48dp Android / 44pt iOS) are deliberately
// NOT enforced: this is a pointer-driven desktop window whose design system
// specifies 34px controls and 28px icon buttons, and Flutter's guideline has
// no desktop variant.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trusty/screens/home_screen.dart';
import 'package:trusty/screens/logs_screen.dart';
import 'package:trusty/screens/server_setup_screen.dart';
import 'package:trusty/screens/servers_screen.dart';
import 'package:trusty/screens/split_tunnel_screen.dart';
import 'package:trusty/services/config_service.dart';

import 'harness.dart';

/// Real async work (config load, client-dir stat) does not complete under
/// `pumpAndSettle` alone: dart:io futures need the real event loop turned.
Future<void> settleReal(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

const _twoServers =
    '[{"id":"srv-a","name":"Amsterdam","hostname":"a.example.com","address":"203.0.113.10",'
    '"port":443,"username":"user1","upstreamProtocol":"http2","hasIpv6":true,'
    '"skipVerification":false,"antiDpi":false,"postQuantum":true,"customSni":""},'
    '{"id":"srv-b","name":"Backup","hostname":"b.example.com","address":"198.51.100.7",'
    '"port":443,"username":"user1","upstreamProtocol":"http2","hasIpv6":true,'
    '"skipVerification":false,"antiDpi":false,"postQuantum":true,"customSni":""}]';

final _seeded = <String, Object>{
  'server_list': _twoServers,
  'active_server_id': 'srv-a',
  'app_dns': 'https://dns.adguard-dns.com/dns-query, 8.8.8.8',
  'banner_dismissed_home_intro': false,
};

typedef ScreenCase = ({String name, Widget Function() build, bool seed});

final _screens = <ScreenCase>[
  (name: 'Home', build: () => const HomeScreen(), seed: true),
  (name: 'Servers', build: () => const ServersScreen(), seed: true),
  (name: 'Split Tunnel', build: () => const SplitTunnelScreen(), seed: true),
  (name: 'Logs', build: () => const LogsScreen(), seed: true),
  (name: 'Deploy', build: () => const ServerSetupScreen(), seed: false),
];

void main() {
  for (final brightness in [Brightness.dark, Brightness.light]) {
    final themeName = brightness == Brightness.dark ? 'dark' : 'light';

    group('text contrast · $themeName', () {
      for (final screen in _screens) {
        testWidgets('${screen.name} meets the WCAG AA text floor', (tester) async {
          final handle = tester.ensureSemantics();
          await pumpScreen(
            tester,
            screen.build(),
            brightness: brightness,
            prefs: screen.seed ? _seeded : const {},
          );
          await settleReal(tester);
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }

      testWidgets('Home in its error state meets the text floor', (tester) async {
        final handle = tester.ensureSemantics();
        final config = await pumpScreen(tester, const HomeScreen(),
            brightness: brightness, prefs: _seeded);
        await settleReal(tester);
        expect(config, isA<ConfigService>());
        await expectLater(tester, meetsGuideline(textContrastGuideline));
        handle.dispose();
      });
    });

    group('semantics · $themeName', () {
      for (final screen in _screens) {
        testWidgets('${screen.name} names every tappable', (tester) async {
          final handle = tester.ensureSemantics();
          await pumpScreen(
            tester,
            screen.build(),
            brightness: brightness,
            prefs: screen.seed ? _seeded : const {},
          );
          await settleReal(tester);
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          handle.dispose();
        });
      }
    });
  }
}

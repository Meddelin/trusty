// Renders the Home screen to `docs/screenshot-home.png` for the README.
//
// This is a golden test used as a screenshot tool: it draws the REAL widget
// tree with the app's real theme and bundled fonts, seeded with placeholder
// data, so the picture cannot leak a real server, address or credential the
// way a capture of a running window would.
//
//   flutter test test/tools/render_screenshot.dart --update-goldens
//
// It sits under `test/` so the analyzer accepts the test-only preference
// seam, but without the `_test.dart` suffix, so `flutter test` never collects
// it: a golden comparison is a pixel diff, and
// pinning a whole screen to a bitmap would fail on every deliberate change to
// the design.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trusty/l10n/app_localizations.dart';
import 'package:trusty/main.dart' show RailFooter;
import 'package:trusty/screens/home_screen.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/services/server_setup_service.dart';
import 'package:trusty/services/update_service.dart';
import 'package:trusty/models/server_config.dart';
import 'package:trusty/models/vpn_status.dart';
import 'package:trusty/services/vpn_service.dart';
import 'package:trusty/theme/app_theme.dart';
import 'package:trusty/utils/localization_helper.dart';

/// Placeholder only: documentation-reserved domain and address ranges.
Future<void> _loadBundledFonts() async {
  for (final family in const {
    'Geologica': [
      'assets/fonts/Geologica-Regular.ttf',
      'assets/fonts/Geologica-Medium.ttf',
      'assets/fonts/Geologica-SemiBold.ttf',
    ],
    'ChivoMono': [
      'assets/fonts/ChivoMono-Regular.ttf',
      'assets/fonts/ChivoMono-Medium.ttf',
    ],
  }.entries) {
    final loader = FontLoader(family.key);
    for (final path in family.value) {
      loader.addFont(
        File(path).readAsBytes().then((b) => ByteData.view(b.buffer)),
      );
    }
    await loader.load();
  }
  // Icons are glyphs in a font as well; without it every one is an empty box.
  final icons = FontLoader('MaterialIcons');
  icons.addFont(
    _materialIconFont().readAsBytes().then((b) => ByteData.view(b.buffer)),
  );
  await icons.load();
}

/// Locates the Material icon font, which ships inside the Flutter SDK rather
/// than the project. The path has to be derived instead of written down, or
/// the tool only runs on the machine it was written on: `flutter test` starts
/// the Dart binary from `<sdk>/bin/cache/dart-sdk/bin/`, which puts the cache
/// two directories above it on every platform.
File _materialIconFont() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final caches = <String>[
    if (root != null && root.isNotEmpty) p.join(root, 'bin', 'cache'),
    p.normalize(p.join(p.dirname(Platform.resolvedExecutable), '..', '..')),
  ];
  for (final cache in caches) {
    final file = File(p.join(
        cache, 'artifacts', 'material_fonts', 'materialicons-regular.otf'));
    if (file.existsSync()) return file;
  }
  throw StateError('Material icon font not found under: ${caches.join(', ')}. '
      'Point FLUTTER_ROOT at the Flutter SDK and run this again.');
}

/// A still, connected screen: real widgets, invented data, and no service
/// doing work while the frame is captured.
class _ShotVpnService extends VpnService {
  // ignore: use_super_parameters
  _ShotVpnService(ConfigService config) : super(config);

  @override
  VpnStatus get status => VpnStatus.connected;

  @override
  DateTime? get connectedAt =>
      DateTime.now().subtract(const Duration(minutes: 42, seconds: 17));

  @override
  List<String> get logs => const [
        '[13:58:41] disconnected',
        '[14:02:02] resolving vpn.example.com',
        '[14:02:02] endpoint selected: 203.0.113.10:443',
        '[14:02:03] starting client, endpoint 203.0.113.10:443',
        '[14:02:03] connection mode: VPN (TUN), adapter wintun',
        '[14:02:04] TLS handshake ok (h2), post-quantum enabled',
        '[14:02:04] tun device up',
        '[14:02:05] routing lists merged: 1243 entries',
        '[14:02:05] exclusions applied: selective, 14 domains, 3 apps',
        '[14:02:05] tunnel is up',
        '[14:31:12] WARN routing list "YouTube" update failed, using cached copy',
        '[14:38:44] DEBUG dns query api.example.org',
        '[14:41:03] dns query cdn.example.org',
        '[14:44:20] keepalive ok',
        '[14:44:51] routes verified, 17 entries active',
      ];
}

/// Mirrors the shell in `main.dart`: the rail beside the screen, sharing one
/// background. MainScreen itself cannot be pumped here — it schedules the
/// update check on a delayed timer and then a daily one, and a widget test
/// fails on a timer that outlives it.
class _Shell extends StatelessWidget {
  const _Shell();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        ColoredBox(
          color: scheme.surfaceContainer,
          child: Column(
            children: [
              Expanded(
                child: NavigationRail(
                  selectedIndex: 0,
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Image(
                      image: ResizeImage(
                        AssetImage('assets/icon.png'),
                        width: 120,
                        height: 120,
                      ),
                      width: 40,
                      height: 40,
                    ),
                  ),
                  destinations: [
                    NavigationRailDestination(
                      icon: const Icon(Icons.home_outlined),
                      selectedIcon: const Icon(Icons.home),
                      label: Text(l10n.navHome),
                    ),
                    NavigationRailDestination(
                      icon: const Icon(Icons.dns_outlined),
                      selectedIcon: const Icon(Icons.dns),
                      label: Text(l10n.navServers),
                    ),
                    NavigationRailDestination(
                      icon: const Icon(Icons.call_split_outlined),
                      selectedIcon: const Icon(Icons.call_split),
                      label: Text(l10n.navSplitTunnel),
                    ),
                    NavigationRailDestination(
                      icon: const Icon(Icons.article_outlined),
                      selectedIcon: const Icon(Icons.article),
                      label: Text(l10n.navLogs),
                    ),
                    NavigationRailDestination(
                      icon: const Icon(Icons.rocket_launch_outlined),
                      selectedIcon: const Icon(Icons.rocket_launch),
                      label: Text(l10n.navServer),
                    ),
                  ],
                ),
              ),
              const RailFooter(),
            ],
          ),
        ),
        const Expanded(child: HomeScreen()),
      ],
    );
  }
}

void main() {
  testWidgets('render the Home screen for the README', (tester) async {
    // Real file I/O never completes inside the test's fake async zone, so the
    // font load has to run on the real one or the test simply hangs.
    await tester.runAsync(_loadBundledFonts);
    final demo = ServerConfig.defaultConfig().copyWith(
      id: 'srv-demo',
      name: 'Personal VPS',
      hostname: 'vpn.example.com',
      address: '203.0.113.10',
      port: 443,
      username: 'user1',
      antiDpi: true,
      dns: 'https://dns.adguard-dns.com/dns-query, 8.8.8.8',
      vpnMode: VpnMode.selective,
      splitTunnelDomains: const [
        'vk.com', 'api.vk.com', 'vk-cdn.net', 'alfa.bank',
        '92.255.112.0/20', 'example.org', 'example.net', 'cdn.example.org',
        'api.example.net', 'static.example.com', 'm.example.org',
        'img.example.net', 'assets.example.com', 'media.example.org',
      ],
      splitTunnelApps: const ['Telegram.exe', 'Discord.exe', 'Steam.exe'],
    );
    SharedPreferences.setMockInitialValues({
      'server_config': jsonEncode(demo.toJson()),
      'server_list': jsonEncode([demo.toJson()]),
      'active_server_id': 'srv-demo',
      'app_dns': 'https://dns.adguard-dns.com/dns-query, 8.8.8.8',
      'banner_dismissed_home_intro': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'readAll' ? <String, String>{} : null,
    );

    // physicalSize is in device pixels: at a ratio of 2 the window is
    // 950x700 logical and the PNG comes out at twice that, which is what a
    // README wants on a high-density display.
    tester.view.physicalSize = const Size(1900, 1400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    final config = ConfigService();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ConfigService>.value(value: config),
          ChangeNotifierProvider<VpnService>(
              create: (_) => _ShotVpnService(config)),
          ChangeNotifierProvider<ServerSetupService>(
              create: (_) => ServerSetupService()),
          ChangeNotifierProvider<UpdateService>(create: (_) => UpdateService()),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Brightness.dark),
          builder: (context, child) {
            L10n.init(AppLocalizations.of(context)!);
            return child!;
          },
          home: const Scaffold(body: _Shell()),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 40));
    }

    await tester.pump(const Duration(milliseconds: 450));

    await expectLater(
      find.byType(_Shell),
      matchesGoldenFile('../../docs/screenshot-home.png'),
    );
  });
}

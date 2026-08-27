// Shared harness for the UI scenario tests.
//
// These tests drive the real screens with the real services; only the
// platform edges are faked — SharedPreferences, the secure-storage channel,
// window/tray managers and package_info. Nothing about the widgets under test
// is mocked, so a layout that overflows or a control that throws fails here
// exactly as it would on a user's machine.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trusty/l10n/app_localizations.dart';
import 'package:trusty/services/config_service.dart';
import 'package:trusty/services/server_setup_service.dart';
import 'package:trusty/services/update_service.dart';
import 'package:trusty/services/vpn_service.dart';
import 'package:trusty/theme/app_theme.dart';
import 'package:trusty/utils/localization_helper.dart';

/// The real window's minimum size, minus nothing: if a screen cannot survive
/// this, a user who drags the window small enough sees the overflow stripes.
const Size kMinWindow = Size(850, 650);

/// The default window the app opens at.
const Size kDefaultWindow = Size(950, 700);

/// Silences the plugin channels the screens touch at build time.
void stubPlatformChannels() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void stub(String channel, Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async => handler(call));
  }

  // Keystore: passwords and the filtering prefix live here.
  final secure = <String, String>{};
  stub('plugins.it_nomads.com/flutter_secure_storage', (call) {
    switch (call.method) {
      case 'write':
        secure[call.arguments['key'] as String] = call.arguments['value'] as String? ?? '';
        return null;
      case 'read':
        return secure[call.arguments['key'] as String];
      case 'readAll':
        return Map<String, String>.from(secure);
      case 'delete':
        secure.remove(call.arguments['key'] as String);
        return null;
      case 'deleteAll':
        secure.clear();
        return null;
      case 'containsKey':
        return secure.containsKey(call.arguments['key'] as String);
    }
    return null;
  });

  stub('window_manager', (_) => null);
  stub('tray_manager', (_) => null);
  stub('dev.flutter.pigeon.package_info_plus.PackageInfoApi.getAll', (_) => null);
  stub('plugins.flutter.io/package_info', (_) => <String, dynamic>{
        'appName': 'Trusty',
        'packageName': 'com.trusty.app',
        'version': '0.4.0',
        'buildNumber': '6',
      });
  stub('plugins.flutter.io/url_launcher', (_) => true);
  stub('plugins.flutter.io/path_provider', (_) => '.');
}

/// Boots the providers the way `main.dart` does and pumps [child] inside a
/// window of [size]. Returns the live [ConfigService] so a test can seed or
/// assert against real persisted state.
Future<ConfigService> pumpScreen(
  WidgetTester tester,
  Widget child, {
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

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ConfigService>.value(value: config),
        ChangeNotifierProvider<VpnService>(create: (_) => VpnService(config)),
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
        home: Scaffold(body: child),
      ),
    ),
  );
  // Services load asynchronously on first build.
  await tester.pumpAndSettle(const Duration(milliseconds: 600));
  return config;
}

/// Fails with a readable message if anything in the tree overflowed.
void expectNoOverflow(WidgetTester tester) {
  final errors = tester.takeException();
  expect(errors, isNull, reason: 'the screen threw or overflowed while laying out');
}

// UI scenario tests for the redesigned Deploy screen (ServerSetupScreen).
//
// Every test pumps the real screen through the shared harness, with the real
// ConfigService / ServerSetupService behind it. Only two things are not real:
// the platform channels the harness stubs, and — for the two phases that
// cannot be reached without an actual VPS — a subclass of ServerSetupService
// that overrides *only* `currentStep`. Everything else on those runs (the
// persisted result, the logs, the error text, applyToClientConfig) is the
// real service.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trusty/models/server_setup_config.dart';
import 'package:trusty/models/setup_step.dart';
import 'package:trusty/screens/server_setup_screen.dart';
import 'package:trusty/services/server_setup_service.dart';
import 'package:trusty/widgets/app_switch.dart';

import 'harness.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// The live service behind the pumped screen.
ServerSetupService _setupService(WidgetTester tester) =>
    Provider.of<ServerSetupService>(
      tester.element(find.byType(ServerSetupScreen)),
      listen: false,
    );

/// The text field that sits under [label] in the artboard's label-above-field
/// recipe.
Finder _inputFor(String label) => find
    .descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Column))
          .first,
      matching: find.byType(TextFormField),
    )
    .first;

/// What the user currently sees inside the field under [label].
String _valueOf(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find
          .descendant(of: _inputFor(label), matching: find.byType(EditableText))
          .first,
    )
    .controller
    .text;

/// The validation message currently displayed under [label], or null.
String? _errorTextOf(WidgetTester tester, String label) => tester
    .widget<InputDecorator>(
      find
          .descendant(of: _inputFor(label), matching: find.byType(InputDecorator))
          .first,
    )
    .decoration
    .errorText;

bool _isObscured(WidgetTester tester, String label) => tester
    .widget<EditableText>(
      find
          .descendant(of: _inputFor(label), matching: find.byType(EditableText))
          .first,
    )
    .obscureText;

const _kHost = 'VPS IP Address';
const _kSshUser = 'Username';
const _kSshPort = 'SSH Port';
const _kSshPassword = 'SSH Password';
const _kDomain = 'Domain';
const _kEmail = "Email (Let's Encrypt)";
const _kListenPort = 'Port';
const _kVpnUser = 'VPN Username';
const _kVpnPassword = 'VPN Password';

/// Types a complete, valid deployment into the form, then applies [overrides]
/// (a null value clears the field).
Future<void> _fillForm(
  WidgetTester tester, {
  Map<String, String?> overrides = const {},
}) async {
  final values = <String, String?>{
    _kHost: '203.0.113.10',
    _kSshUser: 'root',
    _kSshPort: '22',
    _kSshPassword: 'hunter2',
    _kDomain: 'vpn.example.com',
    _kEmail: 'admin@example.com',
    _kListenPort: '443',
    _kVpnUser: 'alice',
    _kVpnPassword: 'sup3rsecret',
    ...overrides,
  };
  for (final entry in values.entries) {
    await tester.enterText(_inputFor(entry.key), entry.value ?? '');
  }
  await tester.pumpAndSettle();
}

Future<void> _pressInstall(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Install Server'));
  await tester.pumpAndSettle();
}

ServerSetupConfig _validConfig({String host = '203.0.113.10', int sshPort = 22}) =>
    ServerSetupConfig(
      host: host,
      sshPort: sshPort,
      sshUsername: 'root',
      sshPassword: 'hunter2',
      domain: 'vpn.example.com',
      email: 'admin@example.com',
      listenPort: 443,
      vpnUsername: 'alice',
      vpnPassword: 'sup3rsecret',
    );

/// A persisted successful deploy, in the legacy shape `loadPersistedResult`
/// migrates (prefix inline, moved to the keystore on load).
Map<String, Object> _persistedResultPrefs({String prefix = 'a1b2c3d4/ff00ff00'}) =>
    {
      'deploy_last_result': jsonEncode({
        'host': '203.0.113.10',
        'domain': 'edge.deploy-test.net',
        'listenPort': 8443,
        'vpnUsername': 'alice',
        'clientRandomPrefix': prefix,
      }),
    };

/// The real service with one getter pinned, for the phases that otherwise
/// need a live VPS. Nothing else is stubbed: logs, errorMessage, lastResult,
/// clearLogs and applyToClientConfig all run their real implementations.
class _PinnedStepService extends ServerSetupService {
  _PinnedStepService(this.step);

  SetupStep step;
  int cancelCalls = 0;

  @override
  SetupStep get currentStep => step;

  @override
  Future<void> cancelInstallation() async {
    cancelCalls++;
    step = SetupStep.failed;
    notifyListeners();
  }

  @override
  Future<void> installAndRemember(
    ServerSetupConfig config, {
    Future<bool> Function()? confirmReplace,
  }) async {
    // Never open a socket from a test; record the attempt instead.
    installCalls.add(config);
  }

  final List<ServerSetupConfig> installCalls = [];
}

Widget _screenWith(ServerSetupService service) =>
    ChangeNotifierProvider<ServerSetupService>.value(
      value: service,
      child: const ServerSetupScreen(),
    );

void main() {
  // -------------------------------------------------------------------
  // Idle form
  // -------------------------------------------------------------------

  testWidgets('idle: all four islands render with their fields', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());

    expect(find.text('SSH Connection'), findsOneWidget);
    expect(find.text('Domain and Certificate'), findsOneWidget);
    expect(find.text('VPN Account'), findsOneWidget);
    expect(find.text('Security'), findsOneWidget);

    for (final label in [
      _kHost,
      _kSshUser,
      _kSshPort,
      _kSshPassword,
      _kDomain,
      _kEmail,
      _kListenPort,
      _kVpnUser,
      _kVpnPassword,
    ]) {
      expect(_inputFor(label), findsOneWidget, reason: 'field "$label"');
    }

    // Defaults the user should not have to type.
    expect(_valueOf(tester, _kSshUser), 'root');
    expect(_valueOf(tester, _kSshPort), '22');
    expect(_valueOf(tester, _kListenPort), '443');
    // Both passwords start hidden.
    expect(_isObscured(tester, _kSshPassword), isTrue);
    expect(_isObscured(tester, _kVpnPassword), isTrue);

    // The intro banner earns its place only before anything was attempted.
    expect(find.textContaining('Installs and configures'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Install Server'), findsOneWidget);
    // Nothing running, so no Cancel.
    expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsNothing);
    expectNoOverflow(tester);
  });

  testWidgets('idle: auth mode swaps the field under the toggle', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());

    expect(_inputFor(_kSshPassword), findsOneWidget);
    expect(find.text('SSH Key Path'), findsNothing);

    await tester.tap(find.text('SSH Key'));
    await tester.pumpAndSettle();

    expect(find.text(_kSshPassword), findsNothing);
    expect(_inputFor('SSH Key Path'), findsOneWidget);
    // Prefilled with a plausible default so the common case is one tap.
    expect(_valueOf(tester, 'SSH Key Path'), contains('id_ed25519'));

    await tester.tap(find.text('Password'));
    await tester.pumpAndSettle();

    expect(_inputFor(_kSshPassword), findsOneWidget);
    expect(find.text('SSH Key Path'), findsNothing);
    expectNoOverflow(tester);
  });

  testWidgets('idle: the eye reveals the SSH password', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await tester.enterText(_inputFor(_kSshPassword), 'hunter2');
    await tester.pumpAndSettle();
    expect(_isObscured(tester, _kSshPassword), isTrue);

    await tester.tap(
      find
          .descendant(
            of: _inputFor(_kSshPassword),
            matching: find.byIcon(Icons.visibility),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(_isObscured(tester, _kSshPassword), isFalse);
    expectNoOverflow(tester);
  });

  // -------------------------------------------------------------------
  // Validation
  // -------------------------------------------------------------------

  testWidgets('validation: an empty IP blocks the install', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kHost: null});
    await _pressInstall(tester);

    expect(find.text('Enter IP address'), findsOneWidget);
    expect(find.text('Installing...'), findsNothing);
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: a malformed IP blocks the install', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    // The VPN password is left empty on purpose: whatever the host field
    // decides, the form as a whole is invalid, so pressing Install can never
    // open a socket from a test. The assertion below is only about the host.
    await _fillForm(
      tester,
      overrides: {_kHost: '999.999.999.999', _kVpnPassword: null},
    );
    await _pressInstall(tester);

    // Proves validate() actually ran over the whole form.
    expect(find.text('Enter password'), findsOneWidget);

    expect(_errorTextOf(tester, _kVpnPassword), 'Enter password');

    // "999.999.999.999" is not an address and does not resolve; a field
    // labelled "VPS IP Address" must say so before a deploy is attempted.
    expect(
      _errorTextOf(tester, _kHost),
      'Enter a valid IP address or hostname (e.g. 203.0.113.10)',
      reason: 'the VPS IP field accepted "999.999.999.999"',
    );
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: a hostname is a valid VPS address', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    // A VPS reached by name, not by literal address. The VPN password is
    // left empty so the form as a whole stays invalid and no socket opens.
    await _fillForm(
      tester,
      overrides: {_kHost: 'vps.example.com', _kVpnPassword: null},
    );
    await _pressInstall(tester);

    // Proves validate() ran over the whole form.
    expect(_errorTextOf(tester, _kVpnPassword), 'Enter password');
    expect(_errorTextOf(tester, _kHost), isNull);
  });

  testWidgets('validation: an out-of-range SSH port blocks the install',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kSshPort: '70000'});
    await _pressInstall(tester);

    expect(find.text('Port must be 1-65535'), findsOneWidget);
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: a non-numeric SSH port blocks the install',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kSshPort: 'ssh'});
    await _pressInstall(tester);

    expect(find.text('Port must be 1-65535'), findsOneWidget);
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: an empty domain blocks the install', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kDomain: null});
    await _pressInstall(tester);

    expect(find.text('Enter domain'), findsOneWidget);
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: a malformed domain blocks the install', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kDomain: 'not a domain'});
    await _pressInstall(tester);

    expect(
      find.text('Enter a valid domain name (e.g. vpn.example.com)'),
      findsOneWidget,
    );
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: a malformed email blocks the install', (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kEmail: 'admin@@example'});
    await _pressInstall(tester);

    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: an empty VPN username blocks the install',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kVpnUser: null});
    await _pressInstall(tester);

    expect(find.text('Enter username'), findsOneWidget);
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: an empty VPN password blocks the install',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kVpnPassword: null});
    await _pressInstall(tester);

    // The SSH password is filled, so this is the VPN one.
    expect(find.text('Enter password'), findsOneWidget);
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: an empty key path blocks the install in key mode',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester);
    await tester.tap(find.text('SSH Key'));
    await tester.pumpAndSettle();
    await tester.enterText(_inputFor('SSH Key Path'), '');
    await tester.pumpAndSettle();
    await _pressInstall(tester);

    expect(find.text('Enter key path'), findsOneWidget);
    expect(_setupService(tester).currentStep, SetupStep.idle);
  });

  testWidgets('validation: errors do not overflow the islands at the minimum window',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen(), size: kMinWindow);
    await _fillForm(tester, overrides: {
      _kHost: null,
      _kDomain: 'not a domain',
      _kEmail: 'nope',
      _kVpnUser: null,
      _kVpnPassword: null,
      _kSshPassword: null,
      _kSshPort: '70000',
    });
    await _pressInstall(tester);

    expect(find.text('Enter IP address'), findsOneWidget);
    expectNoOverflow(tester);
  });

  // -------------------------------------------------------------------
  // Password generator + filtering switch
  // -------------------------------------------------------------------

  testWidgets('generator: the dice fills the VPN password and reveals it',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    expect(_valueOf(tester, _kVpnPassword), isEmpty);

    await tester.tap(find.byIcon(Icons.casino));
    await tester.pumpAndSettle();

    final generated = _valueOf(tester, _kVpnPassword);
    expect(generated, isNotEmpty);
    expect(generated.length, greaterThanOrEqualTo(12));
    expect(_isObscured(tester, _kVpnPassword), isFalse,
        reason: 'a generated password the user must save has to be readable');

    // A second press produces a different one.
    await tester.tap(find.byIcon(Icons.casino));
    await tester.pumpAndSettle();
    expect(_valueOf(tester, _kVpnPassword), isNot(generated));
    expectNoOverflow(tester);
  });

  testWidgets('generator: a generated password satisfies the validator',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kVpnPassword: null, _kDomain: 'bad'});
    await tester.tap(find.byIcon(Icons.casino));
    await tester.pumpAndSettle();
    await _pressInstall(tester);

    // The domain is still wrong (so nothing is deployed), but the VPN
    // password must no longer be flagged.
    expect(find.text('Enter a valid domain name (e.g. vpn.example.com)'),
        findsOneWidget);
    expect(find.text('Enter password'), findsNothing);
  });

  testWidgets('filtering: the switch toggles and explains its consequence',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());

    final switchFinder = find.byType(AppSwitch);
    expect(switchFinder, findsOneWidget);
    expect(tester.widget<AppSwitch>(switchFinder).value, isFalse);
    expect(find.textContaining('without this exact value'),
        findsNothing);

    // The explanation behind the label's info glyph is reachable. Match on a
    // stable fragment rather than the whole sentence, so rewording the copy
    // does not break the behaviour this test is about.
    final hint = find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').contains('secret marker'),
    );
    expect(hint, findsOneWidget);
    await tester.longPress(hint);
    await tester.pumpAndSettle();
    expect(find.textContaining('secret marker'), findsWidgets);

    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(tester.widget<AppSwitch>(switchFinder).value, isTrue);
    expect(find.textContaining('without this exact value'),
        findsOneWidget);
    expectNoOverflow(tester);

    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<AppSwitch>(switchFinder).value, isFalse);
    expect(find.textContaining('without this exact value'),
        findsNothing);
  });

  testWidgets('filtering: the choice is persisted with the form on Install',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    await _fillForm(tester, overrides: {_kDomain: 'bad'});
    await tester.tap(find.byType(AppSwitch));
    await tester.pumpAndSettle();
    await _pressInstall(tester);

    // Install was blocked by the domain, so nothing was saved yet.
    expect(await ServerSetupService.loadFormDefaults(), isNull);

    await tester.enterText(_inputFor(_kDomain), 'vpn.example.com');
    await tester.pumpAndSettle();
    // From here a press would open a socket, so drive the persistence the
    // same way the button does instead.
    final saved = ServerSetupConfig(
      host: _valueOf(tester, _kHost),
      domain: _valueOf(tester, _kDomain),
      generateClientRandomPrefix:
          tester.widget<AppSwitch>(find.byType(AppSwitch)).value,
    );
    await ServerSetupService.saveFormDefaults(saved);
    final reloaded = await ServerSetupService.loadFormDefaults();
    expect(reloaded!.generateClientRandomPrefix, isTrue);
    expect(reloaded.domain, 'vpn.example.com');
  });

  // -------------------------------------------------------------------
  // Running
  // -------------------------------------------------------------------

  testWidgets('running: a real in-flight install locks the form and offers cancel',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    final service = _setupService(tester);

    // A listening socket that never speaks SSH: the TCP connect succeeds, the
    // handshake hangs, so the install stays on step 1 for the whole test.
    late ServerSocket server;
    final held = <Socket>[];
    await tester.runAsync(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(held.add);
    });
    addTearDown(() {
      for (final s in held) {
        s.destroy();
      }
      server.close();
    });

    await _fillForm(tester, overrides: {
      _kHost: '127.0.0.1',
      _kSshPort: '${server.port}',
    });

    await tester.runAsync(() async {
      unawaited(service.installAndRemember(_validConfig(
        host: '127.0.0.1',
        sshPort: server.port,
      )));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();

    expect(service.currentStep.isInProgress, isTrue,
        reason: 'the install should still be connecting');

    // The form islands are gone; a locked summary shows what was submitted.
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('127.0.0.1'), findsOneWidget);
    expect(find.text('${server.port}'), findsOneWidget);
    expect(find.text('vpn.example.com'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);

    // Header: install disabled and relabelled, cancel offered.
    final install = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Installing...'),
    );
    expect(install.onPressed, isNull);
    expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);

    // The checklist: seven steps, the first one current.
    for (final step in const [
      'Connecting via SSH',
      'Checking system',
      'Installing Trusty',
      'Configuring server',
      'Obtaining certificate',
      'Starting service',
      'Verifying',
    ]) {
      expect(find.text(step), findsOneWidget, reason: 'checklist row "$step"');
    }
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(6));
    expectNoOverflow(tester);

    // Cancel really cancels.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(service.currentStep, SetupStep.failed);
    expect(find.text('Installation failed'), findsOneWidget);
    // The form is back so the user can fix and retry.
    expect(_inputFor(_kHost), findsOneWidget);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  });

  // -------------------------------------------------------------------
  // Failure
  // -------------------------------------------------------------------

  testWidgets('failed: a refused connection marks the step it broke on',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    final service = _setupService(tester);

    // A port that is definitely closed: bind one, note it, close it.
    late int deadPort;
    await tester.runAsync(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      deadPort = probe.port;
      await probe.close();
      await service.installServer(
        _validConfig(host: '127.0.0.1', sshPort: deadPort),
      );
    });
    await tester.pumpAndSettle();

    expect(service.currentStep, SetupStep.failed);
    expect(find.text('Installation failed'), findsOneWidget);
    // The failed step is marked, not the whole list greyed out.
    expect(find.byIcon(Icons.error), findsWidgets);
    expect(service.lastAttemptedStep, SetupStep.connecting);
    // The reason is surfaced, not just logged.
    expect(find.textContaining('SocketException'), findsWidgets);
    // The form stays editable underneath so the user can fix and retry.
    expect(_inputFor(_kHost), findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('failed: a rejected domain fails before any SSH work',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    final service = _setupService(tester);

    final bad = _validConfig()..domain = 'vpn.example.com; rm -rf /';
    await service.installServer(bad);
    await tester.pumpAndSettle();

    expect(service.currentStep, SetupStep.failed);
    expect(find.text('Domain contains invalid characters.'), findsOneWidget);
    expect(find.text('Trust new host key & retry'), findsNothing);
    expectNoOverflow(tester);
  });

  testWidgets('failed: the failure is visible without scrolling',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    final service = _setupService(tester);

    await service.installServer(_validConfig()..domain = 'bad domain');
    await tester.pumpAndSettle();

    final banner = find.text('Domain contains invalid characters.');
    expect(banner, findsOneWidget);
    final rect = tester.getRect(banner);
    // Pressing Install and failing has to change the visible screen.
    expect(
      rect.bottom,
      lessThan(kDefaultWindow.height),
      reason: 'the failure banner ends ${rect.bottom.toStringAsFixed(0)}px '
          'down a ${kDefaultWindow.height.toInt()}px window: pressing Install '
          'and failing leaves the visible screen unchanged',
    );
    // Being on the page is not enough — the checklist island scrolls its own
    // content, so the banner must also sit inside its island's visible box
    // rather than clipped underneath the seven step rows.
    final island = tester.getRect(
      find.ancestor(of: banner, matching: find.byType(Card)).first,
    );
    expect(rect.top, greaterThanOrEqualTo(island.top),
        reason: 'the failure banner is clipped above its island');
    expect(rect.bottom, lessThanOrEqualTo(island.bottom),
        reason: 'the failure banner is clipped below its island');
    // ...and the form is still underneath, editable, for the retry.
    expect(_inputFor(_kHost), findsOneWidget);
  });

  testWidgets('failed: a host-key mismatch offers trust-and-retry',
      (tester) async {
    await pumpScreen(tester, const ServerSetupScreen());
    final service = _setupService(tester);

    // Fail first (no SSH involved), then reproduce the mismatch the connect
    // step would have hit.
    await service.installServer(_validConfig()..domain = 'bad domain');
    await tester.pumpAndSettle();
    expect(service.currentStep, SetupStep.failed);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ssh_hostkey_203.0.113.10_22', 'aa:bb:cc:dd');
    final trusted = await service.verifyHostKey(
      _validConfig(),
      'ssh-ed25519',
      Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
    );
    expect(trusted, isFalse);
    await tester.pumpAndSettle();

    expect(service.hostKeyMismatch, isTrue);
    expect(find.text('Trust new host key & retry'), findsOneWidget);
    expect(find.textContaining('MISMATCH'), findsWidgets);
    expectNoOverflow(tester);

    // Taking the recovery forgets the stored fingerprint. The form is still
    // invalid (nothing typed), so the retry stops at validation instead of
    // opening a socket.
    await tester.ensureVisible(find.text('Trust new host key & retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trust new host key & retry'));
    await tester.pumpAndSettle();
    expect(service.hostKeyMismatch, isFalse);
    expect(prefs.getString('ssh_hostkey_203.0.113.10_22'), isNull);
  });

  // -------------------------------------------------------------------
  // Completed
  // -------------------------------------------------------------------

  testWidgets('completed: the result island shows what was deployed',
      (tester) async {
    final pinned = _PinnedStepService(SetupStep.completed);
    addTearDown(pinned.dispose);
    await pumpScreen(
      tester,
      _screenWith(pinned),
      prefs: _persistedResultPrefs(),
    );

    expect(find.text('Result'), findsOneWidget);
    expect(find.text('Server installed. The service started.'), findsOneWidget);
    expect(find.text('edge.deploy-test.net'), findsOneWidget);
    expect(find.text('8443'), findsOneWidget);
    expect(find.text('alice'), findsOneWidget);
    // Every checklist row is ticked.
    expect(find.byIcon(Icons.check_circle), findsAtLeastNWidgets(7));
    // The filtering prefix, with its copy control.
    expect(find.text('Filtering prefix: a1b2c3d4/ff00ff00'), findsOneWidget);
    expect(find.byTooltip('Copy prefix'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add to my servers'),
        findsOneWidget);
    expectNoOverflow(tester);
  });

  testWidgets('completed: copying the prefix confirms itself', (tester) async {
    final pinned = _PinnedStepService(SetupStep.completed);
    addTearDown(pinned.dispose);
    await pumpScreen(
      tester,
      _screenWith(pinned),
      prefs: _persistedResultPrefs(),
    );

    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.tap(find.byTooltip('Copy prefix'));
    await tester.pumpAndSettle();

    expect(copied, ['a1b2c3d4/ff00ff00']);
    expect(find.text('Prefix copied to clipboard'), findsOneWidget);
  });

  testWidgets('completed: Add to my servers writes a real server entry',
      (tester) async {
    final pinned = _PinnedStepService(SetupStep.completed);
    addTearDown(pinned.dispose);
    final config = await pumpScreen(
      tester,
      _screenWith(pinned),
      prefs: _persistedResultPrefs(),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Add to my servers'));
    await tester.pumpAndSettle();

    expect(find.text('Server added and selected'), findsOneWidget);
    final servers = await config.loadServers();
    final deployed =
        servers.where((s) => s.hostname == 'edge.deploy-test.net').toList();
    expect(deployed, hasLength(1), reason: 'the deployed server was not added');
    expect(deployed.single.address, '203.0.113.10');
    expect(deployed.single.port, 8443);
    expect(deployed.single.username, 'alice');
    // ...and it becomes the active one, so Connect uses it.
    expect(await config.getActiveServerId(), deployed.single.id);
    expect((await config.loadConfig()).hostname, 'edge.deploy-test.net');
    // The generated prefix must survive into the client entry, or the server
    // will ignore this client forever.
    final entry = await config.loadServerEntry(deployed.single.id);
    expect(entry!.clientRandomPrefix, 'a1b2c3d4/ff00ff00');
  });

  testWidgets('completed: Deploy is not a dead end — the form comes back',
      (tester) async {
    final pinned = _PinnedStepService(SetupStep.completed);
    addTearDown(pinned.dispose);
    await pumpScreen(
      tester,
      _screenWith(pinned),
      prefs: _persistedResultPrefs(),
    );

    expect(find.byType(TextFormField), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Install Server'));
    await tester.pumpAndSettle();

    // The whole form is reachable again, and the previous deployment stays
    // in reach in the side column.
    expect(_inputFor(_kHost), findsOneWidget);
    expect(_inputFor(_kVpnPassword), findsOneWidget);
    expect(find.text('Last deployment'), findsOneWidget);
    expect(find.text('Filtering prefix: a1b2c3d4/ff00ff00'), findsOneWidget);
    expectNoOverflow(tester);

    // And a second deployment can actually be started from there.
    await _fillForm(tester);
    await _pressInstall(tester);
    expect(pinned.installCalls, hasLength(1));
    expect(pinned.installCalls.single.domain, 'vpn.example.com');
  });

  testWidgets('idle: a restored deployment offers Apply from the form',
      (tester) async {
    final config = await pumpScreen(
      tester,
      const ServerSetupScreen(),
      prefs: _persistedResultPrefs(),
    );

    expect(find.text('Last deployment'), findsOneWidget);
    expect(find.textContaining('edge.deploy-test.net (203.0.113.10:8443)'),
        findsOneWidget);
    expect(find.textContaining('restored after a restart'), findsOneWidget);
    expect(find.text('Filtering prefix: a1b2c3d4/ff00ff00'), findsOneWidget);
    // The form is still the main event.
    expect(_inputFor(_kHost), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add to my servers'));
    await tester.pumpAndSettle();
    expect(
      (await config.loadServers())
          .where((s) => s.hostname == 'edge.deploy-test.net'),
      hasLength(1),
    );
    expectNoOverflow(tester);
  });

  // -------------------------------------------------------------------
  // Size / brightness matrix
  // -------------------------------------------------------------------

  for (final size in const [kDefaultWindow, kMinWindow]) {
    for (final brightness in Brightness.values) {
      final tag = '${size.width.toInt()}x${size.height.toInt()} '
          '${brightness.name}';

      testWidgets('layout: idle at $tag', (tester) async {
        await pumpScreen(
          tester,
          const ServerSetupScreen(),
          size: size,
          brightness: brightness,
        );
        expect(find.text('SSH Connection'), findsOneWidget);
        expectNoOverflow(tester);
      });

      testWidgets('layout: idle with a restored deployment at $tag',
          (tester) async {
        await pumpScreen(
          tester,
          const ServerSetupScreen(),
          size: size,
          brightness: brightness,
          prefs: _persistedResultPrefs(),
        );
        expect(find.text('Last deployment'), findsOneWidget);
        expectNoOverflow(tester);
      });

      testWidgets('layout: filtering on, key auth at $tag', (tester) async {
        await pumpScreen(
          tester,
          const ServerSetupScreen(),
          size: size,
          brightness: brightness,
        );
        await tester.tap(find.text('SSH Key'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(AppSwitch));
        await tester.pumpAndSettle();
        expect(find.textContaining('without this exact value'),
            findsOneWidget);
        expectNoOverflow(tester);
      });

      testWidgets('layout: running at $tag', (tester) async {
        final pinned = _PinnedStepService(SetupStep.obtainingCertificate);
        addTearDown(pinned.dispose);
        await pumpScreen(
          tester,
          _screenWith(pinned),
          size: size,
          brightness: brightness,
        );
        expect(find.text('Obtaining certificate'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'Cancel'), findsOneWidget);
        expectNoOverflow(tester);
      });

      testWidgets('layout: completed at $tag', (tester) async {
        final pinned = _PinnedStepService(SetupStep.completed);
        addTearDown(pinned.dispose);
        await pumpScreen(
          tester,
          _screenWith(pinned),
          size: size,
          brightness: brightness,
          prefs: _persistedResultPrefs(),
        );
        expect(find.text('Result'), findsOneWidget);
        expectNoOverflow(tester);
      });

      testWidgets('layout: failed with a long error at $tag', (tester) async {
        await pumpScreen(
          tester,
          const ServerSetupScreen(),
          size: size,
          brightness: brightness,
        );
        final service = _setupService(tester);
        await service.installServer(
          _validConfig()
            ..domain = 'this domain is deliberately unacceptable and rather '
                'long so the error banner has to wrap inside the checklist',
        );
        await tester.pumpAndSettle();
        expect(find.text('Installation failed'), findsOneWidget);
        expectNoOverflow(tester);
      });
    }
  }
}

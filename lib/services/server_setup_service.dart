import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/setup_step.dart';
import '../models/server_config.dart';
import '../models/server_setup_config.dart';
import 'config_service.dart';

/// Thrown when the user declines to replace an existing installation.
class _SetupCancelled implements Exception {}

/// Generate a TLS client-random prefix in the `prefix/mask` form the client
/// requires (a bare prefix is silently ignored). 4-byte prefix + 4-byte mask
/// with ~70% of bits set, matching the endpoint's own generator defaults
/// (--prefix-length 4, --prefix-percent 70). The same string is written to
/// both the client config and the server's rules.toml, so any valid
/// prefix/mask pair works as long as both sides match.
String generateClientRandomPrefix(Random rnd) {
  String hex4(int Function() nextByte) => List.generate(
        4,
        (_) => nextByte().toRadixString(16).padLeft(2, '0'),
      ).join();

  final prefix = hex4(() => rnd.nextInt(256));
  final mask = hex4(() {
    var b = 0;
    for (var i = 0; i < 8; i++) {
      if (rnd.nextInt(100) < 70) b |= 1 << i;
    }
    return b;
  });
  return '$prefix/$mask';
}

class ServerSetupService extends ChangeNotifier {
  SetupStep _currentStep = SetupStep.idle;

  /// The last real installation step that was attempted — kept when the run
  /// fails so the checklist can mark the exact step that broke instead of
  /// greying everything out (SetupStep.failed itself has no index).
  SetupStep? _lastAttemptedStep;
  final List<String> _logs = [];
  String? _errorMessage;
  SSHClient? _client;
  bool _alreadyInstalled = false;

  /// Set by [cancelInstallation]; checked between install steps. A mid-step
  /// cancel aborts promptly anyway because the SSH connection is closed out
  /// from under the running command.
  bool _cancelled = false;

  // Set when the last connect failed on an SSH host-key mismatch; holds the
  // prefs key of the stored fingerprint so the UI can offer to forget it
  // (legitimate case: the user rebuilt the VPS and it has a new host key).
  String? _mismatchedHostKeyPrefsKey;

  // Public getters
  SetupStep get currentStep => _currentStep;
  SetupStep? get lastAttemptedStep => _lastAttemptedStep;
  List<String> get logs => List.unmodifiable(_logs);
  String? get errorMessage => _errorMessage;
  bool get alreadyInstalled => _alreadyInstalled;
  bool get hostKeyMismatch => _mismatchedHostKeyPrefsKey != null;

  /// The config the last install actually ran with (in-memory only — includes
  /// the password). The success card renders from this, not from the raw form
  /// fields, because the installer may have adjusted values (e.g. the port).
  ServerSetupConfig? get lastConfig => _lastConfig;

  /// The persisted non-secret outcome of the last successful deploy. Survives
  /// app restarts (see [loadPersistedResult]) so the generated
  /// client_random_prefix is never lost.
  ServerSetupResult? get lastResult => _lastResult;

  // SharedPreferences keys. Form defaults use the 'deploy_form_' prefix;
  // ponytail: one JSON blob instead of nine individual keys — the model
  // already knows how to (de)serialize exactly its non-secret fields.
  static const String _formPrefsKey = 'deploy_form_config';
  static const String _lastResultPrefsKey = 'deploy_last_result';

  /// Keystore key for the last deploy's generated client random prefix — an
  /// access token, so it never sits in SharedPreferences as plaintext.
  static const String _lastResultPrefixKey = 'deploy_last_prefix';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Save the non-secret deploy form fields so they survive an app restart.
  /// Passwords are never persisted ([ServerSetupConfig.toJson] omits them).
  static Future<void> saveFormDefaults(ServerSetupConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_formPrefsKey, jsonEncode(config.toJson()));
    } catch (e) {
      debugPrint('Failed to save deploy form defaults: $e');
    }
  }

  /// Load the previously saved deploy form fields, or null when none exist.
  static Future<ServerSetupConfig?> loadFormDefaults() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_formPrefsKey);
      if (raw == null) return null;
      return ServerSetupConfig.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('Failed to load deploy form defaults: $e');
      return null;
    }
  }

  /// Restore the last successful deploy result after an app restart so the
  /// "Last deployment" card (and its Apply button) can be rebuilt.
  Future<void> loadPersistedResult() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_lastResultPrefsKey);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;

      // Older versions stored the prefix inside the JSON — migrate it to the
      // keystore and strip the plaintext copy.
      final legacyPrefix = json.remove('clientRandomPrefix') as String? ?? '';
      if (legacyPrefix.isNotEmpty) {
        await _secureStorage.write(
            key: _lastResultPrefixKey, value: legacyPrefix);
        await prefs.setString(_lastResultPrefsKey, jsonEncode(json));
      }
      json['clientRandomPrefix'] = legacyPrefix.isNotEmpty
          ? legacyPrefix
          : await _secureStorage.read(key: _lastResultPrefixKey) ?? '';

      _lastResult = ServerSetupResult.fromJson(json);
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load persisted deploy result: $e');
    }
  }

  /// Persist the outcome of a successful install. Without this, restarting
  /// the app between "install finished" and "Apply" would lose the generated
  /// client_random_prefix and permanently lock the user out of a
  /// filtering-enabled server.
  Future<void> _persistResult(ServerSetupConfig config) async {
    _lastResult = ServerSetupResult.fromConfig(config);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      // Prefix to the keystore, the rest of the result to prefs.
      await _secureStorage.write(
          key: _lastResultPrefixKey, value: _lastResult!.clientRandomPrefix);
      final json = _lastResult!.toJson()..remove('clientRandomPrefix');
      await prefs.setString(_lastResultPrefsKey, jsonEncode(json));
    } catch (e) {
      debugPrint('Failed to persist deploy result: $e');
    }
  }

  /// Forget the stored fingerprint that caused the last host-key mismatch, so
  /// the next connection trusts the server's current key. Call only after the
  /// user explicitly confirmed the key change is expected (e.g. rebuilt VPS).
  Future<void> trustNewHostKey() async {
    final key = _mismatchedHostKeyPrefsKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
    _mismatchedHostKeyPrefsKey = null;
    _addLog('Forgot saved SSH host key — the next connection will trust '
        'the new key.');
    notifyListeners();
  }

  void _setStep(SetupStep step) {
    if (step.isInProgress) _lastAttemptedStep = step;
    _currentStep = step;
    notifyListeners();
  }

  void _addLog(String message) {
    final timestamp =
        DateTime.now().toIso8601String().substring(11, 19); // HH:MM:SS
    _logs.add('[$timestamp] $message');
    if (_logs.length > 1000) {
      _logs.removeRange(0, _logs.length - 1000);
    }
    notifyListeners();
  }

  void _addLogRaw(String message) {
    _logs.add(message);
    if (_logs.length > 1000) {
      _logs.removeRange(0, _logs.length - 1000);
    }
    notifyListeners();
  }

  /// Clear the log panel only — the progress state (success card, error,
  /// current step) must survive, otherwise Clear after a successful install
  /// destroys the "Apply" button.
  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  /// Run a command via SSH and return stdout
  Future<String> _runCommand(String command) async {
    if (_client == null) throw Exception('SSH not connected');

    _addLog('\$ $command');

    final session = await _client!.execute(command);
    final stdout = await utf8.decodeStream(session.stdout);
    final stderr = await utf8.decodeStream(session.stderr);
    final exitCode = session.exitCode;

    if (stdout.trim().isNotEmpty) {
      for (final line in stdout.trim().split('\n')) {
        _addLogRaw('  $line');
      }
    }
    if (stderr.trim().isNotEmpty) {
      for (final line in stderr.trim().split('\n')) {
        _addLogRaw('  [stderr] $line');
      }
    }

    session.close();

    if (exitCode != null && exitCode != 0) {
      throw Exception(
          'Command failed (exit code $exitCode): $command\n$stderr');
    }

    return stdout.trim();
  }

  /// Upload a file via SFTP
  Future<void> _uploadFile(String remotePath, String content) async {
    if (_client == null) throw Exception('SSH not connected');

    _addLog('Uploading file: $remotePath');

    final sftp = await _client!.sftp();
    final file = await sftp.open(
      remotePath,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    await file.write(Stream.value(utf8.encode(content)));
    await file.close();
    sftp.close();
  }

  /// Main installation method.
  ///
  /// [confirmReplace] is awaited when an existing installation is detected;
  /// returning false aborts before anything is changed on the server.
  Future<void> installServer(
    ServerSetupConfig config, {
    Future<bool> Function()? confirmReplace,
  }) async {
    _logs.clear();
    _errorMessage = null;
    _alreadyInstalled = false;
    _cancelled = false;
    _lastAttemptedStep = null;
    _mismatchedHostKeyPrefsKey = null;
    notifyListeners();

    // Validate user-controlled values BEFORE any SSH work. domain/email are
    // interpolated into shell commands run as root, so reject anything that
    // isn't a clean hostname/email to prevent command injection.
    final validationError = config.validateForInstall();
    if (validationError != null) {
      _errorMessage = validationError;
      _setStep(SetupStep.failed);
      _addLog('Error: $validationError');
      // The failed state IS the result — rethrowing would only produce an
      // unhandled async exception in callers that (correctly) don't catch.
      return;
    }

    try {
      // Steps run in order; between each we bail out if the user pressed
      // Cancel. A mid-step cancel aborts promptly anyway because
      // cancelInstallation() closes the SSH connection under the command.
      final steps = <Future<void> Function()>[
        () => _stepConnect(config), // 1: SSH connect
        () => _stepCheckSystem(config, confirmReplace), // 2: check system
        _stepInstall, // 3: install TrustTunnel
        () => _stepConfigure(config), // 4: upload configs
        () => _stepCertificate(config), // 5: obtain TLS certificate
        _stepStartService, // 6: start systemd service
        _stepVerify, // 7: verify
      ];
      for (final step in steps) {
        if (_cancelled) throw Exception('Installation cancelled');
        await step();
      }
      if (_cancelled) throw Exception('Installation cancelled');

      _setStep(SetupStep.completed);
      _addLog('Installation completed successfully!');
      await _persistResult(config);
    } on _SetupCancelled {
      _addLog('Installation cancelled — existing server was kept.');
      _setStep(SetupStep.idle);
    } catch (e) {
      if (_cancelled) {
        // User-initiated cancel: keep the clean message instead of whatever
        // error the dying SSH channel produced.
        _errorMessage = 'Installation cancelled';
        _setStep(SetupStep.failed);
      } else {
        _errorMessage = e.toString();
        _setStep(SetupStep.failed);
        _addLog('Error: $e');
      }
    } finally {
      // Whatever the outcome, never leave an authenticated root SSH session
      // open (a cancel during the connect step could otherwise strand one).
      disconnect();
    }
  }

  /// Cancel a running installation.
  ///
  /// Closes the SSH connection so any in-flight command dies promptly; the
  /// install loop additionally checks the flag between steps and bails out
  /// cleanly. No server-side rollback is attempted — the partial install is
  /// simply left behind and a re-run overwrites it.
  Future<void> cancelInstallation() async {
    if (!_currentStep.isInProgress) return;
    _cancelled = true;
    _addLog('Installation cancelled by user.');
    disconnect();
    _errorMessage = 'Installation cancelled';
    _setStep(SetupStep.failed);
  }

  /// Format raw fingerprint bytes as colon-separated lowercase hex.
  String _formatFingerprint(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }

  /// Trust-on-first-use (TOFU) SSH host-key verification.
  ///
  /// On the first connection to a host:port we record the fingerprint in
  /// SharedPreferences (keyed `ssh_hostkey_<host>_<port>`) and log it so the
  /// user can eyeball it. On later connections we compare; a mismatch means a
  /// possible MITM, so we reject the key (returning false aborts the deploy).
  /// Public for unit tests.
  Future<bool> verifyHostKey(
    ServerSetupConfig config,
    String type,
    Uint8List fingerprint,
  ) async {
    final fp = _formatFingerprint(fingerprint);
    final key = 'ssh_hostkey_${config.host}_${config.sshPort}';
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(key);

    if (stored == null) {
      // First use: trust and remember.
      await prefs.setString(key, fp);
      _addLog('Trusting new SSH host key ($type) for '
          '${config.host}:${config.sshPort}');
      _addLog('Host key fingerprint (MD5): $fp');
      return true;
    }

    if (stored == fp) {
      _addLog('SSH host key verified ($type)');
      return true;
    }

    // Fingerprint changed since first trust: abort (possible MITM).
    _mismatchedHostKeyPrefsKey = key;
    _addLog('SSH host key MISMATCH for ${config.host}:${config.sshPort}!');
    _addLog('  expected: $stored');
    _addLog('  received: $fp');
    return false;
  }

  Future<void> _stepConnect(ServerSetupConfig config) async {
    _setStep(SetupStep.connecting);
    _addLog('Connecting to ${config.host}:${config.sshPort}...');

    final socket = await SSHSocket.connect(
      config.host,
      config.sshPort,
      timeout: const Duration(seconds: 15),
    );

    // TOFU host-key verification to defend against MITM.
    Future<bool> onVerifyHostKey(String type, Uint8List fingerprint) =>
        verifyHostKey(config, type, fingerprint);

    if (config.useKeyAuth && config.sshKeyPath != null) {
      // Key-based auth
      final keyFile = File(config.sshKeyPath!);
      if (!await keyFile.exists()) {
        throw Exception('SSH key not found: ${config.sshKeyPath}');
      }
      final keyContent = await keyFile.readAsString();

      _client = SSHClient(
        socket,
        username: config.sshUsername,
        identities: SSHKeyPair.fromPem(keyContent),
        onVerifyHostKey: onVerifyHostKey,
      );
    } else {
      // Password auth
      _client = SSHClient(
        socket,
        username: config.sshUsername,
        onPasswordRequest: () => config.sshPassword,
        onVerifyHostKey: onVerifyHostKey,
      );
    }

    // Wait for auth so a host-key rejection surfaces here as a clear error.
    try {
      await _client!.authenticated;
    } on SSHHostkeyError {
      throw Exception(
          'SSH host key changed — possible MITM. Aborting. '
          'If you intentionally rebuilt ${config.host}, press '
          '"Trust new host key & retry" below.');
    }

    _addLog('SSH connection established');
  }

  Future<void> _stepCheckSystem(
    ServerSetupConfig config,
    Future<bool> Function()? confirmReplace,
  ) async {
    _setStep(SetupStep.checkingSystem);

    // Check architecture
    final arch = await _runCommand('uname -m');
    _addLog('Architecture: $arch');

    if (arch != 'x86_64' && arch != 'aarch64') {
      throw Exception(
          'Unsupported architecture: $arch. Requires x86_64 or aarch64.');
    }

    // Check OS
    final osInfo = await _runCommand('cat /etc/os-release | head -5');
    _addLog('OS: ${osInfo.split('\n').first}');

    // Check if already installed
    try {
      await _runCommand('test -f /opt/trusttunnel/trusttunnel_endpoint');
      _alreadyInstalled = true;
      _addLog('Trusty is already installed on this server');
      notifyListeners();
    } catch (_) {
      _alreadyInstalled = false;
      _addLog('Trusty is not installed, will be installed');
    }

    // Existing install found — confirm before touching anything destructive
    // (the port check below stops the running service).
    if (_alreadyInstalled && confirmReplace != null) {
      final proceed = await confirmReplace();
      if (!proceed) throw _SetupCancelled();
    }

    // Check if curl is available
    try {
      await _runCommand('which curl');
    } catch (_) {
      _addLog('Installing curl...');
      await _runCommand('apt-get update -qq && apt-get install -y -qq curl');
    }

    // Check if VPN listen port is already in use and auto-pick if necessary
    _addLog('Checking if port ${config.listenPort} is available...');
    
    if (_alreadyInstalled) {
      await _runCommand('systemctl stop trusttunnel || true');
    }

    bool portFound = false;
    int currentPort = config.listenPort;
    int attempts = 0;

    while (!portFound && attempts < 10) {
      try {
        final portCheck = await _runCommand('ss -tuln | grep ":$currentPort " || true');
        if (portCheck.trim().isEmpty) {
          portFound = true;
          if (currentPort != config.listenPort) {
            _addLog('Port ${config.listenPort} is busy. Automatically selected port $currentPort.');
            config.listenPort = currentPort;
          } else {
            _addLog('Port $currentPort is available.');
          }
        } else {
          currentPort = currentPort == 443 ? 8443 : currentPort + 1;
          attempts++;
        }
      } catch (e) {
        // If ss fails, we assume port is available to not block installation
        portFound = true; 
      }
    }   
    
    if (!portFound) {
      throw Exception('Could not find an available port. Original requested port: ${config.listenPort}');
    }
  }

  Future<void> _stepInstall() async {
    _setStep(SetupStep.installing);
    _addLog('Downloading and installing TrustTunnel (latest)...');

    await _runCommand(
      'curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh | sh -s -- -a y',
    );

    // Verify installation
    await _runCommand('test -f /opt/trusttunnel/trusttunnel_endpoint');
    _addLog('Trusty installed to /opt/trusttunnel/');
  }

  Future<void> _stepConfigure(ServerSetupConfig config) async {
    _setStep(SetupStep.configuringServer);

    // Stop existing service if running
    if (_alreadyInstalled) {
      _addLog('Stopping existing service...');
      try {
        await _runCommand('systemctl stop trusttunnel 2>/dev/null || true');
      } catch (_) {}
    }

    // Generate the client_random_prefix before writing configs that reference it
    if (config.generateClientRandomPrefix && config.clientRandomPrefix.isEmpty) {
      config.clientRandomPrefix = generateClientRandomPrefix(Random.secure());
    }

    // Upload vpn.toml (includes rules_file when filtering is enabled)
    await _uploadFile('/opt/trusttunnel/vpn.toml', config.generateVpnToml());
    _addLog('vpn.toml uploaded');

    // Upload rules.toml for connection filtering
    if (config.generateClientRandomPrefix) {
      await _uploadFile('/opt/trusttunnel/rules.toml', config.generateRulesToml());
      // The prefix is a shared access token — never log its value: the log
      // panel is exactly what users copy into support requests.
      _addLog('Connection filtering enabled');
    }

    // Upload credentials.toml
    await _uploadFile(
        '/opt/trusttunnel/credentials.toml', config.generateCredentialsToml());
    _addLog('credentials.toml uploaded');

    // Upload hosts.toml (cert paths will be valid after certbot)
    await _uploadFile(
        '/opt/trusttunnel/hosts.toml', config.generateHostsToml());
    _addLog('hosts.toml uploaded');

    // Set proper permissions
    await _runCommand('chmod 600 /opt/trusttunnel/credentials.toml');
    _addLog('Server configuration ready');
  }

  Future<void> _stepCertificate(ServerSetupConfig config) async {
    _setStep(SetupStep.obtainingCertificate);

    // Check if cert already exists
    try {
      await _runCommand(
          'test -f /etc/letsencrypt/live/${config.domain}/fullchain.pem');
      _addLog('Certificate for ${config.domain} already exists');
      return;
    } catch (_) {
      _addLog('Certificate not found, obtaining via Let\'s Encrypt...');
    }

    // Install certbot if missing
    try {
      await _runCommand('which certbot');
    } catch (_) {
      _addLog('Installing certbot...');
      await _runCommand(
        'apt-get update -qq && apt-get install -y -qq certbot',
      );
    }

    // Removed fuser -k 80/tcp to avoid killing existing web servers.
    // If port 80 is occupied, certbot standalone will fail gracefully.

    // Obtain certificate
    _addLog('Requesting certificate for ${config.domain}...');
    try {
      await _runCommand(
        'certbot certonly --non-interactive --standalone '
        '--agree-tos -m ${config.email} -d ${config.domain}',
      );
    } catch (e) {
      if (e.toString().contains('TCP port 80') || e.toString().contains('already in use')) {
        _addLog('Port 80 is busy. Attempting to use Nginx/Apache plugin...');
        try {
          await _runCommand('apt-get install -y -qq python3-certbot-nginx python3-certbot-apache || true');
          await _runCommand(
            'certbot certonly --non-interactive --nginx '
            '--agree-tos -m ${config.email} -d ${config.domain} || '
            'certbot certonly --non-interactive --apache '
            '--agree-tos -m ${config.email} -d ${config.domain}'
          );
        } catch (e2) {
          throw Exception('Failed to obtain certificate because port 80 is busy and Nginx/Apache auto-config failed.\n'
              'If you already have a certificate, please manually copy it to:\n'
              '/etc/letsencrypt/live/${config.domain}/fullchain.pem\n'
              '/etc/letsencrypt/live/${config.domain}/privkey.pem\n'
              'and re-run the installation.');
        }
      } else {
        rethrow;
      }
    }

    // Verify cert exists
    await _runCommand(
        'test -f /etc/letsencrypt/live/${config.domain}/fullchain.pem');
    _addLog('Certificate obtained');
  }

  Future<void> _stepStartService() async {
    _setStep(SetupStep.startingService);

    // Copy systemd template
    _addLog('Configuring systemd service...');
    await _runCommand(
      'cp /opt/trusttunnel/trusttunnel.service.template '
      '/etc/systemd/system/trusttunnel.service',
    );

    await _runCommand('systemctl daemon-reload');
    await _runCommand('systemctl enable trusttunnel');
    await _runCommand('systemctl start trusttunnel');
    _addLog('Service started');
  }

  Future<void> _stepVerify() async {
    _setStep(SetupStep.verifying);
    _addLog('Waiting for service to start...');

    // Wait for service to start
    await Future.delayed(const Duration(seconds: 3));

    try {
      final status = await _runCommand('systemctl is-active trusttunnel');
      if (status.trim() == 'active') {
        _addLog('Trusty service is running!');
      }
    } catch (e) {
      // systemctl is-active returns non-zero if not active, causing _runCommand to throw.
      // Get journal logs for debugging
      final journal = await _runCommand(
          'journalctl -u trusttunnel --no-pager -n 20 2>/dev/null || true');
      throw Exception(
          'Service failed to start.\n\nLogs:\n$journal\n\nOriginal error: $e');
    }
  }

  /// Apply server setup to client connection config.
  ///
  /// Uses the in-memory install config when available; after an app restart
  /// it falls back to the persisted [lastResult]. The password is never
  /// persisted, so in the fallback case we keep the matched server's stored
  /// password (re-deploy) or leave it empty for the user to enter in Settings.
  Future<void> applyToClientConfig(ConfigService configService) async {
    // Trust the in-memory config only when the CURRENT run completed —
    // after an aborted run ("Keep existing") _lastConfig belongs to the
    // aborted attempt while the UI shows the persisted last SUCCESSFUL
    // deploy, and applying the aborted values would corrupt the entry.
    final setup =
        _currentStep == SetupStep.completed ? _lastConfig : null;
    final result =
        setup != null ? ServerSetupResult.fromConfig(setup) : _lastResult;
    if (result == null) return;

    // Deploying to a fresh VPS must never clobber another saved server:
    // update the entry with the same hostname if one exists, otherwise add a
    // new entry. Either way it becomes the active server (saveConfig upserts
    // by id and activates), and app-wide settings (DNS, split tunneling)
    // carry over from the current config.
    final existingConfig = await configService.loadConfig();
    ServerConfig? match;
    for (final s in await configService.loadServers()) {
      if (s.hostname == result.domain) match = s;
    }

    // Only override the client prefix when the installer generated one;
    // a brand-new server starts with an empty prefix, a re-deployed one
    // keeps its stored value (list entries no longer carry the prefix —
    // it lives in the keystore, so resolve it through loadServerEntry).
    var prefix = result.clientRandomPrefix;
    if (prefix.isEmpty && match != null) {
      prefix =
          (await configService.loadServerEntry(match.id))?.clientRandomPrefix ??
              '';
    }

    // The persisted-result path has no password ('' — never stored).
    // saveConfig never overwrites a stored password with an empty string,
    // so a re-deployed server keeps its previously working credential.
    final password = setup?.vpnPassword ?? '';

    final updatedConfig = existingConfig.copyWith(
      id: match?.id ?? ConfigService.newServerId(),
      // A matched entry keeps its display name; a brand-new one must not
      // inherit the currently active server's name.
      name: match?.name ?? '',
      hostname: result.domain,
      address: result.host,
      port: result.listenPort,
      username: result.vpnUsername,
      password: password,
      clientRandomPrefix: prefix,
      // Per-server fields must not leak from the currently active server
      // into this entry (saveConfig overwrites the whole list entry): a
      // matched server keeps its own values, a fresh deploy starts from the
      // defaults — mirroring the per-server set switchServer carries.
      hasIpv6: match?.hasIpv6 ?? true,
      skipVerification: match?.skipVerification ?? false,
      upstreamProtocol: match?.upstreamProtocol ?? 'http2',
      antiDpi: match?.antiDpi ?? false,
      customSni: match?.customSni ?? '',
      postQuantumGroupEnabled: match?.postQuantumGroupEnabled ?? true,
    );
    await configService.saveConfig(updatedConfig);
  }

  ServerSetupConfig? _lastConfig;
  ServerSetupResult? _lastResult;

  /// Wrapper that stores config for later use by applyToClientConfig
  Future<void> installAndRemember(
    ServerSetupConfig config, {
    Future<bool> Function()? confirmReplace,
  }) async {
    _lastConfig = config;
    await installServer(config, confirmReplace: confirmReplace);
  }

  /// Disconnect SSH
  void disconnect() {
    _client?.close();
    _client = null;
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}

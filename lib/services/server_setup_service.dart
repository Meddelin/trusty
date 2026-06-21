import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import '../models/setup_step.dart';
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
  final List<String> _logs = [];
  String? _errorMessage;
  SSHClient? _client;
  bool _alreadyInstalled = false;

  // Public getters
  SetupStep get currentStep => _currentStep;
  List<String> get logs => List.unmodifiable(_logs);
  String? get errorMessage => _errorMessage;
  bool get alreadyInstalled => _alreadyInstalled;

  void _setStep(SetupStep step) {
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

  void clearLogs() {
    _logs.clear();
    _errorMessage = null;
    _currentStep = SetupStep.idle;
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
    notifyListeners();

    try {
      // Step 1: SSH connect
      await _stepConnect(config);

      // Step 2: Check system (may prompt to replace an existing install)
      await _stepCheckSystem(config, confirmReplace);

      // Step 3: Install TrustTunnel
      await _stepInstall();

      // Step 4: Upload configs
      await _stepConfigure(config);

      // Step 5: Obtain TLS certificate
      await _stepCertificate(config);

      // Step 6: Start systemd service
      await _stepStartService();

      // Step 7: Verify
      await _stepVerify();

      _setStep(SetupStep.completed);
      _addLog('Installation completed successfully!');
    } on _SetupCancelled {
      _addLog('Installation cancelled — existing server was kept.');
      disconnect();
      _setStep(SetupStep.idle);
    } catch (e) {
      _errorMessage = e.toString();
      _setStep(SetupStep.failed);
      _addLog('Error: $e');
    }
  }

  Future<void> _stepConnect(ServerSetupConfig config) async {
    _setStep(SetupStep.connecting);
    _addLog('Connecting to ${config.host}:${config.sshPort}...');

    final socket = await SSHSocket.connect(
      config.host,
      config.sshPort,
      timeout: const Duration(seconds: 15),
    );

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
      );
    } else {
      // Password auth
      _client = SSHClient(
        socket,
        username: config.sshUsername,
        onPasswordRequest: () => config.sshPassword,
      );
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
      _addLog('Connection filtering enabled (prefix: ${config.clientRandomPrefix})');
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

  /// Apply server setup to client connection config
  Future<void> applyToClientConfig(ConfigService configService) async {
    final existingConfig = await configService.loadConfig();
    // Only override the client prefix when the installer generated one.
    final prefix = (_lastConfig?.clientRandomPrefix.isNotEmpty ?? false)
        ? _lastConfig!.clientRandomPrefix
        : existingConfig.clientRandomPrefix;
    final updatedConfig = existingConfig.copyWith(
      hostname: _lastConfig?.domain ?? existingConfig.hostname,
      address: _lastConfig?.host ?? existingConfig.address,
      port: _lastConfig?.listenPort ?? existingConfig.port,
      username: _lastConfig?.vpnUsername ?? existingConfig.username,
      password: _lastConfig?.vpnPassword ?? existingConfig.password,
      clientRandomPrefix: prefix,
    );
    await configService.saveConfig(updatedConfig);
  }

  ServerSetupConfig? _lastConfig;

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

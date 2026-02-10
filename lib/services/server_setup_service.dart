import 'dart:convert';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import '../models/setup_step.dart';
import '../models/server_setup_config.dart';
import 'config_service.dart';

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

  /// Main installation method
  Future<void> installServer(ServerSetupConfig config) async {
    _logs.clear();
    _errorMessage = null;
    _alreadyInstalled = false;
    notifyListeners();

    try {
      // Step 1: SSH connect
      await _stepConnect(config);

      // Step 2: Check system
      await _stepCheckSystem();

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

  Future<void> _stepCheckSystem() async {
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

    // Check if curl is available
    try {
      await _runCommand('which curl');
    } catch (_) {
      _addLog('Installing curl...');
      await _runCommand('apt-get update -qq && apt-get install -y -qq curl');
    }
  }

  Future<void> _stepInstall() async {
    _setStep(SetupStep.installing);
    _addLog('Downloading and installing Trusty...');

    await _runCommand(
      'curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnel/refs/heads/master/scripts/install.sh | sh -s -',
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

    // Upload vpn.toml
    await _uploadFile('/opt/trusttunnel/vpn.toml', config.generateVpnToml());
    _addLog('vpn.toml uploaded');

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

    // Free port 80 if occupied
    try {
      await _runCommand(
          'fuser -k 80/tcp 2>/dev/null || true');
    } catch (_) {}

    // Obtain certificate
    _addLog('Requesting certificate for ${config.domain}...');
    await _runCommand(
      'certbot certonly --non-interactive --standalone '
      '--agree-tos -m ${config.email} -d ${config.domain}',
    );

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

    final status = await _runCommand('systemctl is-active trusttunnel');
    if (status.trim() == 'active') {
      _addLog('Trusty service is running!');
    } else {
      // Get journal logs for debugging
      final journal = await _runCommand(
          'journalctl -u trusttunnel --no-pager -n 20 2>/dev/null || true');
      throw Exception(
          'Service failed to start (status: $status)\n\nLogs:\n$journal');
    }
  }

  /// Apply server setup to client connection config
  Future<void> applyToClientConfig(ConfigService configService) async {
    final existingConfig = await configService.loadConfig();
    final updatedConfig = existingConfig.copyWith(
      hostname: _lastConfig?.domain ?? existingConfig.hostname,
      address: _lastConfig?.host ?? existingConfig.address,
      port: _lastConfig?.listenPort ?? existingConfig.port,
      username: _lastConfig?.vpnUsername ?? existingConfig.username,
      password: _lastConfig?.vpnPassword ?? existingConfig.password,
    );
    await configService.saveConfig(updatedConfig);
  }

  ServerSetupConfig? _lastConfig;

  /// Wrapper that stores config for later use by applyToClientConfig
  Future<void> installAndRemember(ServerSetupConfig config) async {
    _lastConfig = config;
    await installServer(config);
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

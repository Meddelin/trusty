import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/server_config.dart';
import '../models/vpn_status.dart';
import 'config_service.dart';

/// Service for managing VPN connection
class VpnService extends ChangeNotifier {
  final ConfigService _configService;

  VpnStatus _status = VpnStatus.disconnected;
  Process? _process;
  final List<String> _logs = [];
  String? _errorMessage;
  final List<void Function(String)> _logObservers = [];
  Timer? _logNotifyTimer;

  VpnService(this._configService);

  VpnStatus get status => _status;
  List<String> get logs => List.unmodifiable(_logs);
  String? get errorMessage => _errorMessage;

  /// Add a log observer for real-time log monitoring
  void addLogObserver(void Function(String) observer) {
    _logObservers.add(observer);
  }

  /// Remove a log observer
  void removeLogObserver(void Function(String) observer) {
    _logObservers.remove(observer);
  }

  /// Connect to VPN
  Future<void> connect(ServerConfig config) async {
    if (_status.isActive) {
      _addLog('⚠️ Already connected or connecting');
      return;
    }

    // Ensure previous process is fully cleaned up
    if (_process != null) {
      _addLog('⚠️ Detected unfinished process, terminating...');
      await disconnect();
      // disconnect() now handles all cleanup and waiting
    }

    try {
      _setStatus(VpnStatus.connecting);
      _errorMessage = null;

      // Debug: check config - SAFE version
      if (kDebugMode) {
        print('VPN Connect - config object: $config');
        print('VPN Connect - hostname: ${config.hostname}');
        print('VPN Connect - address: ${config.address}');
      }

      final hostname = config.hostname;
      _addLog('🔄 Connecting to $hostname...');

      // Check if trusttunnel.exe exists
      if (kDebugMode) {
        print('VPN Connect - _configService: $_configService');
      }

      final exePath = await _configService.getTrustTunnelExecutable();
      final exeFile = File(exePath);
      if (!await exeFile.exists()) {
        final clientDir = await _configService.getClientDirectory();
        final exeName = Platform.isWindows ? 'trusttunnel_client.exe' : 'trusttunnel_client';
        throw Exception(
          'Trusty client not found!\n'
          'Path: $exePath\n'
          'Client directory: $clientDir\n'
          'Download $exeName and place it in the client/ directory',
        );
      }

      final configPath = await _configService.getConfigFilePath();

      // Always write config file with current settings
      _addLog('📝 Creating configuration file...');
      await _configService.writeConfigFile(config);

      // Start process
      _addLog('🚀 Starting Trusty client...');

      if (kDebugMode) {
        print('Starting process: $exePath');
        print('Args: --config $configPath --loglevel ${config.logLevel}');
      }

      try {
        _process = await Process.start(
          exePath,
          [
            '--config',
            configPath,
            '--loglevel',
            config.logLevel,
          ],
          runInShell: false,
        );

        if (kDebugMode) {
          print('Process started successfully, PID: ${_process?.pid}');
        }
      } catch (e, stackTrace) {
        if (kDebugMode) {
          print('Process.start failed: $e');
          print('Stack trace: $stackTrace');
        }
        throw Exception(
          'Failed to start client: $e\n'
          'Path: $exePath',
        );
      }

      // Verify process was created successfully
      if (_process == null) {
        throw Exception('Process.start returned null - unknown error');
      }

      // Store process reference for listeners
      final process = _process!;

      // Listen to stdout
      process.stdout.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            _addLog(line.trim());
          }
        }
      });

      // Listen to stderr
      process.stderr.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            _addLog(_formatLogLine(line.trim()));
          }
        }
      });

      // Wait a bit to check if process starts successfully
      if (kDebugMode) {
        print('Waiting 2 seconds for process to initialize...');
      }
      await Future.delayed(const Duration(seconds: 2));

      // Check if process already exited (error during startup)
      if (kDebugMode) {
        print('Checking if process exited...');
      }
      bool processExited = false;
      try {
        final exitCode = await process.exitCode.timeout(const Duration(milliseconds: 100));
        processExited = true;

        if (kDebugMode) {
          print('Process exited with code: $exitCode');
        }

        _addLog('🛑 Process exited with code: $exitCode');
        _process = null;

        if (exitCode != 0) {
          if (Platform.isWindows) {
            // Check if it's a Wintun initialization error (Windows only)
            final logsToCheck = _logs.length > 10 ? _logs.sublist(_logs.length - 10) : _logs;
            final lastLogs = logsToCheck.join('\n').toLowerCase();

            if (kDebugMode) {
              print('Exit code check: exitCode=$exitCode, logs count=${_logs.length}');
              print('Last 10 logs:\n${logsToCheck.join('\n')}');
              print('Last logs contain "wintun": ${lastLogs.contains('wintun')}');
            }

            final isWintunBusy = lastLogs.contains('wintun') &&
                                 (lastLogs.contains('already') || lastLogs.contains('already'));
            final isAccessDenied = lastLogs.contains('access is denied') ||
                                   lastLogs.contains('access denied') ||
                                   lastLogs.contains('code 0x5') ||
                                   lastLogs.contains('code 0x00000005');

            if (isAccessDenied) {
              _errorMessage = 'Access denied. Run the application as administrator.';
              _addLog('🔒 Administrator privileges are required to create a VPN tunnel.');
              _addLog('💡 Close the application and run it as administrator (right-click → Run as administrator).');
              await Future.delayed(const Duration(seconds: 2));
            } else if (isWintunBusy) {
              _errorMessage = 'Wintun adapter is still busy. Wait before retrying.';
              _addLog('⏳ Waiting for Wintun adapter to release...');
              // CRITICAL: Wait for Wintun to fully release
              await Future.delayed(const Duration(seconds: 5));
              _addLog('✅ Wintun adapter should be free now');
            } else {
              _errorMessage = 'Process exited with error (code: $exitCode)';
              await Future.delayed(const Duration(seconds: 2));
            }
          } else {
            // macOS/Linux: no Wintun, minimal delay
            _errorMessage = 'Process exited with error (code: $exitCode)';
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }

        throw Exception('Process exited immediately after start');
      } on TimeoutException {
        // Process is still running - good!
        processExited = false;
      }

      if (!processExited && _status == VpnStatus.connecting) {
        // Setup exit handler for later
        process.exitCode.then((code) async {
          _addLog('🛑 Process exited with code: $code');
          _process = null;

          // Wait for Wintun to release
          await Future.delayed(const Duration(seconds: 3));

          if (_status == VpnStatus.connected) {
            _setStatus(VpnStatus.disconnected);
          }
        });

        _addLog('✅ Connected successfully!');
        _setStatus(VpnStatus.connected);
      } else if (!processExited) {
        throw Exception('Status changed during connection: $_status');
      }
    } catch (e, stackTrace) {
      // Extract meaningful error message
      String errorMsg = e.toString();
      if (errorMsg.contains('Exception:')) {
        errorMsg = errorMsg.replaceFirst('Exception:', '').trim();
      }

      _errorMessage = errorMsg;
      _addLog('❌ Error: $errorMsg');

      // Log stack trace for debugging
      if (kDebugMode) {
        print('Connection error stack trace: $stackTrace');
      }

      // If process is still running, kill it
      if (_process != null) {
        _addLog('🔄 Terminating process after error...');
        await disconnect();
      } else {
        // Process already terminated, just update state
        _setStatus(VpnStatus.disconnected);
      }

      rethrow;
    }
  }

  /// Disconnect from VPN
  Future<void> disconnect() async {
    if (_status == VpnStatus.disconnected) {
      return;
    }

    try {
      _setStatus(VpnStatus.disconnecting);
      _addLog('🔄 Disconnecting...');

      final currentProcess = _process;
      if (currentProcess != null) {
        // Try graceful shutdown first (SIGTERM)
        _addLog('📤 Sending termination signal...');

        try {
          currentProcess.kill(ProcessSignal.sigterm);
        } catch (e) {
          _addLog('⚠️ Failed to send SIGTERM: $e');
        }

        // Wait for graceful shutdown (3 seconds)
        bool exited = false;
        try {
          await currentProcess.exitCode.timeout(
            const Duration(seconds: 3),
          );
          exited = true;
          _addLog('✅ Process terminated gracefully');
        } catch (e) {
          // Timeout - process didn't exit gracefully
          _addLog('⚠️ Process did not terminate gracefully, forcing shutdown...');
          exited = false;
        }

        // If still running, force kill
        if (!exited) {
          try {
            currentProcess.kill(ProcessSignal.sigkill);

            // Wait for force kill (2 seconds max)
            await currentProcess.exitCode.timeout(
              const Duration(seconds: 2),
            );
            _addLog('✅ Process force terminated');
          } catch (e) {
            _addLog('⚠️ Process not responding: $e');
          }
        }

        // Process reference will be cleared by exitCode handler
        // Don't set _process = null here to avoid race condition
      } else {
        // No process to kill, just clean up state
        _addLog('ℹ️ Process already terminated');
      }

      // Don't delete config file - keep it for next connection
      // await _configService.deleteConfigFile();

      // Wait for TUN adapter to release
      if (Platform.isWindows) {
        // CRITICAL: Wintun adapter needs 5+ seconds to fully release
        _addLog('⏳ Waiting for Wintun adapter to release...');
        await Future.delayed(const Duration(seconds: 5));
      }

      _addLog('✅ Disconnected');
      _setStatus(VpnStatus.disconnected);
      _errorMessage = null;
    } catch (e) {
      _addLog('❌ Error during disconnect: $e');
      // Force cleanup even on error
      _process = null;
      _setStatus(VpnStatus.disconnected);
    }
  }

  /// Clear logs
  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  /// Format log line based on log level
  String _formatLogLine(String line) {
    // Check for log level in the line
    if (line.contains(' ERROR ')) {
      return '❌ $line';
    } else if (line.contains(' WARN ')) {
      return '⚠️ $line';
    } else if (line.contains(' INFO ')) {
      return 'ℹ️ $line';
    } else if (line.contains(' DEBUG ') || line.contains(' TRACE ')) {
      return '🔍 $line';
    }
    // Default - no prefix for unrecognized format
    return '📋 $line';
  }

  /// Add log entry
  void _addLog(String message) {
    try {
      final timestamp = DateTime.now().toString().substring(11, 19);
      final entry = '[$timestamp] $message';
      _logs.add(entry);

      // Keep only last 500 logs
      if (_logs.length > 500) {
        _logs.removeAt(0);
      }

      // Notify log observers
      for (final observer in _logObservers) {
        try {
          observer(entry);
        } catch (e) {
          if (kDebugMode) {
            print('Error in log observer: $e');
          }
        }
      }

      _scheduleLogNotify();
    } catch (e) {
      if (kDebugMode) {
        print('Error in _addLog: $e, message: $message');
      }
    }
  }

  /// Throttle log notifications to max ~10fps
  void _scheduleLogNotify() {
    _logNotifyTimer ??= Timer(const Duration(milliseconds: 100), () {
      _logNotifyTimer = null;
      notifyListeners();
    });
  }

  /// Set status and notify listeners
  void _setStatus(VpnStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      notifyListeners();
    }
  }

  /// Graceful shutdown - call before app exit
  /// This method ensures VPN process is terminated and Wintun adapter is released
  Future<void> shutdown() async {
    final currentProcess = _process;
    if (currentProcess != null) {
      if (kDebugMode) {
        print('Shutdown: starting cleanup, PID: ${currentProcess.pid}');
      }
      _addLog('🔄 Shutting down...');

      // Try graceful shutdown first
      try {
        currentProcess.kill(ProcessSignal.sigterm);
        if (kDebugMode) {
          print('Shutdown: sent SIGTERM');
        }
      } catch (e) {
        _addLog('⚠️ Error sending SIGTERM: $e');
      }

      // Wait for graceful exit
      bool exited = false;
      try {
        await currentProcess.exitCode.timeout(const Duration(seconds: 3));
        _addLog('✅ Client terminated gracefully');
        exited = true;
        if (kDebugMode) {
          print('Shutdown: process exited gracefully');
        }
      } catch (e) {
        // Force kill if graceful shutdown failed
        if (kDebugMode) {
          print('Shutdown: graceful exit timeout, forcing kill');
        }
        try {
          currentProcess.kill(ProcessSignal.sigkill);
          await currentProcess.exitCode.timeout(const Duration(seconds: 2));
          exited = true;
          if (kDebugMode) {
            print('Shutdown: process force killed');
          }
        } catch (_) {
          _addLog('⚠️ Failed to terminate process');
          if (kDebugMode) {
            print('Shutdown: force kill failed');
          }
        }
      }

      _process = null;

      // Wait for TUN adapter to release if process was killed
      if (exited && Platform.isWindows) {
        if (kDebugMode) {
          print('Shutdown: waiting for Wintun release (5 sec)...');
        }
        _addLog('⏳ Waiting for Wintun adapter to release...');
        await Future.delayed(const Duration(seconds: 5));
      }
    }

    _setStatus(VpnStatus.disconnected);

    if (kDebugMode) {
      print('Shutdown: complete');
    }
  }

  /// Dispose and cleanup
  @override
  void dispose() {
    // Synchronous cleanup - prefer calling shutdown() before dispose
    final currentProcess = _process;
    if (currentProcess != null) {
      if (kDebugMode) {
        print('Dispose: cleaning up process PID: ${currentProcess.pid}');
      }
      try {
        currentProcess.kill(ProcessSignal.sigterm);
        // Give it a moment to handle the signal
        Future.delayed(const Duration(milliseconds: 500), () {
          try {
            currentProcess.kill(ProcessSignal.sigkill);
          } catch (_) {
            // Ignore errors during cleanup
          }
        });
      } catch (e) {
        // Ignore errors during dispose
        if (kDebugMode) {
          print('Dispose: error killing process: $e');
        }
      }
    }
    _logNotifyTimer?.cancel();
    _process = null;
    super.dispose();
  }
}

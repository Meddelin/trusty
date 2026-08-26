import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/server_config.dart';
import '../models/vpn_status.dart';
import '../utils/log_level.dart';
import '../utils/windows_short_path.dart';
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

  // Deduplication: collapse consecutive log lines that differ only in numbers
  String? _lastMsgPattern;
  int _dupCount = 0;

  /// On Windows, the Wintun adapter takes a few seconds to release after the
  /// client process dies. Instead of blocking the foreground during disconnect,
  /// we record when the adapter is expected to be free and pay that cost lazily
  /// at the start of the NEXT connect() (usually already elapsed → no wait).
  DateTime? _adapterBusyUntil;

  /// How long the Wintun adapter is assumed to stay busy after the process dies.
  static const Duration _adapterReleaseDuration = Duration(seconds: 5);

  /// Stdout/stderr markers the CLI prints once the tunnel is actually up.
  /// Verified from real CLI logs.
  static const List<String> _connectedMarkers = [
    'VPN_SS_CONNECTED',
    'Successfully connected to endpoint',
  ];

  VpnService(this._configService);

  /// Remaining time to wait for the Wintun adapter to release, given the
  /// recorded busy-until timestamp and the current time. Pure and clamped to
  /// zero so it never returns a negative duration. Returns [Duration.zero] when
  /// no disconnect is pending (busyUntil == null) or the window has elapsed.
  static Duration remainingAdapterWait(DateTime? busyUntil, DateTime now) {
    if (busyUntil == null) return Duration.zero;
    final remaining = busyUntil.difference(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// True if [line] contains a marker indicating the tunnel is up.
  static bool isConnectedMarker(String line) {
    for (final marker in _connectedMarkers) {
      if (line.contains(marker)) return true;
    }
    return false;
  }

  VpnStatus get status => _status;
  List<String> get logs => List.unmodifiable(_logs);
  String? get errorMessage => _errorMessage;

  /// When the current connection was established (null unless connected).
  DateTime? get connectedAt => _connectedAt;
  DateTime? _connectedAt;

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

      // On macOS, the client needs full root (sudo) to set up TUN routes.
      // setuid is not enough — the client drops to the real uid when it shells
      // out to `ifconfig`, so configure passwordless sudo once instead.
      if (Platform.isMacOS) {
        await _ensureMacOSPrivileges(exePath);
      }

      final configPath = await _configService.getConfigFilePath();

      // Always write config file with current settings
      _addLog('📝 Creating configuration file...');
      await _configService.writeConfigFile(config);

      // Oversized exclusion sets slow tunnel setup down — warn, don't block.
      final merged = _configService.lastMergedExclusionCount;
      if (merged > ConfigService.mergedExclusionsSoftLimit) {
        _addLog('⚠️ $merged exclusions after merging routing lists (soft '
            'limit ${ConfigService.mergedExclusionsSoftLimit}) — connection '
            'setup may be slow; consider disabling some lists');
      }

      // Pay the deferred Wintun-release cost (if any) right before launching.
      // disconnect() returns instantly and records _adapterBusyUntil; the wait
      // for the adapter to free up is paid here, lazily, and is usually already
      // elapsed (so this is a no-op) unless this is a fast disconnect→reconnect.
      final adapterWait =
          remainingAdapterWait(_adapterBusyUntil, DateTime.now());
      if (adapterWait > Duration.zero) {
        _addLog('⏳ Waiting for Wintun adapter to release...');
        await Future.delayed(adapterWait);
        _addLog('✅ Wintun adapter should be free now');
      }
      _adapterBusyUntil = null;

      // disconnect() may have been called while we waited — don't launch a
      // process the user has already cancelled.
      if (_status != VpnStatus.connecting) {
        _addLog('ℹ️ Connection cancelled before launch');
        return;
      }

      // Start process
      _addLog('🚀 Starting Trusty client...');

      if (kDebugMode) {
        print('Starting process: $exePath');
        print('Args: --config $configPath --loglevel ${config.logLevel}');
      }

      try {
        // The CLI can't start when its exe/config path contains non-ASCII
        // characters (e.g. a Cyrillic install dir). On Windows, pass the 8.3
        // short paths (always ASCII); no-op everywhere else.
        final shortExe = toShortPathName(exePath);
        final shortConfig = toShortPathName(configPath);
        final workDir = Platform.isWindows
            ? toShortPathName(await _configService.getClientDirectory())
            : null;

        // macOS runs the client through sudo (full root); the setuid path is
        // insufficient. Other platforms launch the binary directly.
        final launchExe = Platform.isMacOS ? 'sudo' : shortExe;
        final launchArgs = Platform.isMacOS
            ? ['-n', exePath, '--config', configPath, '--loglevel', config.logLevel]
            : ['--config', shortConfig, '--loglevel', config.logLevel];
        _process = await Process.start(
          launchExe,
          launchArgs,
          runInShell: false,
          workingDirectory: workDir,
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

      // Fresh readiness signal for this attempt. Completed when the CLI prints
      // a "tunnel up" marker on stdout/stderr (see _connectedMarkers).
      final connectedSignal = Completer<void>();

      // Listen to stdout
      process.stdout.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            _addLog(trimmed);
            if (!connectedSignal.isCompleted && isConnectedMarker(trimmed)) {
              connectedSignal.complete();
            }
          }
        }
      });

      // Listen to stderr
      process.stderr.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            _addLog(_formatLogLine(trimmed));
            if (!connectedSignal.isCompleted && isConnectedMarker(trimmed)) {
              connectedSignal.complete();
            }
          }
        }
      });

      // Race three outcomes instead of sleeping a fixed 2s:
      //   1. a readiness marker on stdout/stderr → connected (usually fast),
      //   2. the process exits → startup error (handled below),
      //   3. a timeout fallback → assume connected if still alive (safety net).
      // _RaceResult encodes which arm won so we can branch without re-querying.
      if (kDebugMode) {
        print('Waiting for readiness marker / early exit...');
      }
      const readinessTimeout = Duration(seconds: 5);
      final outcome = await Future.any<_RaceResult>([
        connectedSignal.future.then((_) => _RaceResult.connected),
        process.exitCode.then((code) => _RaceResult.exited(code)),
        Future<_RaceResult>.delayed(
          readinessTimeout,
          () => _RaceResult.timeout,
        ),
      ]);

      bool processExited = outcome.kind == _RaceOutcome.exited;
      if (processExited) {
        final exitCode = outcome.exitCode!;

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
                                 (lastLogs.contains('already') || lastLogs.contains('busy'));
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
            // macOS/Linux: check for TUN permission errors (e.g. setuid was removed)
            final logsToCheck = _logs.length > 15 ? _logs.sublist(_logs.length - 15) : _logs;
            final lastLogs = logsToCheck.join('\n').toLowerCase();

            final isTunPermissionDenied = lastLogs.contains('tun_open') &&
                (lastLogs.contains('operation not permitted') || lastLogs.contains('(1) operation'));

            if (isTunPermissionDenied && Platform.isMacOS) {
              _errorMessage = 'TUN device permission lost. Reconnect to re-grant access.';
              _addLog('🔒 TUN permission was reset (e.g. after an app update). Reconnecting will show the password dialog again.');
              await Future.delayed(const Duration(seconds: 2));
            } else {
              _errorMessage = 'Process exited with error (code: $exitCode)';
              await Future.delayed(const Duration(milliseconds: 500));
            }
          }
        }

        throw Exception('Process exited immediately after start');
      }

      // Process is still alive: either a readiness marker arrived (fast path)
      // or the timeout fallback fired with the process still running.
      if (!processExited && _status == VpnStatus.connecting) {
        // Setup exit handler for later (covers the process dying while connected,
        // e.g. the link drops). The adapter-busy cost is deferred to the next
        // connect() via _adapterBusyUntil rather than blocking here.
        process.exitCode.then((code) {
          // Stale-handler guard: if disconnect() already cleared _process or a
          // new connect() replaced it, this exit belongs to an old process —
          // touching shared state here would wipe the new process reference
          // and flip a live connection back to "disconnected".
          if (!identical(_process, process)) return;
          _addLog('🛑 Process exited with code: $code');
          _process = null;
          _lastMsgPattern = null;
          _dupCount = 0;
          if (Platform.isWindows) {
            _adapterBusyUntil = DateTime.now().add(_adapterReleaseDuration);
          }

          if (_status == VpnStatus.connected) {
            _setStatus(VpnStatus.disconnected);
          }
        });

        if (outcome.kind == _RaceOutcome.timeout) {
          // Be honest: nothing confirmed the tunnel, the process is merely
          // still alive after the timeout.
          _addLog('ℹ️ No readiness confirmation from the client yet — assuming connected');
        } else {
          _addLog('✅ Connected successfully!');
        }
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

      // The exit-code branch may have set a specific, actionable message
      // ("run as administrator", "Wintun busy") — keep it over the generic
      // exception text.
      final message = _errorMessage ?? errorMsg;
      _addLog('❌ Error: $message');

      // Log stack trace for debugging
      if (kDebugMode) {
        print('Connection error stack trace: $stackTrace');
      }

      // If process is still running, kill it
      if (_process != null) {
        _addLog('🔄 Terminating process after error...');
        await disconnect();
      }

      // Land in a real error state so the Home screen shows the error card;
      // disconnect() above resets both status and message, so set them last.
      _errorMessage = message;
      _setStatus(VpnStatus.error);
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
        // Kill immediately and flip the UI back to "Connect" without lingering.
        // On Windows, kill() maps to TerminateProcess, which is effectively
        // synchronous, so there is no point waiting for a graceful exit. On
        // macOS we send SIGTERM (the client cleans up the utun device on it).
        _addLog('📤 Sending termination signal...');
        try {
          currentProcess.kill(
            Platform.isWindows ? ProcessSignal.sigkill : ProcessSignal.sigterm,
          );
        } catch (e) {
          _addLog('⚠️ Failed to terminate process: $e');
        }

        // Defer the Wintun-release cost: the adapter is busy for a few seconds
        // after the process dies, but we do NOT block here. The wait (if still
        // pending) is paid lazily at the start of the next connect().
        if (Platform.isWindows) {
          _adapterBusyUntil = DateTime.now().add(_adapterReleaseDuration);
        }

        // The exitCode handler installed in connect() clears _process; clear it
        // here too so a subsequent connect() doesn't see a stale reference.
        _process = null;
      } else {
        // No process to kill, just clean up state
        _addLog('ℹ️ Process already terminated');
      }

      // The TOML holds the password in plaintext and is rewritten on every
      // connect anyway — remove it now that the client process is gone.
      // deleteConfigFile swallows its own errors (the file may not exist).
      await _configService.deleteConfigFile();

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
    _lastMsgPattern = null;
    _dupCount = 0;
    notifyListeners();
  }

  /// Check whether passwordless sudo is already configured for the binary (macOS).
  Future<bool> _hasSudoNopasswd(String exePath) async {
    // `sudo -n` fails fast (non-zero) if a password would be required, so this
    // returns true only when the NOPASSWD rule is in place for this binary.
    final result = await Process.run('sudo', ['-n', exePath, '--version']);
    return result.exitCode == 0;
  }

  /// Returns a human-readable reason if [s] contains characters that are unsafe
  /// to embed in a root shell command, or null if it is safe.
  ///
  /// The sudoers rule we build is executed as ROOT via `osascript ... with
  /// administrator privileges`. Any of these characters could break out of the
  /// surrounding shell quoting and run arbitrary commands as root, so we reject
  /// them outright rather than try to escape every edge case.
  static String? sudoersUnsafeReason(String s) {
    // Whitespace is rejected too: sudoers cannot express an unescaped space in
    // a command path, so a value with one would fail visudo validation.
    const dangerous = [
      '\'', '"', '\n', '\r', '\t', ' ', '`', r'$', ';', '|', '&', '\\'
    ];
    const names = {'\n': r'\n', '\r': r'\r', '\t': 'tab', ' ': 'space'};
    for (final c in dangerous) {
      if (s.contains(c)) {
        return 'contains an unsupported character (${names[c] ?? c})';
      }
    }
    return null;
  }

  /// Ensure passwordless sudo is configured for the client binary. If not,
  /// prompt once via the macOS password dialog (osascript) and write a
  /// NOPASSWD sudoers rule for this exact binary path, validated by visudo.
  Future<void> _ensureMacOSPrivileges(String exePath) async {
    if (await _hasSudoNopasswd(exePath)) return;

    _addLog('🔐 One-time setup: requesting administrator access to enable VPN tunnel...');

    final user = Platform.environment['USER'] ?? '';

    // Validate before any value reaches the root shell. exePath is an absolute
    // path to the bundled client binary and user is the login name; neither
    // should contain shell metacharacters. Rejecting them here closes the
    // injection entirely (the dangerous chars can never reach the root shell).
    final userReason = sudoersUnsafeReason(user);
    if (userReason != null) {
      throw Exception('Cannot set up VPN privileges: your username $userReason.');
    }
    final pathReason = sudoersUnsafeReason(exePath);
    if (pathReason != null) {
      throw Exception(
          'Cannot set up VPN privileges: the app path $pathReason.\nPlease move the app to a path without special characters (e.g. /Applications) and try again.');
    }

    final rule = '$user ALL=(ALL) NOPASSWD: $exePath';
    // Belt-and-suspenders: even though validation above already rejected single
    // quotes, escape them with the standard `'\''` trick so the value embeds
    // literally inside the single-quoted echo and is never re-interpreted.
    final escapedRule = rule.replaceAll('\'', '\'\\\'\'');
    // Write the rule to a staging file, validate with visudo, and only then
    // move it into place. Sudo ignores #includedir files whose name contains a
    // dot, so a rule that fails validation can never take effect (or break
    // sudo system-wide) — the old atomic-write-then-validate order left an
    // invalid file live in /etc/sudoers.d on visudo failure.
    final inner =
        "echo '$escapedRule' > /etc/sudoers.d/trusty.tmp && chmod 440 /etc/sudoers.d/trusty.tmp && visudo -cf /etc/sudoers.d/trusty.tmp && mv /etc/sudoers.d/trusty.tmp /etc/sudoers.d/trusty";
    final osaArg =
        'do shell script "${inner.replaceAll('"', '\\"')}" with administrator privileges';

    final result = await Process.run('osascript', ['-e', osaArg]);

    if (result.exitCode != 0) {
      // User cancelled, wrong password, or sudoers validation failed.
      throw Exception('Administrator access is required to create a VPN tunnel.\nPlease try again and enter your Mac password when prompted.');
    }

    _addLog('✅ Setup complete. VPN tunnel access granted.');
  }

  /// Format log line based on log level
  String _formatLogLine(String line) {
    // Known-benign lines tagged ERROR upstream (Wintun's adapter probe)
    // must not get the red ❌ treatment.
    if (isBenignCliNoise(line)) {
      return 'ℹ️ $line';
    }
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

  /// Add log entry, collapsing consecutive lines that differ only in numbers.
  void _addLog(String message) {
    try {
      // Strip all digit sequences to produce a stable pattern.
      // e.g. "request id=14812 failed" and "request id=14813 failed" → same pattern.
      final pattern = message.replaceAll(RegExp(r'\d+'), '#');

      if (pattern == _lastMsgPattern && _logs.isNotEmpty) {
        // Same pattern as previous line — update the counter in-place.
        _dupCount++;
        final last = _logs.last;
        final base = last.contains(' (×') ? last.substring(0, last.lastIndexOf(' (×')) : last;
        _logs[_logs.length - 1] = '$base (×${_dupCount + 1})';
        _scheduleLogNotify();
        return;
      }

      _lastMsgPattern = pattern;
      _dupCount = 0;

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
      _connectedAt =
          newStatus == VpnStatus.connected ? DateTime.now() : null;
      _status = newStatus;
      notifyListeners();
    }
  }

  /// Graceful shutdown - call before app exit.
  /// Kills the client process and returns immediately. There is no Wintun
  /// release wait here: the OS frees the adapter as the process dies, and the
  /// next app launch is always far more than the release window away, so
  /// blocking app exit for it only makes quitting feel sluggish.
  Future<void> shutdown() async {
    final currentProcess = _process;
    if (currentProcess != null) {
      if (kDebugMode) {
        print('Shutdown: starting cleanup, PID: ${currentProcess.pid}');
      }
      _addLog('🔄 Shutting down...');

      // Kill hard — we are exiting and don't wait for the process to drain.
      try {
        currentProcess.kill(
          Platform.isWindows ? ProcessSignal.sigkill : ProcessSignal.sigterm,
        );
        if (kDebugMode) {
          print('Shutdown: sent kill signal');
        }
      } catch (e) {
        _addLog('⚠️ Error terminating process: $e');
        if (kDebugMode) {
          print('Shutdown: kill failed: $e');
        }
      }

      _process = null;
    }

    // Never leave the plaintext-password TOML behind after exit (a failed
    // connect may have written it even when no process is running).
    await _configService.deleteConfigFile();

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

/// Which arm of the connect() readiness race won.
enum _RaceOutcome { connected, exited, timeout }

/// Result of the connect() readiness race (see [VpnService.connect]).
/// Carries the exit code only when the process-exit arm won.
class _RaceResult {
  final _RaceOutcome kind;
  final int? exitCode;

  const _RaceResult._(this.kind, this.exitCode);

  static const _RaceResult connected = _RaceResult._(_RaceOutcome.connected, null);
  static const _RaceResult timeout = _RaceResult._(_RaceOutcome.timeout, null);
  factory _RaceResult.exited(int code) => _RaceResult._(_RaceOutcome.exited, code);
}

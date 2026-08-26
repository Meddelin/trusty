import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'models/vpn_status.dart';
import 'services/vpn_service.dart';
import 'services/config_service.dart';
import 'screens/home_screen.dart';
import 'screens/servers_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/split_tunnel_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/server_setup_screen.dart';
import 'services/server_setup_service.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'l10n/app_localizations.dart';
import 'utils/localization_helper.dart';

// Global reference to VPN service for cleanup on process termination
VpnService? _globalVpnService;

// Global lock file for single instance check
RandomAccessFile? _lockFile;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Check for single instance - only one app should run
  if (!await _ensureSingleInstance()) {
    debugPrint('Another instance is already running. Showing dialog...');

    // Initialize window manager to show error dialog
    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(400, 200),
      center: true,
      title: 'Trusty VPN',
      skipTaskbar: false,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });

    // Show error in a simple Flutter app
    runApp(const SingleInstanceErrorApp());

    // Exit after 5 seconds
    await Future.delayed(const Duration(seconds: 5));
    exit(0);
  }

  // Setup signal handlers for graceful shutdown
  _setupSignalHandlers();

  // Initialize window manager
  await windowManager.ensureInitialized();

  // Configure window
  const windowOptions = WindowOptions(
    // ponytail: opaque background on purpose. A transparent window background
    // makes the native title bar wash out the close/min/max glyphs on Windows
    // light theme (they become near-invisible). No custom window shape needs it.
    size: Size(950, 700),
    minimumSize: Size(850, 650),
    center: true,
    skipTaskbar: false,
    title: 'Trusty VPN',
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MyApp());
}

/// Setup signal handlers for graceful shutdown on process termination
void _setupSignalHandlers() {
  // Handle SIGINT (Ctrl+C) and SIGTERM (kill command)
  ProcessSignal.sigint.watch().listen((signal) async {
    debugPrint('Received SIGINT, cleaning up...');
    await _performGlobalCleanup();
    exit(0);
  });

  if (!Platform.isWindows) {
    // SIGTERM is not available on Windows
    ProcessSignal.sigterm.watch().listen((signal) async {
      debugPrint('Received SIGTERM, cleaning up...');
      await _performGlobalCleanup();
      exit(0);
    });
  }
}

/// Perform global cleanup when process is being terminated
Future<void> _performGlobalCleanup() async {
  if (_globalVpnService != null) {
    try {
      debugPrint('Shutting down VPN service...');
      await _globalVpnService!.shutdown();
      debugPrint('VPN service shut down successfully');
    } catch (e) {
      debugPrint('Error during global cleanup: $e');
    }
  }

  // Release lock file
  _releaseLock();
}

/// Ensure only one instance of the app is running
Future<bool> _ensureSingleInstance() async {
  try {
    // Get temp directory for lock file
    final tempDir = Directory.systemTemp;
    final lockFilePath = '${tempDir.path}/trusty.lock';
    final lockFile = File(lockFilePath);

    // Try to open the lock file exclusively
    try {
      _lockFile = await lockFile.open(mode: FileMode.write);

      // Try to lock the file (exclusive lock)
      await _lockFile!.lock(FileLock.exclusive);

      // Write PID to lock file
      await _lockFile!.writeString('$pid\n');
      await _lockFile!.flush();

      debugPrint('Single instance lock acquired: $lockFilePath (PID: $pid)');
      return true;
    } catch (e) {
      // Lock failed - another instance is running
      debugPrint('Failed to acquire lock: $e');

      // Try to read PID of running instance
      if (await lockFile.exists()) {
        try {
          final existingPid = await lockFile.readAsString();
          debugPrint('Existing instance PID: ${existingPid.trim()}');
        } catch (_) {}
      }

      return false;
    }
  } catch (e) {
    debugPrint('Error checking single instance: $e');
    // If we can't check, allow running (fail-open)
    return true;
  }
}

/// Release the lock file
void _releaseLock() {
  if (_lockFile != null) {
    try {
      _lockFile!.unlock();
      _lockFile!.closeSync();
      debugPrint('Lock file released');
    } catch (e) {
      debugPrint('Error releasing lock: $e');
    }
    _lockFile = null;
  }
}

/// Simple app to show single instance error
class SingleInstanceErrorApp extends StatelessWidget {
  const SingleInstanceErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trusty VPN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light(),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 64,
                  color: Colors.orange,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Trusty VPN is already running',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                const Text(
                  'The application is already open.\n'
                  'Check the system tray or taskbar.',
                  style: TextStyle(fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                const Text(
                  'This window will close in 5 seconds...',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ConfigService>(
          create: (_) => ConfigService(),
        ),
        ChangeNotifierProvider<VpnService>(
          create: (context) {
            final vpnService = VpnService(context.read<ConfigService>());
            // Register for global cleanup
            _globalVpnService = vpnService;
            return vpnService;
          },
        ),
        ChangeNotifierProvider<ServerSetupService>(
          create: (_) => ServerSetupService(),
        ),
        ChangeNotifierProvider<UpdateService>(
          create: (_) => UpdateService(),
        ),
      ],
      child: MaterialApp(
        title: 'Trusty VPN',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        builder: (context, child) {
          L10n.init(AppLocalizations.of(context)!);
          return child!;
        },
        home: const MainScreen(),
      ),
    );
  }

}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with TrayListener, WindowListener, WidgetsBindingObserver {
  int _selectedIndex = 0;

  // VPN service we listen to so the tray stays in sync with status changes
  // triggered from anywhere (e.g. the Home-screen Connect/Disconnect button),
  // not just from the tray menu itself.
  VpnService? _vpnService;
  bool? _lastConnected;

  @override
  void initState() {
    super.initState();
    _initSystemTray();
    trayManager.addListener(this);
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);

    // Keep the tray menu/tooltip in sync with VPN status changes that happen
    // outside the tray (listen:false read is safe in initState).
    _vpnService = context.read<VpnService>();
    _lastConnected = _vpnService!.status == VpnStatus.connected;
    _vpnService!.addListener(_onVpnStatusChanged);

    // Prevent closing window without cleanup
    windowManager.setPreventClose(true);

    // Background update check, delayed to keep startup snappy
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) context.read<UpdateService>().start();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _vpnService?.removeListener(_onVpnStatusChanged);
    super.dispose();
  }

  /// React to VPN status changes (from the Home screen, tray, or anywhere)
  /// and refresh the tray menu + tooltip so the labels never go stale.
  void _onVpnStatusChanged() {
    if (!mounted) return;

    final isConnected = _vpnService?.status == VpnStatus.connected;
    // Only do tray work when the connected-ness actually flipped.
    if (isConnected == _lastConnected) return;
    _lastConnected = isConnected;

    // Fire-and-forget: tray APIs are async but we don't need to await here.
    _updateTrayMenu();
    // Reflect status in the tooltip using only existing localized strings.
    trayManager.setToolTip(
      '${L10n.tr.trayTooltip} - '
      '${isConnected ? L10n.tr.vpnStatusConnected : L10n.tr.vpnStatusDisconnected}',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Handle app lifecycle changes
    if (state == AppLifecycleState.detached || state == AppLifecycleState.paused) {
      // App is being closed or paused
      _performCleanup(graceful: false);
    }
  }

  Future<void> _initSystemTray() async {
    String iconPath;

    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final exeDir = File(exePath).parent.path;
      iconPath = '$exeDir/data/flutter_assets/assets/tray_icon.ico';
    } else if (Platform.isMacOS) {
      // macOS: icon is inside .app bundle, use .png format
      final exePath = Platform.resolvedExecutable;
      final contentsDir = File(exePath).parent.parent.path;
      iconPath = '$contentsDir/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/tray_icon.png';
    } else {
      iconPath = 'assets/tray_icon.png';
    }

    try {
      await trayManager.setIcon(iconPath);
      debugPrint('Tray icon set successfully: $iconPath');
    } catch (e) {
      debugPrint('Failed to set tray icon: $e');
      debugPrint('Tried path: $iconPath');
    }

    // Setup tray menu
    await _updateTrayMenu();

    await trayManager.setToolTip(L10n.tr.trayTooltip);
  }

  /// Serializes the exit sequence (both the window-close and tray paths)
  /// and guards the close dialog against a repeated X-click stacking dialogs.
  bool _exiting = false;

  /// The one exit path. Cleanup is fast (a synchronous process kill), so the
  /// only thing that used to make quitting feel sluggish was awaiting
  /// windowManager.destroy() — a native platform-channel round-trip that can
  /// stall for seconds (or never complete, hanging the quit) before exit(0)
  /// is reached. exit(0) itself tears the process down and the OS reclaims
  /// the window, so the native teardown is given only a short bounded window
  /// (enough to remove the tray icon and avoid a lingering Windows ghost)
  /// and can never delay the quit.
  Future<void> _exitApp() async {
    if (_exiting) return;
    _exiting = true;
    await _performCleanup(graceful: true);
    await Future.any([
      windowManager.destroy(),
      Future.delayed(const Duration(milliseconds: 200)),
    ]);
    exit(0);
  }

  /// Perform cleanup before app exit
  /// [graceful] - if true, shows messages and waits properly; if false, does quick cleanup
  Future<void> _performCleanup({bool graceful = true}) async {
    try {
      final vpnService = context.read<VpnService>();

      if (vpnService.status.isActive) {
        if (graceful) {
          debugPrint('Graceful shutdown: disconnecting VPN...');
          await vpnService.shutdown();
        } else {
          debugPrint('Quick shutdown: killing VPN process...');
          // Force quick cleanup without waiting
          await vpnService.shutdown();
        }
      }
    } catch (e) {
      debugPrint('Error during cleanup: $e');
    }

    // Release single instance lock
    _releaseLock();
  }

  Future<void> _updateTrayMenu() async {
    final vpnService = context.read<VpnService>();
    final isConnected = vpnService.status == VpnStatus.connected;

    Menu menu = Menu(
      items: [
        MenuItem(
          key: 'show',
          label: L10n.tr.trayShowWindow,
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'connect',
          label: isConnected ? L10n.tr.trayDisconnect : L10n.tr.trayConnect,
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit',
          label: L10n.tr.trayExit,
        ),
      ],
    );

    await trayManager.setContextMenu(menu);
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        await windowManager.show();
        await windowManager.focus();
        break;
      case 'connect':
        final vpnService = context.read<VpnService>();
        final configService = context.read<ConfigService>();

        if (vpnService.status == VpnStatus.connected) {
          await vpnService.disconnect();
        } else if (vpnService.status == VpnStatus.disconnected ||
            vpnService.status == VpnStatus.error) {
          final config = await configService.loadConfig();
          if (config.isPlaceholder) {
            // Same guard as the Home button: never fake-connect to the
            // factory placeholder. Bring the window up so the user sees why.
            await windowManager.show();
            await windowManager.focus();
          } else {
            await vpnService.connect(config);
          }
        }
        await _updateTrayMenu();
        break;
      case 'exit':
        await _exitApp();
    }
  }

  /// True while onWindowClose is mid-flight (dialog open or exiting). With
  /// setPreventClose(true) the OS X button keeps re-firing the callback, so
  /// without this a second click would stack another dialog / race cleanup.
  bool _handlingClose = false;

  @override
  void onWindowClose() async {
    if (_handlingClose || _exiting) return;
    _handlingClose = true;
    try {
      await _handleWindowClose();
    } finally {
      // Cleared on every path that leaves the window open; the exit path
      // never returns here (exit(0) kills the process first).
      _handlingClose = false;
    }
  }

  Future<void> _handleWindowClose() async {
    final prefs = await SharedPreferences.getInstance();
    // Remembered close action: 'exit' or 'minimize'. Absent → ask each time.
    String? action = prefs.getString('close_action');

    if (action == null) {
      if (!mounted) return;
      bool remember = false;
      action = await showDialog<String>(
        context: context,
        barrierDismissible: true, // Allow dismissing by clicking outside
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(L10n.tr.dialogCloseTitle),
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Do you want to exit or minimize to tray?\n\n'
                    'If VPN is connected, it will be disconnected on exit.',
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: remember,
                    onChanged: (v) => setState(() => remember = v ?? false),
                    title: const Text('Remember my choice'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop('minimize'),
                child: Text(L10n.tr.dialogCloseMinimize),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop('exit'),
                child: Text(L10n.tr.dialogCloseExit),
              ),
            ],
          ),
        ),
      );

      // Dialog dismissed (clicked outside) → keep the window open.
      if (action == null) return;

      // Persist only if the user opted in.
      if (remember) {
        await prefs.setString('close_action', action);
      }
    }

    if (action == 'exit') {
      await _exitApp();
    } else {
      // minimize to tray
      await windowManager.hide();
    }
  }


  List<NavigationDestination> get _destinations => [
    NavigationDestination(
      icon: const Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: L10n.tr.navHome,
    ),
    NavigationDestination(
      icon: const Icon(Icons.dns_outlined),
      selectedIcon: Icon(Icons.dns),
      label: L10n.tr.navServers,
    ),
    NavigationDestination(
      icon: const Icon(Icons.call_split_outlined),
      selectedIcon: Icon(Icons.call_split),
      label: L10n.tr.navSplitTunnel,
    ),
    NavigationDestination(
      icon: const Icon(Icons.article_outlined),
      selectedIcon: Icon(Icons.article),
      label: L10n.tr.navLogs,
    ),
    NavigationDestination(
      icon: const Icon(Icons.rocket_launch_outlined),
      selectedIcon: Icon(Icons.rocket_launch),
      label: L10n.tr.navServer,
    ),
    NavigationDestination(
      icon: const Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: L10n.tr.navSettings,
    ),
  ];

  final List<Widget> _screens = const [
    HomeScreen(),
    ServersScreen(),
    SplitTunnelScreen(),
    LogsScreen(),
    ServerSetupScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Navigation Rail
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.all(16),
              child: Icon(
                Icons.vpn_lock,
                size: 40,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            destinations: _destinations.map((dest) {
              return NavigationRailDestination(
                icon: dest.icon,
                selectedIcon: dest.selectedIcon,
                label: Text(dest.label),
              );
            }).toList(),
          ),

          // Main content (the tonal rail color separates it; no hard divider)
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: _screens,
            ),
          ),
        ],
      ),
    );
  }
}

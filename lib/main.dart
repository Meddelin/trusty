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
import 'screens/split_tunnel_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/server_setup_screen.dart';
import 'services/server_setup_service.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'l10n/app_localizations.dart';
import 'utils/localization_helper.dart';
import 'utils/open_external.dart';
import 'widgets/app_switch.dart';
import 'widgets/github_mark.dart';
import 'widgets/telegram_mark.dart';

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
    // Opaque background on purpose. A transparent window background
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
      // This window used to be raw `ThemeData.light()` — Material's baseline
      // palette and type, in the one window a user only ever sees when
      // something went wrong. It is the same app, so it wears the same theme.
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const _SingleInstanceNotice(),
    );
  }
}

/// The body of [SingleInstanceErrorApp], split out so it can read the theme
/// it is being given.
class _SingleInstanceNotice extends StatelessWidget {
  const _SingleInstanceNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = theme.extension<StatusColors>()!;
    return Scaffold(
      body: Center(
        // The window is 400×200 and this text is not the app's to reflow: at
        // the old sizes (a 64px icon, a 20px title, 24px gaps) the column did
        // not fit and painted overflow stripes. The kit's sizes fit with room
        // to spare, and the scroll view keeps it true at any font or scale
        // factor rather than at the ones measured here.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Amber, not red: nothing failed — the app is running, just not
              // in this process. Red stays for errors (kit §5).
              Icon(
                Icons.warning_amber_rounded,
                size: 40,
                color: status.connecting,
              ),
              const SizedBox(height: 16),
              Text(
                'Trusty VPN is already running',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'The application is already open.\n'
                'Check the system tray or taskbar.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.4,
                  color: scheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              Text(
                'This window will close in 5 seconds...',
                style: TextStyle(fontSize: 11.5, color: dimTextOf(scheme)),
              ),
            ],
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
        ChangeNotifierProvider<ConfigService>(create: (_) => ConfigService()),
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
        ChangeNotifierProvider<UpdateService>(create: (_) => UpdateService()),
      ],
      child: MaterialApp(
        title: 'Trusty VPN',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(Brightness.light),
        darkTheme: buildAppTheme(Brightness.dark),
        themeMode: ThemeMode.system,
        // Following the OS between light and dark repaints every surface in
        // the window, so it moves like a surface: the app's duration and the
        // app's curve, not Material's 200ms linear default.
        themeAnimationDuration: kSurfaceChangeDuration,
        themeAnimationCurve: kMotionCurve,
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

    // The rail footer shows the running version, so read it now rather than
    // waiting for the delayed update check below.
    context.read<UpdateService>().loadCurrentVersion();

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
    if (state == AppLifecycleState.detached ||
        state == AppLifecycleState.paused) {
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
      iconPath =
          '$contentsDir/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/tray_icon.png';
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
        MenuItem(key: 'show', label: L10n.tr.trayShowWindow),
        MenuItem.separator(),
        MenuItem(
          key: 'connect',
          label: isConnected ? L10n.tr.trayDisconnect : L10n.tr.trayConnect,
        ),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: L10n.tr.trayExit),
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
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          return StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              // The kit's dialog: flat, radius 14, one hairline border. M3's
              // default is a radius-28 elevated surface with a tinted shadow,
              // which is the only thing in the app still casting one.
              backgroundColor: scheme.surfaceContainerLow,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(color: scheme.outline),
              ),
              titleTextStyle: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
              contentTextStyle: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
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
                    // `CheckboxListTile` was the last radial reaction in the
                    // app: a Material checkbox paints its own expanding circle
                    // from the toggle painter, so `splashFactory: NoSplash`
                    // never reaches it, and hovers as a 40px disc around an
                    // 18px box. The kit has exactly one boolean control.
                    _ToggleRow(
                      label: 'Remember my choice',
                      value: remember,
                      onChanged: (v) => setState(() => remember = v),
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
          );
        },
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
  ];

  /// One entry per destination, in the same order. The old Settings tab is
  /// gone: its three app-wide controls now live next to what they govern —
  /// the log level on Logs, the connection mode / SOCKS5 port and the
  /// window-close behaviour in the shared-settings card on Servers.
  final List<Widget> _screens = const [
    HomeScreen(),
    ServersScreen(),
    SplitTunnelScreen(),
    LogsScreen(),
    ServerSetupScreen(),
  ];

  /// The rail's own ink is the one overlay the theme cannot reach.
  /// `_RailDestination` hard-codes its hover as `colorScheme.primary` at 4%
  /// and its splash as `primary` at 12%, and `NavigationRailThemeData` has no
  /// `overlayColor` to state instead — so on hover the rail was the only
  /// control in the app tinting itself teal while everything else tints
  /// neutral. Inside the rail, and only inside it, `primary` is used for
  /// nothing but those two inks (the selected item takes `secondaryContainer`
  /// / `onSecondaryContainer`, the labels `onSurface`, the icons
  /// `onSurfaceVariant`), so pointing it at `onSurface` for this subtree buys
  /// the shared pointer language at no other cost.
  ///
  /// `highlightColor` comes back for the same reason: the app-wide value is
  /// transparent because every button states its press as `overlayColor`, and
  /// an `InkResponse` has no such property — without this, pressing a rail
  /// item would show nothing at all.
  ThemeData _railPointerTheme(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return theme.copyWith(
      colorScheme: scheme.copyWith(primary: scheme.onSurface),
      highlightColor: scheme.onSurface.withValues(alpha: 0.12),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Navigation Rail
          // The rail and its footer share one background so they read as a
          // single panel; NavigationRail's own `trailing` sits inside a
          // scroll view, which cannot pin anything to the bottom.
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Column(
              children: [
                Expanded(
                  child: Theme(
                    data: _railPointerTheme(context),
                    child: NavigationRail(
                      selectedIndex: _selectedIndex,
                      onDestinationSelected: (index) {
                        setState(() {
                          _selectedIndex = index;
                        });
                      },
                      labelType: NavigationRailLabelType.all,
                      leading: const Padding(
                        padding: EdgeInsets.all(16),
                        // The source icon is 1024x1024; decoding it whole would
                        // hold ~4 MB of RGBA for a 40px mark, so it is decoded
                        // at display size (headroom for a 3x display).
                        child: Image(
                          image: ResizeImage(
                            AssetImage('assets/icon.png'),
                            width: 120,
                            height: 120,
                          ),
                          width: 40,
                          height: 40,
                          filterQuality: FilterQuality.medium,
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
                  ),
                ),
                const RailFooter(),
              ],
            ),
          ),

          // Main content (the tonal rail color separates it; no hard divider)
          Expanded(
            child: IndexedStack(index: _selectedIndex, children: _screens),
          ),
        ],
      ),
    );
  }
}

/// The kit's toggle row: label on the left, [AppSwitch] on the right, the
/// whole row clickable.
///
/// The row answers the pointer with the app's own overlay — a flat tint at 5%
/// on hover and 12% while pressed, no circle travelling out from the cursor —
/// and deliberately does not take focus itself, so a keyboard lands on the
/// switch: one tab stop per boolean, with the focus ring drawn where the state
/// is. `MergeSemantics` folds the label, the toggle state and the tap into the
/// single node a screen reader should hear.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(10),
        overlayColor: pointerOverlay(scheme.onSurface),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 13, color: scheme.onSurface),
                ),
              ),
              const SizedBox(width: 12),
              AppSwitch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom of the navigation rail: what belongs to the application rather than
/// to a connection — how the window behaves when it is closed, a link to the
/// project, and the running build's version.
class RailFooter extends StatefulWidget {
  const RailFooter({super.key});

  @override
  State<RailFooter> createState() => _RailFooterState();
}

class _RailFooterState extends State<RailFooter> {
  static const _communityUrl = 'https://t.me/+JizbvklDJYg0Njg6';

  /// Absent means "ask each time"; `main.dart` reads the same key on close.
  String _closeAction = 'ask';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() => _closeAction = prefs.getString('close_action') ?? 'ask');
    });
  }

  Future<void> _setCloseAction(String value) async {
    setState(() => _closeAction = value);
    final prefs = await SharedPreferences.getInstance();
    if (value == 'ask') {
      await prefs.remove('close_action');
    } else {
      await prefs.setString('close_action', value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            tooltip: l10n.settingsCloseAction,
            position: PopupMenuPosition.over,
            icon: Icon(Icons.tune, size: 18, color: scheme.onSurfaceVariant),
            onSelected: _setCloseAction,
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                height: 32,
                child: Text(
                  l10n.settingsCloseAction,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (final option in [
                ('ask', l10n.settingsCloseActionAsk),
                ('minimize', l10n.settingsCloseActionMinimize),
                ('exit', l10n.settingsCloseActionExit),
              ])
                CheckedPopupMenuItem(
                  value: option.$1,
                  checked: _closeAction == option.$1,
                  child: Text(option.$2),
                ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () => context.read<UpdateService>().openRepository(),
                tooltip: 'Open the project on GitHub',
                icon: GitHubMark(size: 17, color: scheme.onSurfaceVariant),
              ),
              IconButton(
                onPressed: () => openExternal(_communityUrl),
                tooltip: 'Open the Telegram group',
                icon: TelegramMark(size: 17, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          Selector<UpdateService, String?>(
            selector: (_, updates) => updates.currentVersion,
            // The version arrives from an async read a moment after the rail
            // is already on screen, so it fades in rather than popping. The
            // box is the same 14px tall either way — nothing reflows.
            builder: (context, version, _) => SizedBox(
              height: 14,
              child: AnimatedOpacity(
                opacity: version == null ? 0 : 1,
                duration: kSurfaceChangeDuration,
                curve: kMotionCurve,
                child: Text(
                  version == null ? '' : 'v$version',
                  style: TextStyle(
                    fontFamily: kMonoFontStack.first,
                    fontFamilyFallback: kMonoFontStack.sublist(1),
                    fontSize: 10.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

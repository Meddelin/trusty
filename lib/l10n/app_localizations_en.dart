// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Trusty VPN';

  @override
  String get singleInstanceTitle => 'Trusty VPN is already running';

  @override
  String get singleInstanceMessage =>
      'The application is already open.\nCheck the system tray or taskbar.';

  @override
  String get singleInstanceClosing => 'This window will close in 5 seconds...';

  @override
  String get trayShowWindow => 'Show Window';

  @override
  String get trayConnect => 'Connect';

  @override
  String get trayDisconnect => 'Disconnect';

  @override
  String get trayExit => 'Exit';

  @override
  String get trayTooltip => 'Trusty VPN';

  @override
  String get dialogCloseTitle => 'Close Application?';

  @override
  String get dialogCloseMessage =>
      'Do you want to exit or minimize to tray?\n\nIf VPN is connected, it will be disconnected on exit.';

  @override
  String get dialogCloseMinimize => 'Minimize to Tray';

  @override
  String get dialogCloseExit => 'Exit';

  @override
  String get navHome => 'Home';

  @override
  String get navServers => 'Servers';

  @override
  String get navSettings => 'Settings';

  @override
  String get navSplitTunnel => 'Split Tunnel';

  @override
  String get navLogs => 'Logs';

  @override
  String get navServer => 'Deploy';

  @override
  String get vpnStatusDisconnected => 'Disconnected';

  @override
  String get vpnStatusConnecting => 'Connecting…';

  @override
  String get vpnStatusConnected => 'Connected';

  @override
  String get vpnStatusDisconnecting => 'Disconnecting...';

  @override
  String get vpnStatusError => 'Error';

  @override
  String get setupStepIdle => 'Ready to install';

  @override
  String get setupStepConnecting => 'Connecting via SSH...';

  @override
  String get setupStepCheckingSystem => 'Checking system...';

  @override
  String get setupStepInstalling => 'Installing Trusty...';

  @override
  String get setupStepConfiguringServer => 'Configuring server...';

  @override
  String get setupStepObtainingCertificate => 'Obtaining certificate...';

  @override
  String get setupStepStartingService => 'Starting service...';

  @override
  String get setupStepVerifying => 'Verifying...';

  @override
  String get setupStepCompleted => 'Installation complete';

  @override
  String get setupStepFailed => 'Installation failed';

  @override
  String get configErrorHostnameEmpty =>
      'Hostname is empty! Check server settings.';

  @override
  String get configErrorAddressEmpty =>
      'Address is empty! Check server settings.';

  @override
  String get configErrorUsernameEmpty =>
      'Username is empty! Check server settings.';

  @override
  String get homePleaseWait => 'Please wait...';

  @override
  String get homeDisconnect => 'Disconnect';

  @override
  String get homeConnect => 'Connect';

  @override
  String get homeInfoTitle => 'Information';

  @override
  String get homeInfoLine1 => 'Add your server on the Servers tab first';

  @override
  String get homeInfoLineClientWindows =>
      'trusttunnel_client.exe belongs in the client/ directory';

  @override
  String get homeInfoLineClientOther =>
      'trusttunnel_client belongs in the client/ directory';

  @override
  String get homeInfoLine3 =>
      'Connection logs are available in the \"Logs\" tab';

  @override
  String homeError(String error) {
    return 'Error: $error';
  }

  @override
  String get logsTitle => 'Connection Logs';

  @override
  String get logsAutoScrollEnabled => 'Auto-scroll enabled';

  @override
  String get logsAutoScrollDisabled => 'Auto-scroll disabled';

  @override
  String get logsCopy => 'Copy logs';

  @override
  String get logsClear => 'Clear logs';

  @override
  String logsTotalEntries(int count) {
    return '$count lines · this session only';
  }

  @override
  String get logsEmpty => 'No logs yet';

  @override
  String get logsConnectToSee => 'Connect to VPN to see logs';

  @override
  String get logsClearTitle => 'Clear logs?';

  @override
  String get logsClearMessage =>
      'All log entries will be deleted. This action cannot be undone.';

  @override
  String get logsCopied => 'Logs copied to clipboard';

  @override
  String get logsCleared => 'Logs cleared';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonClear => 'Clear';

  @override
  String get commonAdd => 'Add';

  @override
  String get commonSave => 'Save';

  @override
  String get commonRename => 'Rename';

  @override
  String get settingsServerName => 'Server name (optional)';

  @override
  String get settingsDnsHelper =>
      'One or more upstreams, separated by commas: a plain IP, tls://, https:// or quic://. Takes effect when you next connect.';

  @override
  String get settingsPrefixHelper =>
      'The exact hex prefix[/mask] from your server\'s rules.toml. Only servers that use connection filtering need one.';

  @override
  String get commonDelete => 'Delete';

  @override
  String get settingsWarningConnected =>
      'Server settings are locked while connected. Disconnect to edit.';

  @override
  String get settingsHostname => 'Hostname';

  @override
  String get settingsHostnameError => 'Enter hostname';

  @override
  String get settingsAddress => 'IP address';

  @override
  String get settingsAddressError => 'Enter IP address';

  @override
  String get settingsPort => 'Port';

  @override
  String get settingsPortErrorEmpty => 'Enter port';

  @override
  String get settingsPortErrorInvalid => 'Invalid port';

  @override
  String get settingsUsername => 'Username';

  @override
  String get settingsUsernameError => 'Enter username';

  @override
  String get settingsPassword => 'Password';

  @override
  String get settingsPasswordError => 'Enter password';

  @override
  String get settingsDns => 'DNS upstreams';

  @override
  String get settingsDnsError => 'Enter at least one upstream';

  @override
  String get settingsDnsPresetTooltip => 'Add a DNS preset';

  @override
  String get settingsDnsPresetDuplicate =>
      'This DNS server is already in the list';

  @override
  String get settingsProtocol => 'Protocol';

  @override
  String get settingsLogLevel => 'Log level';

  @override
  String get settingsLogLevelHelper =>
      'One level for every server. It takes effect when you next connect.';

  @override
  String get settingsConnectionMode => 'Connection mode';

  @override
  String get settingsConnectionModeTun => 'VPN (TUN)';

  @override
  String get settingsConnectionModeSocks => 'Proxy (SOCKS5)';

  @override
  String get settingsConnectionModeTunHint =>
      'Routes system traffic through a virtual network adapter, leaving addresses on your local network off the tunnel. Requires administrator rights.';

  @override
  String get settingsConnectionModeSocksHint =>
      'Runs a local proxy on 127.0.0.1 without creating a network adapter, so only the apps you point at it go through the tunnel. On Windows the app still starts with administrator rights.';

  @override
  String get settingsConnectionModeLocked =>
      'Disconnect to change the connection mode.';

  @override
  String get settingsSocksPort => 'SOCKS5 port';

  @override
  String get settingsSocksPortHelper =>
      'The proxy listens on 127.0.0.1 and nothing else. Reconnect for a change to take effect.';

  @override
  String get settingsSocksPortError => 'Enter a port between 1 and 65535';

  @override
  String get settingsCloseAction => 'On window close';

  @override
  String get settingsCloseActionHelper =>
      'Ask each time, minimize to the tray, or exit. This one takes effect straight away.';

  @override
  String get settingsCloseActionAsk => 'ask';

  @override
  String get settingsCloseActionMinimize => 'minimize';

  @override
  String get settingsCloseActionExit => 'exit';

  @override
  String get settingsAppSection => 'App settings';

  @override
  String get settingsAppSectionSubtitle => 'Shared by every server';

  @override
  String get settingsAppliesNextConnect => 'Applies on your next connect';

  @override
  String get settingsSectionAdvanced => 'Advanced';

  @override
  String get settingsIpv6 => 'IPv6 Support';

  @override
  String get settingsSkipVerification => 'Skip Certificate Verification';

  @override
  String get settingsAntiDpi => 'Anti-DPI';

  @override
  String get settingsPostQuantum => 'Post-Quantum Key Exchange';

  @override
  String get settingsPostQuantumHint =>
      'Hybrid key exchange that protects the TLS handshake against future quantum computers (harvest-now-decrypt-later). The handshake grows a little, which is why it stays on by default.';

  @override
  String get settingsCustomSni => 'Custom SNI (optional)';

  @override
  String get settingsSave => 'Save server';

  @override
  String get settingsSaved => 'Server saved';

  @override
  String settingsSaveError(String error) {
    return 'Save error: $error';
  }

  @override
  String get splitTunnelWarningConnected =>
      'Changes are saved now and take effect the next time you connect';

  @override
  String get splitTunnelSocksModeBanner =>
      'Proxy mode is active. Only apps you point at 127.0.0.1 go through the tunnel; these rules apply to the traffic that reaches the proxy.';

  @override
  String get splitTunnelVpnMode => 'Tunnel mode';

  @override
  String get splitTunnelModeGeneralTitle => 'General';

  @override
  String get splitTunnelModeGeneralSubtitle =>
      'Everything goes through the VPN except your list';

  @override
  String get splitTunnelModeGeneralSubtitleProxy =>
      'Everything goes through the proxy except your list';

  @override
  String get splitTunnelModeSelectiveTitle => 'Selective';

  @override
  String get splitTunnelModeSelectiveSubtitle =>
      'Only your list goes through the VPN';

  @override
  String get splitTunnelModeSelectiveSubtitleProxy =>
      'Only your list goes through the proxy';

  @override
  String get splitTunnelModeSameList =>
      'The same entries are exclusions in General mode, inclusions in Selective';

  @override
  String splitTunnelDomainsTab(int count) {
    return 'Domains ($count)';
  }

  @override
  String splitTunnelAppsTab(int count) {
    return 'Apps ($count)';
  }

  @override
  String get splitTunnelAutoSave =>
      'Saved as you go, and picked up by your next connection';

  @override
  String get splitTunnelDomainsExclude => 'Domains kept off the VPN';

  @override
  String get splitTunnelDomainsInclude => 'Domains sent through the VPN';

  @override
  String get splitTunnelDomainsHint =>
      'A domain, wildcard, IP, CIDR range or process name';

  @override
  String get splitTunnelDomainsInputHint => 'Enter domain, IP or CIDR';

  @override
  String get splitTunnelNoDomains => 'No domains added';

  @override
  String get splitTunnelOther => 'Other';

  @override
  String splitTunnelAddToGroup(String groupName) {
    return 'Add domain to \"$groupName\"';
  }

  @override
  String get splitTunnelEnterDomain => 'Enter domain';

  @override
  String get splitTunnelRenameGroup => 'Rename Group';

  @override
  String get splitTunnelGroupName => 'Group name';

  @override
  String get splitTunnelDeleteGroupTitle => 'Delete group?';

  @override
  String splitTunnelDeleteGroupMessage(String groupName) {
    return 'Group \"$groupName\" and all its domains will be deleted.';
  }

  @override
  String splitTunnelDomainCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count domains',
      one: '1 domain',
    );
    return '$_temp0';
  }

  @override
  String get splitTunnelSourcePreset => 'Preset';

  @override
  String get splitTunnelPresetPick => 'Ready-made list';

  @override
  String get splitTunnelPresetHint =>
      'Ready-made sets of domains and IP ranges from the v2fly community: domain categories (geosite) and per-country IP ranges (geoip). Domain rules are imported; regexp and keyword rules are skipped.';

  @override
  String splitTunnelExclusionLimitWarning(int count, int limit) {
    return 'Merging left $count domains and IP ranges, past the $limit the client handles comfortably. Connecting may take longer; switch a routing list off to bring it down.';
  }

  @override
  String get splitTunnelSuggestionTitle =>
      'Seen in the logs. Add to your list?';

  @override
  String get splitTunnelSuggestionAddToGroup => 'Add to group';

  @override
  String get splitTunnelSuggestionAddStandalone => 'Add standalone';

  @override
  String get splitTunnelSuggestionHide => 'Hide';

  @override
  String get splitTunnelDomainAlreadyAdded => 'This domain is already added';

  @override
  String splitTunnelSaveError(String error) {
    return 'Save error: $error';
  }

  @override
  String get splitTunnelAppsExclude => 'Apps kept off the VPN';

  @override
  String get splitTunnelAppsInclude => 'Apps sent through the VPN';

  @override
  String get splitTunnelAppsHint =>
      'Apps are matched by process name, like chrome.exe or Discord. If one is missing, start it and search again: running programs show the exact name.';

  @override
  String get splitTunnelSearchApps => 'Search apps...';

  @override
  String get splitTunnelNoApps =>
      'Couldn\'t list your apps. Press refresh, or type a process name and press +.';

  @override
  String splitTunnelSelectedApps(int count) {
    return 'Selected apps: $count';
  }

  @override
  String splitTunnelToGroup(String groupName) {
    return 'To \"$groupName\"';
  }

  @override
  String discoveryTitle(String domain) {
    return 'Add $domain';
  }

  @override
  String get discoverySearching => 'Searching for related domains...';

  @override
  String get discoveryRelatedFound => 'Related domains found:';

  @override
  String get discoveryGroupName => 'Group name';

  @override
  String get discoveryNoRelated => 'No related domains found.';

  @override
  String get discoveryAddStandalone => 'Domain will be added standalone.';

  @override
  String get discoveryWithoutGroup => 'Without group';

  @override
  String get discoveryAddGroup => 'Add group';

  @override
  String get serverInfoBanner =>
      'Installs and configures a TrustTunnel server on your VPS over SSH. You need Debian or Ubuntu on x86_64 or ARM64, root SSH access, and a domain already pointing at the machine.';

  @override
  String get serverSectionSsh => 'SSH Connection';

  @override
  String get serverVpsIp => 'VPS IP Address';

  @override
  String get serverVpsIpError => 'Enter IP address';

  @override
  String get serverSshPort => 'SSH Port';

  @override
  String get serverSshUser => 'Username';

  @override
  String get serverSshPassword => 'SSH Password';

  @override
  String get serverSshPasswordError => 'Enter password';

  @override
  String get serverSshKeyPath => 'SSH Key Path';

  @override
  String get serverSshKeyPathError => 'Enter key path';

  @override
  String get serverAuthPassword => 'Password';

  @override
  String get serverAuthKey => 'SSH Key';

  @override
  String get serverSectionDomain => 'Domain and Certificate';

  @override
  String get serverDomain => 'Domain';

  @override
  String get serverDomainError => 'Enter domain';

  @override
  String get serverDomainHint =>
      'Point this domain at your server\'s IP before you deploy, or the certificate step will fail.';

  @override
  String get serverEmail => 'Email (Let\'s Encrypt)';

  @override
  String get serverEmailError => 'Enter email';

  @override
  String get serverSectionVpnAccount => 'VPN Account';

  @override
  String get serverVpnUsername => 'VPN Username';

  @override
  String get serverVpnUsernameError => 'Enter username';

  @override
  String get serverVpnPassword => 'VPN Password';

  @override
  String get serverVpnPasswordError => 'Enter password';

  @override
  String get serverGeneratePassword => 'Generate password';

  @override
  String get serverSshSecretsHint =>
      'SSH details are used for this deployment only and are never saved';

  @override
  String get serverFilteringHint =>
      'The server answers only connections carrying this secret marker and ignores everything else. Apply fills it in for you.';

  @override
  String get serverFilteringWarning =>
      'Save it somewhere. Any device configured without this exact value gets ignored.';

  @override
  String get serverRestoredNote =>
      'These values were restored after a restart. Enter the VPN password again on the Servers tab.';

  @override
  String get serverInstallButton => 'Install Server';

  @override
  String get serverInstalling => 'Installing...';

  @override
  String get serverInstallLog => 'Installation Log';

  @override
  String get serverLogEmpty => 'Log is empty';

  @override
  String get serverInstalled => 'Server installed. The service started.';

  @override
  String serverSuccessInfo(String domain, String port, String username) {
    return 'Domain: $domain\nPort: $port\nVPN username: $username';
  }

  @override
  String get serverApplySettings => 'Add to my servers';

  @override
  String get serverApplyHint =>
      'Adds this server to your list, or updates the entry with the same domain, and makes it active. You connect from the main screen.';

  @override
  String get serverSettingsApplied => 'Server added and selected';

  @override
  String serverError(String error) {
    return 'Error: $error';
  }

  @override
  String homeUpdateAvailable(String version) {
    return 'New version available: v$version';
  }

  @override
  String get homeUpdateDownload => 'Download';

  @override
  String homeSocksProxy(String address) {
    return 'SOCKS5 proxy · $address';
  }
}

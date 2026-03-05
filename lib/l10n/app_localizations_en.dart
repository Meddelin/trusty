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
  String get navSettings => 'Settings';

  @override
  String get navSplitTunnel => 'Split Tunnel';

  @override
  String get navLogs => 'Logs';

  @override
  String get navServer => 'Server';

  @override
  String get vpnStatusDisconnected => 'Disconnected';

  @override
  String get vpnStatusConnecting => 'Connecting...';

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
  String get homeInfoLine1 =>
      'Configure server settings in the \"Settings\" tab';

  @override
  String get homeInfoLineClientWindows =>
      'Make sure trusttunnel_client.exe is in the client/ directory';

  @override
  String get homeInfoLineClientOther =>
      'Make sure trusttunnel_client is in the client/ directory';

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
    return 'Total entries: $count';
  }

  @override
  String get logsEmpty => 'Logs are empty';

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
  String get commonDelete => 'Delete';

  @override
  String get settingsWarningConnected =>
      'Disconnect from VPN before changing settings';

  @override
  String get settingsSectionServer => 'Server';

  @override
  String get settingsHostname => 'Hostname';

  @override
  String get settingsHostnameError => 'Enter hostname';

  @override
  String get settingsAddress => 'IP Address';

  @override
  String get settingsAddressError => 'Enter IP address';

  @override
  String get settingsPort => 'Port';

  @override
  String get settingsPortErrorEmpty => 'Enter port';

  @override
  String get settingsPortErrorInvalid => 'Invalid port';

  @override
  String get settingsSectionAuth => 'Authentication';

  @override
  String get settingsUsername => 'Username';

  @override
  String get settingsUsernameError => 'Enter username';

  @override
  String get settingsPassword => 'Password';

  @override
  String get settingsPasswordError => 'Enter password';

  @override
  String get settingsSectionNetwork => 'Network';

  @override
  String get settingsDns => 'DNS Server';

  @override
  String get settingsDnsError => 'Enter DNS server';

  @override
  String get settingsProtocol => 'Protocol';

  @override
  String get settingsLogLevel => 'Log Level';

  @override
  String get settingsSectionAdvanced => 'Advanced';

  @override
  String get settingsIpv6 => 'IPv6 Support';

  @override
  String get settingsSkipVerification => 'Skip Certificate Verification';

  @override
  String get settingsAntiDpi => 'Anti-DPI';

  @override
  String get settingsSave => 'Save Settings';

  @override
  String get settingsSaved => 'Settings saved';

  @override
  String settingsSaveError(String error) {
    return 'Save error: $error';
  }

  @override
  String get splitTunnelWarningConnected =>
      'Disconnect from VPN before changing settings';

  @override
  String get splitTunnelVpnMode => 'VPN Mode';

  @override
  String get splitTunnelModeGeneralTitle => 'All traffic through VPN';

  @override
  String get splitTunnelModeGeneralSubtitle =>
      'Exclusions will not go through VPN';

  @override
  String get splitTunnelModeSelectiveTitle =>
      'Only selected traffic through VPN';

  @override
  String get splitTunnelModeSelectiveSubtitle =>
      'Only specified domains/apps through VPN';

  @override
  String splitTunnelDomainsTab(int count) {
    return 'Domains ($count)';
  }

  @override
  String splitTunnelAppsTab(int count) {
    return 'Apps ($count)';
  }

  @override
  String get splitTunnelAutoSave => 'Settings are saved automatically';

  @override
  String get splitTunnelDomainsExclude =>
      'Domains that will NOT go through VPN:';

  @override
  String get splitTunnelDomainsInclude => 'Domains that WILL go through VPN:';

  @override
  String get splitTunnelDomainsHint =>
      'Domains (google.com), IPs (8.8.8.8), CIDR (10.0.0.0/8)';

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
  String get splitTunnelSuggestionTitle =>
      'Detected in logs — Add to exclusions?';

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
  String get splitTunnelAppsExclude => 'Apps that will NOT use VPN:';

  @override
  String get splitTunnelAppsInclude => 'Apps that WILL use VPN:';

  @override
  String get splitTunnelSearchApps => 'Search apps...';

  @override
  String get splitTunnelNoApps => 'No apps found';

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
      'TrustTunnel server installation on a remote VPS. Requires a VPS with Linux (Ubuntu/Debian), a domain name and SSH access (root).';

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
      'Domain must point to server IP (A record in DNS)';

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
  String get serverInstallButton => 'Install Server';

  @override
  String get serverInstalling => 'Installing...';

  @override
  String get serverInstallLog => 'Installation Log';

  @override
  String get serverLogEmpty => 'Log is empty';

  @override
  String get serverInstalled => 'Server installed and running!';

  @override
  String serverSuccessInfo(String domain, String port, String username) {
    return 'Domain: $domain\nPort: $port\nVPN username: $username';
  }

  @override
  String get serverApplySettings => 'Apply Client Settings';

  @override
  String get serverSettingsApplied => 'Client settings updated';

  @override
  String serverError(String error) {
    return 'Error: $error';
  }
}

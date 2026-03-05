import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Trusty VPN'**
  String get appTitle;

  /// No description provided for @singleInstanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Trusty VPN is already running'**
  String get singleInstanceTitle;

  /// No description provided for @singleInstanceMessage.
  ///
  /// In en, this message translates to:
  /// **'The application is already open.\nCheck the system tray or taskbar.'**
  String get singleInstanceMessage;

  /// No description provided for @singleInstanceClosing.
  ///
  /// In en, this message translates to:
  /// **'This window will close in 5 seconds...'**
  String get singleInstanceClosing;

  /// No description provided for @trayShowWindow.
  ///
  /// In en, this message translates to:
  /// **'Show Window'**
  String get trayShowWindow;

  /// No description provided for @trayConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get trayConnect;

  /// No description provided for @trayDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get trayDisconnect;

  /// No description provided for @trayExit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get trayExit;

  /// No description provided for @trayTooltip.
  ///
  /// In en, this message translates to:
  /// **'Trusty VPN'**
  String get trayTooltip;

  /// No description provided for @dialogCloseTitle.
  ///
  /// In en, this message translates to:
  /// **'Close Application?'**
  String get dialogCloseTitle;

  /// No description provided for @dialogCloseMessage.
  ///
  /// In en, this message translates to:
  /// **'Do you want to exit or minimize to tray?\n\nIf VPN is connected, it will be disconnected on exit.'**
  String get dialogCloseMessage;

  /// No description provided for @dialogCloseMinimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize to Tray'**
  String get dialogCloseMinimize;

  /// No description provided for @dialogCloseExit.
  ///
  /// In en, this message translates to:
  /// **'Exit'**
  String get dialogCloseExit;

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @navSplitTunnel.
  ///
  /// In en, this message translates to:
  /// **'Split Tunnel'**
  String get navSplitTunnel;

  /// No description provided for @navLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get navLogs;

  /// No description provided for @navServer.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get navServer;

  /// No description provided for @vpnStatusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get vpnStatusDisconnected;

  /// No description provided for @vpnStatusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get vpnStatusConnecting;

  /// No description provided for @vpnStatusConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get vpnStatusConnected;

  /// No description provided for @vpnStatusDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting...'**
  String get vpnStatusDisconnecting;

  /// No description provided for @vpnStatusError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get vpnStatusError;

  /// No description provided for @setupStepIdle.
  ///
  /// In en, this message translates to:
  /// **'Ready to install'**
  String get setupStepIdle;

  /// No description provided for @setupStepConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting via SSH...'**
  String get setupStepConnecting;

  /// No description provided for @setupStepCheckingSystem.
  ///
  /// In en, this message translates to:
  /// **'Checking system...'**
  String get setupStepCheckingSystem;

  /// No description provided for @setupStepInstalling.
  ///
  /// In en, this message translates to:
  /// **'Installing Trusty...'**
  String get setupStepInstalling;

  /// No description provided for @setupStepConfiguringServer.
  ///
  /// In en, this message translates to:
  /// **'Configuring server...'**
  String get setupStepConfiguringServer;

  /// No description provided for @setupStepObtainingCertificate.
  ///
  /// In en, this message translates to:
  /// **'Obtaining certificate...'**
  String get setupStepObtainingCertificate;

  /// No description provided for @setupStepStartingService.
  ///
  /// In en, this message translates to:
  /// **'Starting service...'**
  String get setupStepStartingService;

  /// No description provided for @setupStepVerifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying...'**
  String get setupStepVerifying;

  /// No description provided for @setupStepCompleted.
  ///
  /// In en, this message translates to:
  /// **'Installation complete'**
  String get setupStepCompleted;

  /// No description provided for @setupStepFailed.
  ///
  /// In en, this message translates to:
  /// **'Installation failed'**
  String get setupStepFailed;

  /// No description provided for @configErrorHostnameEmpty.
  ///
  /// In en, this message translates to:
  /// **'Hostname is empty! Check server settings.'**
  String get configErrorHostnameEmpty;

  /// No description provided for @configErrorAddressEmpty.
  ///
  /// In en, this message translates to:
  /// **'Address is empty! Check server settings.'**
  String get configErrorAddressEmpty;

  /// No description provided for @configErrorUsernameEmpty.
  ///
  /// In en, this message translates to:
  /// **'Username is empty! Check server settings.'**
  String get configErrorUsernameEmpty;

  /// No description provided for @homePleaseWait.
  ///
  /// In en, this message translates to:
  /// **'Please wait...'**
  String get homePleaseWait;

  /// No description provided for @homeDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get homeDisconnect;

  /// No description provided for @homeConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get homeConnect;

  /// No description provided for @homeInfoTitle.
  ///
  /// In en, this message translates to:
  /// **'Information'**
  String get homeInfoTitle;

  /// No description provided for @homeInfoLine1.
  ///
  /// In en, this message translates to:
  /// **'Configure server settings in the \"Settings\" tab'**
  String get homeInfoLine1;

  /// No description provided for @homeInfoLineClientWindows.
  ///
  /// In en, this message translates to:
  /// **'Make sure trusttunnel_client.exe is in the client/ directory'**
  String get homeInfoLineClientWindows;

  /// No description provided for @homeInfoLineClientOther.
  ///
  /// In en, this message translates to:
  /// **'Make sure trusttunnel_client is in the client/ directory'**
  String get homeInfoLineClientOther;

  /// No description provided for @homeInfoLine3.
  ///
  /// In en, this message translates to:
  /// **'Connection logs are available in the \"Logs\" tab'**
  String get homeInfoLine3;

  /// No description provided for @homeError.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String homeError(String error);

  /// No description provided for @logsTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection Logs'**
  String get logsTitle;

  /// No description provided for @logsAutoScrollEnabled.
  ///
  /// In en, this message translates to:
  /// **'Auto-scroll enabled'**
  String get logsAutoScrollEnabled;

  /// No description provided for @logsAutoScrollDisabled.
  ///
  /// In en, this message translates to:
  /// **'Auto-scroll disabled'**
  String get logsAutoScrollDisabled;

  /// No description provided for @logsCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy logs'**
  String get logsCopy;

  /// No description provided for @logsClear.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get logsClear;

  /// No description provided for @logsTotalEntries.
  ///
  /// In en, this message translates to:
  /// **'Total entries: {count}'**
  String logsTotalEntries(int count);

  /// No description provided for @logsEmpty.
  ///
  /// In en, this message translates to:
  /// **'Logs are empty'**
  String get logsEmpty;

  /// No description provided for @logsConnectToSee.
  ///
  /// In en, this message translates to:
  /// **'Connect to VPN to see logs'**
  String get logsConnectToSee;

  /// No description provided for @logsClearTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear logs?'**
  String get logsClearTitle;

  /// No description provided for @logsClearMessage.
  ///
  /// In en, this message translates to:
  /// **'All log entries will be deleted. This action cannot be undone.'**
  String get logsClearMessage;

  /// No description provided for @logsCopied.
  ///
  /// In en, this message translates to:
  /// **'Logs copied to clipboard'**
  String get logsCopied;

  /// No description provided for @logsCleared.
  ///
  /// In en, this message translates to:
  /// **'Logs cleared'**
  String get logsCleared;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get commonClear;

  /// No description provided for @commonAdd.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get commonAdd;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @settingsWarningConnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnect from VPN before changing settings'**
  String get settingsWarningConnected;

  /// No description provided for @settingsSectionServer.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get settingsSectionServer;

  /// No description provided for @settingsHostname.
  ///
  /// In en, this message translates to:
  /// **'Hostname'**
  String get settingsHostname;

  /// No description provided for @settingsHostnameError.
  ///
  /// In en, this message translates to:
  /// **'Enter hostname'**
  String get settingsHostnameError;

  /// No description provided for @settingsAddress.
  ///
  /// In en, this message translates to:
  /// **'IP Address'**
  String get settingsAddress;

  /// No description provided for @settingsAddressError.
  ///
  /// In en, this message translates to:
  /// **'Enter IP address'**
  String get settingsAddressError;

  /// No description provided for @settingsPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get settingsPort;

  /// No description provided for @settingsPortErrorEmpty.
  ///
  /// In en, this message translates to:
  /// **'Enter port'**
  String get settingsPortErrorEmpty;

  /// No description provided for @settingsPortErrorInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid port'**
  String get settingsPortErrorInvalid;

  /// No description provided for @settingsSectionAuth.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get settingsSectionAuth;

  /// No description provided for @settingsUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get settingsUsername;

  /// No description provided for @settingsUsernameError.
  ///
  /// In en, this message translates to:
  /// **'Enter username'**
  String get settingsUsernameError;

  /// No description provided for @settingsPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get settingsPassword;

  /// No description provided for @settingsPasswordError.
  ///
  /// In en, this message translates to:
  /// **'Enter password'**
  String get settingsPasswordError;

  /// No description provided for @settingsSectionNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get settingsSectionNetwork;

  /// No description provided for @settingsDns.
  ///
  /// In en, this message translates to:
  /// **'DNS Server'**
  String get settingsDns;

  /// No description provided for @settingsDnsError.
  ///
  /// In en, this message translates to:
  /// **'Enter DNS server'**
  String get settingsDnsError;

  /// No description provided for @settingsProtocol.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get settingsProtocol;

  /// No description provided for @settingsLogLevel.
  ///
  /// In en, this message translates to:
  /// **'Log Level'**
  String get settingsLogLevel;

  /// No description provided for @settingsSectionAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get settingsSectionAdvanced;

  /// No description provided for @settingsIpv6.
  ///
  /// In en, this message translates to:
  /// **'IPv6 Support'**
  String get settingsIpv6;

  /// No description provided for @settingsSkipVerification.
  ///
  /// In en, this message translates to:
  /// **'Skip Certificate Verification'**
  String get settingsSkipVerification;

  /// No description provided for @settingsAntiDpi.
  ///
  /// In en, this message translates to:
  /// **'Anti-DPI'**
  String get settingsAntiDpi;

  /// No description provided for @settingsSave.
  ///
  /// In en, this message translates to:
  /// **'Save Settings'**
  String get settingsSave;

  /// No description provided for @settingsSaved.
  ///
  /// In en, this message translates to:
  /// **'Settings saved'**
  String get settingsSaved;

  /// No description provided for @settingsSaveError.
  ///
  /// In en, this message translates to:
  /// **'Save error: {error}'**
  String settingsSaveError(String error);

  /// No description provided for @splitTunnelWarningConnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnect from VPN before changing settings'**
  String get splitTunnelWarningConnected;

  /// No description provided for @splitTunnelVpnMode.
  ///
  /// In en, this message translates to:
  /// **'VPN Mode'**
  String get splitTunnelVpnMode;

  /// No description provided for @splitTunnelModeGeneralTitle.
  ///
  /// In en, this message translates to:
  /// **'All traffic through VPN'**
  String get splitTunnelModeGeneralTitle;

  /// No description provided for @splitTunnelModeGeneralSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Exclusions will not go through VPN'**
  String get splitTunnelModeGeneralSubtitle;

  /// No description provided for @splitTunnelModeSelectiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Only selected traffic through VPN'**
  String get splitTunnelModeSelectiveTitle;

  /// No description provided for @splitTunnelModeSelectiveSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Only specified domains/apps through VPN'**
  String get splitTunnelModeSelectiveSubtitle;

  /// No description provided for @splitTunnelDomainsTab.
  ///
  /// In en, this message translates to:
  /// **'Domains ({count})'**
  String splitTunnelDomainsTab(int count);

  /// No description provided for @splitTunnelAppsTab.
  ///
  /// In en, this message translates to:
  /// **'Apps ({count})'**
  String splitTunnelAppsTab(int count);

  /// No description provided for @splitTunnelAutoSave.
  ///
  /// In en, this message translates to:
  /// **'Settings are saved automatically'**
  String get splitTunnelAutoSave;

  /// No description provided for @splitTunnelDomainsExclude.
  ///
  /// In en, this message translates to:
  /// **'Domains that will NOT go through VPN:'**
  String get splitTunnelDomainsExclude;

  /// No description provided for @splitTunnelDomainsInclude.
  ///
  /// In en, this message translates to:
  /// **'Domains that WILL go through VPN:'**
  String get splitTunnelDomainsInclude;

  /// No description provided for @splitTunnelDomainsHint.
  ///
  /// In en, this message translates to:
  /// **'Domains (google.com), IPs (8.8.8.8), CIDR (10.0.0.0/8)'**
  String get splitTunnelDomainsHint;

  /// No description provided for @splitTunnelDomainsInputHint.
  ///
  /// In en, this message translates to:
  /// **'Enter domain, IP or CIDR'**
  String get splitTunnelDomainsInputHint;

  /// No description provided for @splitTunnelNoDomains.
  ///
  /// In en, this message translates to:
  /// **'No domains added'**
  String get splitTunnelNoDomains;

  /// No description provided for @splitTunnelOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get splitTunnelOther;

  /// No description provided for @splitTunnelAddToGroup.
  ///
  /// In en, this message translates to:
  /// **'Add domain to \"{groupName}\"'**
  String splitTunnelAddToGroup(String groupName);

  /// No description provided for @splitTunnelEnterDomain.
  ///
  /// In en, this message translates to:
  /// **'Enter domain'**
  String get splitTunnelEnterDomain;

  /// No description provided for @splitTunnelRenameGroup.
  ///
  /// In en, this message translates to:
  /// **'Rename Group'**
  String get splitTunnelRenameGroup;

  /// No description provided for @splitTunnelGroupName.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get splitTunnelGroupName;

  /// No description provided for @splitTunnelDeleteGroupTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete group?'**
  String get splitTunnelDeleteGroupTitle;

  /// No description provided for @splitTunnelDeleteGroupMessage.
  ///
  /// In en, this message translates to:
  /// **'Group \"{groupName}\" and all its domains will be deleted.'**
  String splitTunnelDeleteGroupMessage(String groupName);

  /// No description provided for @splitTunnelDomainCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 domain} other{{count} domains}}'**
  String splitTunnelDomainCount(int count);

  /// No description provided for @splitTunnelSuggestionTitle.
  ///
  /// In en, this message translates to:
  /// **'Detected in logs — Add to exclusions?'**
  String get splitTunnelSuggestionTitle;

  /// No description provided for @splitTunnelSuggestionAddToGroup.
  ///
  /// In en, this message translates to:
  /// **'Add to group'**
  String get splitTunnelSuggestionAddToGroup;

  /// No description provided for @splitTunnelSuggestionAddStandalone.
  ///
  /// In en, this message translates to:
  /// **'Add standalone'**
  String get splitTunnelSuggestionAddStandalone;

  /// No description provided for @splitTunnelSuggestionHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get splitTunnelSuggestionHide;

  /// No description provided for @splitTunnelDomainAlreadyAdded.
  ///
  /// In en, this message translates to:
  /// **'This domain is already added'**
  String get splitTunnelDomainAlreadyAdded;

  /// No description provided for @splitTunnelSaveError.
  ///
  /// In en, this message translates to:
  /// **'Save error: {error}'**
  String splitTunnelSaveError(String error);

  /// No description provided for @splitTunnelAppsExclude.
  ///
  /// In en, this message translates to:
  /// **'Apps that will NOT use VPN:'**
  String get splitTunnelAppsExclude;

  /// No description provided for @splitTunnelAppsInclude.
  ///
  /// In en, this message translates to:
  /// **'Apps that WILL use VPN:'**
  String get splitTunnelAppsInclude;

  /// No description provided for @splitTunnelSearchApps.
  ///
  /// In en, this message translates to:
  /// **'Search apps...'**
  String get splitTunnelSearchApps;

  /// No description provided for @splitTunnelNoApps.
  ///
  /// In en, this message translates to:
  /// **'No apps found'**
  String get splitTunnelNoApps;

  /// No description provided for @splitTunnelSelectedApps.
  ///
  /// In en, this message translates to:
  /// **'Selected apps: {count}'**
  String splitTunnelSelectedApps(int count);

  /// No description provided for @splitTunnelToGroup.
  ///
  /// In en, this message translates to:
  /// **'To \"{groupName}\"'**
  String splitTunnelToGroup(String groupName);

  /// No description provided for @discoveryTitle.
  ///
  /// In en, this message translates to:
  /// **'Add {domain}'**
  String discoveryTitle(String domain);

  /// No description provided for @discoverySearching.
  ///
  /// In en, this message translates to:
  /// **'Searching for related domains...'**
  String get discoverySearching;

  /// No description provided for @discoveryRelatedFound.
  ///
  /// In en, this message translates to:
  /// **'Related domains found:'**
  String get discoveryRelatedFound;

  /// No description provided for @discoveryGroupName.
  ///
  /// In en, this message translates to:
  /// **'Group name'**
  String get discoveryGroupName;

  /// No description provided for @discoveryNoRelated.
  ///
  /// In en, this message translates to:
  /// **'No related domains found.'**
  String get discoveryNoRelated;

  /// No description provided for @discoveryAddStandalone.
  ///
  /// In en, this message translates to:
  /// **'Domain will be added standalone.'**
  String get discoveryAddStandalone;

  /// No description provided for @discoveryWithoutGroup.
  ///
  /// In en, this message translates to:
  /// **'Without group'**
  String get discoveryWithoutGroup;

  /// No description provided for @discoveryAddGroup.
  ///
  /// In en, this message translates to:
  /// **'Add group'**
  String get discoveryAddGroup;

  /// No description provided for @serverInfoBanner.
  ///
  /// In en, this message translates to:
  /// **'TrustTunnel server installation on a remote VPS. Requires a VPS with Linux (Ubuntu/Debian), a domain name and SSH access (root).'**
  String get serverInfoBanner;

  /// No description provided for @serverSectionSsh.
  ///
  /// In en, this message translates to:
  /// **'SSH Connection'**
  String get serverSectionSsh;

  /// No description provided for @serverVpsIp.
  ///
  /// In en, this message translates to:
  /// **'VPS IP Address'**
  String get serverVpsIp;

  /// No description provided for @serverVpsIpError.
  ///
  /// In en, this message translates to:
  /// **'Enter IP address'**
  String get serverVpsIpError;

  /// No description provided for @serverSshPort.
  ///
  /// In en, this message translates to:
  /// **'SSH Port'**
  String get serverSshPort;

  /// No description provided for @serverSshUser.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get serverSshUser;

  /// No description provided for @serverSshPassword.
  ///
  /// In en, this message translates to:
  /// **'SSH Password'**
  String get serverSshPassword;

  /// No description provided for @serverSshPasswordError.
  ///
  /// In en, this message translates to:
  /// **'Enter password'**
  String get serverSshPasswordError;

  /// No description provided for @serverSshKeyPath.
  ///
  /// In en, this message translates to:
  /// **'SSH Key Path'**
  String get serverSshKeyPath;

  /// No description provided for @serverSshKeyPathError.
  ///
  /// In en, this message translates to:
  /// **'Enter key path'**
  String get serverSshKeyPathError;

  /// No description provided for @serverAuthPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get serverAuthPassword;

  /// No description provided for @serverAuthKey.
  ///
  /// In en, this message translates to:
  /// **'SSH Key'**
  String get serverAuthKey;

  /// No description provided for @serverSectionDomain.
  ///
  /// In en, this message translates to:
  /// **'Domain and Certificate'**
  String get serverSectionDomain;

  /// No description provided for @serverDomain.
  ///
  /// In en, this message translates to:
  /// **'Domain'**
  String get serverDomain;

  /// No description provided for @serverDomainError.
  ///
  /// In en, this message translates to:
  /// **'Enter domain'**
  String get serverDomainError;

  /// No description provided for @serverDomainHint.
  ///
  /// In en, this message translates to:
  /// **'Domain must point to server IP (A record in DNS)'**
  String get serverDomainHint;

  /// No description provided for @serverEmail.
  ///
  /// In en, this message translates to:
  /// **'Email (Let\'s Encrypt)'**
  String get serverEmail;

  /// No description provided for @serverEmailError.
  ///
  /// In en, this message translates to:
  /// **'Enter email'**
  String get serverEmailError;

  /// No description provided for @serverSectionVpnAccount.
  ///
  /// In en, this message translates to:
  /// **'VPN Account'**
  String get serverSectionVpnAccount;

  /// No description provided for @serverVpnUsername.
  ///
  /// In en, this message translates to:
  /// **'VPN Username'**
  String get serverVpnUsername;

  /// No description provided for @serverVpnUsernameError.
  ///
  /// In en, this message translates to:
  /// **'Enter username'**
  String get serverVpnUsernameError;

  /// No description provided for @serverVpnPassword.
  ///
  /// In en, this message translates to:
  /// **'VPN Password'**
  String get serverVpnPassword;

  /// No description provided for @serverVpnPasswordError.
  ///
  /// In en, this message translates to:
  /// **'Enter password'**
  String get serverVpnPasswordError;

  /// No description provided for @serverGeneratePassword.
  ///
  /// In en, this message translates to:
  /// **'Generate password'**
  String get serverGeneratePassword;

  /// No description provided for @serverInstallButton.
  ///
  /// In en, this message translates to:
  /// **'Install Server'**
  String get serverInstallButton;

  /// No description provided for @serverInstalling.
  ///
  /// In en, this message translates to:
  /// **'Installing...'**
  String get serverInstalling;

  /// No description provided for @serverInstallLog.
  ///
  /// In en, this message translates to:
  /// **'Installation Log'**
  String get serverInstallLog;

  /// No description provided for @serverLogEmpty.
  ///
  /// In en, this message translates to:
  /// **'Log is empty'**
  String get serverLogEmpty;

  /// No description provided for @serverInstalled.
  ///
  /// In en, this message translates to:
  /// **'Server installed and running!'**
  String get serverInstalled;

  /// No description provided for @serverSuccessInfo.
  ///
  /// In en, this message translates to:
  /// **'Domain: {domain}\nPort: {port}\nVPN username: {username}'**
  String serverSuccessInfo(String domain, String port, String username);

  /// No description provided for @serverApplySettings.
  ///
  /// In en, this message translates to:
  /// **'Apply Client Settings'**
  String get serverApplySettings;

  /// No description provided for @serverSettingsApplied.
  ///
  /// In en, this message translates to:
  /// **'Client settings updated'**
  String get serverSettingsApplied;

  /// No description provided for @serverError.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String serverError(String error);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}

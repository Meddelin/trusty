import '../l10n/app_localizations.dart';

/// Global helper for accessing localizations without BuildContext.
/// Used by models, services, and system tray that lack BuildContext.
class L10n {
  static AppLocalizations? _instance;

  /// Initialize with the app's localizations (called from MaterialApp.builder)
  static void init(AppLocalizations localizations) {
    _instance = localizations;
  }

  /// Get current localizations instance
  static AppLocalizations get tr {
    if (_instance == null) {
      throw StateError('L10n not initialized. Call L10n.init() first.');
    }
    return _instance!;
  }
}

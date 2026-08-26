import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Checks GitHub Releases for a newer version and lets the user open the
/// release page in a browser. Notify-only: no download/install.
class UpdateService extends ChangeNotifier {
  static const _latestReleaseApi =
      'https://api.github.com/repos/Meddelin/trusty/releases/latest';
  static const _releasesPage = 'https://github.com/Meddelin/trusty/releases/latest';
  static const _timeout = Duration(seconds: 15);

  String? _latestVersion;
  String? _releaseUrl;
  bool _dismissed = false;
  Timer? _recheckTimer;

  String? get latestVersion => _latestVersion;
  bool get updateAvailable => _latestVersion != null && !_dismissed;

  /// Check now and re-check daily (the app lives in the tray for weeks).
  void start() {
    checkForUpdate();
    _recheckTimer ??= Timer.periodic(
      const Duration(hours: 24),
      (_) => checkForUpdate(),
    );
  }

  Future<void> checkForUpdate() async {
    try {
      final current = (await PackageInfo.fromPlatform()).version;
      final client = HttpClient()..connectionTimeout = _timeout;
      try {
        final request =
            await client.getUrl(Uri.parse(_latestReleaseApi)).timeout(_timeout);
        request.headers.set('User-Agent', 'Trusty');
        request.headers.set('Accept', 'application/vnd.github+json');
        final response = await request.close().timeout(_timeout);
        if (response.statusCode != 200) {
          await response.drain<void>();
          return;
        }
        final body = await response.transform(utf8.decoder).join();
        final release = jsonDecode(body) as Map<String, dynamic>;
        final tag = release['tag_name'] as String? ?? '';
        final version = tag.startsWith('v') ? tag.substring(1) : tag;
        if (isNewerVersion(version, current)) {
          _latestVersion = version;
          _releaseUrl = release['html_url'] as String? ?? _releasesPage;
          // A dismissed version stays dismissed across restarts; a NEWER
          // release shows the banner again.
          final prefs = await SharedPreferences.getInstance();
          _dismissed =
              prefs.getString(_dismissedVersionKey) == version;
          notifyListeners();
        }
      } finally {
        client.close();
      }
    } catch (_) {
      // ponytail: check failures (offline, rate limit) are silent — the
      // banner simply doesn't appear; next check is in 24h.
    }
  }

  static const _dismissedVersionKey = 'update_dismissed_version';

  void dismiss() {
    _dismissed = true;
    notifyListeners();
    // Fire-and-forget persistence — the banner must not reappear next launch.
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString(_dismissedVersionKey, _latestVersion ?? ''),
    );
  }

  Future<void> openReleasePage() async {
    final url = _releaseUrl ?? _releasesPage;
    if (Platform.isWindows) {
      // explorer hands the URL to the default browser without inheriting
      // this process's admin token.
      await Process.run('explorer.exe', [url]);
    } else {
      await Process.run('open', [url]);
    }
  }

  @override
  void dispose() {
    _recheckTimer?.cancel();
    super.dispose();
  }
}

/// True if [candidate] is a strictly newer x.y.z version than [current].
/// Build metadata (+n) and pre-release suffixes (-rc1) are ignored.
@visibleForTesting
bool isNewerVersion(String candidate, String current) {
  List<int> parse(String v) => v
      .split('+')
      .first
      .split('-')
      .first
      .split('.')
      .map((p) => int.tryParse(p) ?? 0)
      .toList();
  final a = parse(candidate);
  final b = parse(current);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

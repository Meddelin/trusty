import 'dart:io';

/// Opens a URL in the user's browser.
///
/// On Windows the app runs elevated, and handing the URL straight to the
/// default browser would launch it with this process's administrator token.
/// `explorer.exe` performs the hand-off at the shell's own integrity level,
/// so the browser starts unprivileged.
Future<void> openExternal(String url) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', [url]);
  } else {
    await Process.run('open', [url]);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum SnackKind { info, success, warning, error }

/// One snackbar helper with fixed conventions instead of ad-hoc colors and
/// durations at every call site: success/info 3s, warning 4s, error 6s.
/// Errors get an automatic Copy action (raw messages are report material)
/// unless the caller supplies its own action. Always replaces the current
/// snackbar so messages never queue up.
void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackKind kind = SnackKind.info,
  SnackBarAction? action,
  Duration? duration,
}) {
  final scheme = Theme.of(context).colorScheme;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();

  final (Color? bg, Color? fg, IconData? icon, int seconds) = switch (kind) {
    SnackKind.info => (null, null, null, 3),
    SnackKind.success => (null, null, Icons.check_circle_outline, 3),
    SnackKind.warning => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        Icons.warning_amber,
        4,
      ),
    SnackKind.error => (scheme.error, scheme.onError, Icons.error_outline, 6),
  };

  final effectiveAction = action ??
      (kind == SnackKind.error
          ? SnackBarAction(
              label: 'Copy',
              textColor: fg,
              onPressed: () => Clipboard.setData(ClipboardData(text: message)),
            )
          : null);

  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      width: 480,
      backgroundColor: bg,
      duration: duration ?? Duration(seconds: seconds),
      action: effectiveAction,
      content: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: fg ?? scheme.inversePrimary),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(message, style: fg != null ? TextStyle(color: fg) : null),
          ),
        ],
      ),
    ),
  );
}

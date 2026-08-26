import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum BannerSeverity { info, warning, error }

/// Unified inline banner — one visual language for every informational strip
/// in the app, themed via ColorScheme so contrast holds in both light and
/// dark mode (replaces the hand-rolled Colors.blue/orange/red containers).
///
/// With [dismissKey] set, the banner shows an X and, once dismissed, stays
/// hidden forever (persisted in SharedPreferences). [onDismiss] alone shows
/// an X and delegates state to the caller (e.g. the update banner, whose
/// dismissal is versioned by UpdateService).
class InfoBanner extends StatefulWidget {
  final BannerSeverity severity;
  final String message;

  /// Optional bold first line above [message].
  final String? title;
  final List<Widget> actions;
  final String? dismissKey;
  final VoidCallback? onDismiss;
  final EdgeInsetsGeometry margin;

  const InfoBanner({
    super.key,
    this.severity = BannerSeverity.info,
    required this.message,
    this.title,
    this.actions = const [],
    this.dismissKey,
    this.onDismiss,
    this.margin = EdgeInsets.zero,
  });

  @override
  State<InfoBanner> createState() => _InfoBannerState();
}

class _InfoBannerState extends State<InfoBanner> {
  // null while the dismissal pref is loading (renders nothing — banners are
  // secondary chrome, a one-frame delay is invisible).
  bool? _visible;

  String get _prefKey => 'banner_dismissed_${widget.dismissKey}';

  @override
  void initState() {
    super.initState();
    _initVisibility();
  }

  @override
  void didUpdateWidget(covariant InfoBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keyless reconciliation can reuse this State for a DIFFERENT banner
    // (e.g. the dismissed intro banner's slot taken by the error banner) —
    // re-resolve visibility whenever the identity changes.
    if (oldWidget.dismissKey != widget.dismissKey) _initVisibility();
  }

  void _initVisibility() {
    if (widget.dismissKey == null) {
      _visible = true;
    } else {
      _visible = null;
      SharedPreferences.getInstance().then((prefs) {
        if (mounted) {
          setState(() => _visible = !(prefs.getBool(_prefKey) ?? false));
        }
      });
    }
  }

  void _dismiss() {
    setState(() => _visible = false);
    if (widget.dismissKey != null) {
      SharedPreferences.getInstance().then((p) => p.setBool(_prefKey, true));
    }
    widget.onDismiss?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_visible != true) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final (Color bg, Color fg, IconData icon) = switch (widget.severity) {
      BannerSeverity.info => (
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
          Icons.info_outline,
        ),
      BannerSeverity.warning => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
          Icons.warning_amber,
        ),
      BannerSeverity.error => (
          scheme.errorContainer,
          scheme.onErrorContainer,
          Icons.error_outline,
        ),
    };

    final dismissible = widget.dismissKey != null || widget.onDismiss != null;

    return Container(
      margin: widget.margin,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 18, color: fg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.title != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      widget.title!,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                Text(
                  widget.message,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: fg),
                ),
              ],
            ),
          ),
          ...widget.actions,
          if (dismissible)
            IconButton(
              icon: Icon(Icons.close, size: 16, color: fg),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: 'Dismiss',
              onPressed: _dismiss,
            ),
        ],
      ),
    );
  }
}

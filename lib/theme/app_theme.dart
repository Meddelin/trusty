import 'package:flutter/material.dart';

/// Semantic status colors — the ONLY source of connected/connecting/error
/// accents. Muted pairs tuned per brightness; raw Material-500 constants
/// (Colors.green/red/orange) must not be used for status anywhere.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  final Color connected;
  final Color connecting;
  final Color error;
  final Color idle;

  const StatusColors({
    required this.connected,
    required this.connecting,
    required this.error,
    required this.idle,
  });

  static const light = StatusColors(
    connected: Color(0xFF2E7D32),
    connecting: Color(0xFFB26A00),
    error: Color(0xFFBA1A1A),
    idle: Color(0xFF72777F),
  );

  static const dark = StatusColors(
    connected: Color(0xFF81C784),
    connecting: Color(0xFFFFB74D),
    error: Color(0xFFFFB4AB),
    idle: Color(0xFF8C9199),
  );

  @override
  StatusColors copyWith({
    Color? connected,
    Color? connecting,
    Color? error,
    Color? idle,
  }) {
    return StatusColors(
      connected: connected ?? this.connected,
      connecting: connecting ?? this.connecting,
      error: error ?? this.error,
      idle: idle ?? this.idle,
    );
  }

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      connected: Color.lerp(connected, other.connected, t)!,
      connecting: Color.lerp(connecting, other.connecting, t)!,
      error: Color.lerp(error, other.error, t)!,
      idle: Color.lerp(idle, other.idle, t)!,
    );
  }
}

/// One theme builder for both brightnesses: desaturated steel-blue seed
/// ("calm technical tool" — not the stock Flutter blue), flat tonal cards
/// with hairline outlines instead of shadows, tonal navigation rail,
/// floating snackbars.
ThemeData buildAppTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3D5A80),
    brightness: brightness,
  );
  final status =
      brightness == Brightness.light ? StatusColors.light : StatusColors.dark;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: [status],
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
    ),
    // One input language everywhere: subtle fill, hairline outline, calm
    // 1.5px primary focus ring, no hover fill. The state-specific borders
    // here override any per-field plain `border:` declaration, so every
    // field focuses identically.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.22),
      hoverColor: Colors.transparent,
      helperMaxLines: 3,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
    ),
  );
}

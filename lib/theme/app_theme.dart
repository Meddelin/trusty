import 'package:flutter/material.dart';

/// Semantic status colors — the ONLY source of connected/connecting/error
/// accents. Muted pairs tuned per brightness; raw Material-500 constants
/// (Colors.green/red/orange) must not be used for status anywhere.
///
/// The values are sampled from the app icon (assets/icon.png): a keyhole onto a
/// teal starfield above violet mountains. Connected is the sky, connecting the
/// warm horizon, error the lit ridge, idle the mountain body.
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
    connected: Color(0xFF117668),
    connecting: Color(0xFF8A6027),
    error: Color(0xFFB83D4C),
    idle: Color(0xFF686681),
  );

  static const dark = StatusColors(
    connected: Color(0xFF41BFAE),
    connecting: Color(0xFFD9A96B),
    error: Color(0xFFE2707C),
    idle: Color(0xFF8986A2),
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

/// Monospaced style for values the user reads as data rather than prose:
/// hostnames, addresses, ports, prefixes, entry counts, the connection timer
/// and log output. Chivo Mono carries Latin; JetBrains Mono sits behind it for
/// Cyrillic (a routing list may hold `кино.рф`) at the same advance width, so
/// swapping scripts never reflows a column. Both fall back to whatever the OS
/// offers until the font assets are bundled — see design-concepts/THEME.md.
const List<String> kMonoFontStack = [
  'ChivoMono',
  'JetBrainsMono',
  'Consolas',
  'monospace',
];

/// The quietest text tone: mono section labels, captions, placeholders and
/// log timestamps. It is deliberately NOT `colorScheme.outline` — that is a
/// border colour and lands around 1.6:1 against the card surfaces, i.e. text
/// nobody can read — and not `onSurfaceVariant` either, so the design keeps
/// three distinct text tones. Both values clear the WCAG AA 4.5:1 floor on
/// every surface in this palette; `test/ui/a11y_test.dart` enforces that.
Color dimTextOf(ColorScheme scheme) => scheme.brightness == Brightness.dark
    ? const Color(0xFF8389A0)
    : const Color(0xFF62687B);

/// The UI face. Bundle the assets to get it; without them Flutter falls back to
/// the platform default and every measurement below still holds.
const String kUiFont = 'Geologica';

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

/// A control answering the pointer or a boolean: a hover tint arriving, a
/// switch thumb sliding, an icon swapping. Short enough that the UI reads as
/// already-responded rather than as animating.
const Duration kStateChangeDuration = Duration(milliseconds: 120);

/// A surface changing: a panel expanding, a banner appearing, a list reflowing,
/// a size settling. Long enough to be followed, short enough not to be waited
/// on.
const Duration kSurfaceChangeDuration = Duration(milliseconds: 220);

/// The curve for both. `easeOut` leaves immediately and settles at the end,
/// which is what a pointer-driven UI should feel like.
///
/// Deliberately NOT `Curves.fastOutSlowIn` — that is Material's signature ease,
/// and its slow-in tail reads as a phone animation on a desktop window.
///
/// These three exist because nothing in the app declared a duration or a curve,
/// so every `AnimatedContainer`, `AnimatedSwitcher` and `AnimatedSize` fell
/// back to the framework's defaults. Two durations and one curve is the whole
/// vocabulary; anything that wants a fourth value probably wants one of these.
const Curve kMotionCurve = Curves.easeOut;

// ---------------------------------------------------------------------------
// Pointer states
// ---------------------------------------------------------------------------

/// Width of the one focus indicator in the app — the ring the input fields
/// draw on focus, reused on every button, the segmented control and
/// `AppSwitch`, so keyboard focus looks the same wherever it lands.
const double kFocusRingWidth = 1.5;

// A desktop control answers the pointer with a flat tint, not with a circle
// expanding from wherever the cursor happened to be. Three strengths of one
// colour: hover, focus (which also gets the ring) and press.
const double _kHoverAlpha = 0.05;
const double _kFocusAlpha = 0.08;
const double _kPressAlpha = 0.12;

/// The overlay every interactive component in the app shares: [tint] at 5% on
/// hover, 8% on focus, 12% while pressed, nothing at rest.
///
/// Pass the colour that contrasts with the control's own ground — normally
/// `colorScheme.onSurface`. Exported so a hand-rolled `InkWell` or
/// `FocusableActionDetector` on a screen can answer the pointer exactly like a
/// themed button does.
WidgetStateProperty<Color?> pointerOverlay(Color tint) {
  return WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.pressed)) {
      return tint.withValues(alpha: _kPressAlpha);
    }
    if (states.contains(WidgetState.focused)) {
      return tint.withValues(alpha: _kFocusAlpha);
    }
    if (states.contains(WidgetState.hovered)) {
      return tint.withValues(alpha: _kHoverAlpha);
    }
    return null;
  });
}

/// The focus ring as a button `side`: [ringColor] at [kFocusRingWidth] while
/// focused, [resting] otherwise (null for controls that carry no border at
/// rest, the outline for the ones that do).
WidgetStateProperty<BorderSide?> focusRingSide(
  Color ringColor, {
  BorderSide? resting,
}) {
  return WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.focused)) {
      return BorderSide(color: ringColor, width: kFocusRingWidth);
    }
    return resting;
  });
}

/// One theme builder for both brightnesses. The seed is the icon's sky teal,
/// but the surface family is pinned rather than generated: the icon's night is
/// blue-violet, which a teal seed would never produce on its own. Flat tonal
/// cards with hairline outlines instead of shadows, tonal navigation rail,
/// floating snackbars.
ThemeData buildAppTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(
    seedColor: const Color(0xFF33A9A2),
    brightness: brightness,
  );

  final scheme = isDark
      ? base.copyWith(
          primary: const Color(0xFF41BFAE),
          onPrimary: const Color(0xFF0A0D18),
          secondaryContainer: const Color(0xFF1C2236),
          onSecondaryContainer: const Color(0xFFE3E6F2),
          surface: const Color(0xFF0A0D18),
          surfaceContainerLowest: const Color(0xFF0D1120),
          surfaceContainerLow: const Color(0xFF151A2B),
          surfaceContainer: const Color(0xFF0F1322),
          surfaceContainerHigh: const Color(0xFF1C2236),
          surfaceContainerHighest: const Color(0xFF232941),
          onSurface: const Color(0xFFE3E6F2),
          onSurfaceVariant: const Color(0xFF8F97B2),
          outline: const Color(0xFF31384F),
          outlineVariant: const Color(0xFF232941),
          error: const Color(0xFFE2707C),
          onError: const Color(0xFF0A0D18),
          errorContainer: const Color(0xFF3A2028),
          onErrorContainer: const Color(0xFFF3C9CE),
          tertiaryContainer: const Color(0xFF3A2E1E),
          onTertiaryContainer: const Color(0xFFF0DCC0),
        )
      : base.copyWith(
          primary: const Color(0xFF117668),
          onPrimary: const Color(0xFFFFFFFF),
          secondaryContainer: const Color(0xFFE5E9F4),
          onSecondaryContainer: const Color(0xFF111420),
          surface: const Color(0xFFF4F5FA),
          surfaceContainerLowest: const Color(0xFFFFFFFF),
          surfaceContainerLow: const Color(0xFFFFFFFF),
          surfaceContainer: const Color(0xFFEBEEF6),
          surfaceContainerHigh: const Color(0xFFE5E9F4),
          surfaceContainerHighest: const Color(0xFFDEE2EE),
          onSurface: const Color(0xFF111420),
          onSurfaceVariant: const Color(0xFF535A73),
          outline: const Color(0xFFC4CADB),
          outlineVariant: const Color(0xFFDEE2EE),
          error: const Color(0xFFB83D4C),
          onError: const Color(0xFFFFFFFF),
          errorContainer: const Color(0xFFFBE4E6),
          onErrorContainer: const Color(0xFF5C1620),
          tertiaryContainer: const Color(0xFFF6EBDA),
          onTertiaryContainer: const Color(0xFF4A3413),
        );

  final status = isDark ? StatusColors.dark : StatusColors.light;

  // One pointer language for the whole app. `onSurface` is the tint on every
  // component, including the filled buttons: their fill is set per call site
  // (primary on Home, error on the destructive dialogs, a tonal container on
  // Servers), and a light-on-dark / dark-on-light tint is the only one that
  // stays visible on all three.
  final overlay = pointerOverlay(scheme.onSurface);

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: [status],
    fontFamily: kUiFont,
    // No ink. A ripple is a touch affordance: it animates outward from the
    // contact point to tell a finger that something under it was hit. A mouse
    // already knows where it clicked, and the expanding circle is the single
    // loudest Material tell left in a repainted app. Every component below
    // states its pointer states as flat overlays instead.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    // The legacy (non-`WidgetStateProperty`) half of the same model, for the
    // components whose theme data has no `overlayColor` at all — `ListTile`,
    // `PopupMenuItem`, `NavigationRail`'s focus highlight and any bare
    // `InkWell` on a screen all read these two off `ThemeData`.
    hoverColor: scheme.onSurface.withValues(alpha: _kHoverAlpha),
    focusColor: scheme.onSurface.withValues(alpha: _kFocusAlpha),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
    ),
    // The rail's selected item is a rounded rectangle at the kit's button
    // radius, not Material 3's stadium pill. `indicatorShape` is also the
    // `customBorder` of the item's ink response, so the hover highlight takes
    // the same shape as the indicator instead of a pill around it.
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    ),
    // One input language everywhere: subtle fill, hairline outline, calm
    // 1.5px primary focus ring, no hover fill. The state-specific borders
    // here override any per-field plain `border:` declaration, so every
    // field focuses identically.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF0D1120) : const Color(0xFFEDEFF7),
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
    // Controls carry the redesign's geometry, not Material's stadium default:
    // 34px standard height with an 8px radius, a 10px radius on the taller
    // status-strip and segmented controls. Setting it here means every call
    // site matches without repeating styleFrom.
    //
    // Each style then repeats the same two lines: `overlayColor` for the flat
    // hover / focus / press tint, and `side` for the focus ring. They are
    // stated per component rather than inherited because Material has no
    // app-wide `overlayColor`, and a component left unstated falls back to its
    // own M3 default — which is exactly the tint-plus-ripple this is replacing.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          // A ButtonStyle textStyle replaces the ambient one instead of
          // merging, so the family has to be named or the label silently
          // falls back to the platform font.
          fontFamily: kUiFont,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ).copyWith(
        overlayColor: overlay,
        // A filled button's ground IS an accent, so a primary ring would
        // vanish into it. The ring inverts to `onSurface` here: same
        // geometry, the tone that stays visible on primary, on error and on
        // the tonal container alike.
        side: focusRingSide(scheme.onSurface),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          // A ButtonStyle textStyle replaces the ambient one instead of
          // merging, so the family has to be named or the label silently
          // falls back to the platform font.
          fontFamily: kUiFont,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ).copyWith(
        overlayColor: overlay,
        side: focusRingSide(scheme.primary),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        foregroundColor: scheme.onSurface,
        textStyle: const TextStyle(
          fontFamily: kUiFont,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ).copyWith(
        overlayColor: overlay,
        // The hairline it already had at rest, thickened into the ring on
        // focus — the border never disappears, it only changes colour.
        side: focusRingSide(
          scheme.primary,
          resting: BorderSide(color: scheme.outline),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        foregroundColor: scheme.primary,
        textStyle: const TextStyle(
          fontFamily: kUiFont,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ).copyWith(
        overlayColor: overlay,
        side: focusRingSide(scheme.primary),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(28, 28),
        padding: const EdgeInsets.all(4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        foregroundColor: scheme.onSurfaceVariant,
      ).copyWith(
        overlayColor: overlay,
        side: focusRingSide(scheme.primary),
      ),
    ),
    // The segmented control paints its enclosing border from the resting
    // `side`, so the ring here lands on the focused segment only — which is
    // what a keyboard user is actually moving through.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: scheme.surfaceContainerLowest,
        foregroundColor: scheme.onSurfaceVariant,
        selectedBackgroundColor: scheme.secondaryContainer,
        selectedForegroundColor: scheme.onSecondaryContainer,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: const TextStyle(
          fontFamily: kUiFont,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ).copyWith(
        overlayColor: overlay,
        side: focusRingSide(
          scheme.primary,
          resting: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    ),
    // `PopupMenuThemeData` and `ListTileThemeData` carry no `overlayColor` at
    // all — both components put a bare `InkWell` around their content, which
    // reads `hoverColor` / `focusColor` / `splashFactory` off `ThemeData`.
    // Those are set at the top of this builder, so these two answer the
    // pointer with the same tints as the buttons; what is left to state here
    // is the surface each one sits on.
    popupMenuTheme: PopupMenuThemeData(
      elevation: 0,
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outline),
      ),
      textStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
    ),
    listTileTheme: ListTileThemeData(
      // The kit's row: rounded, so the hover tint lands as a soft rectangle
      // rather than edge to edge.
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      selectedTileColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.onSurface,
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      backgroundColor: scheme.surfaceContainerLowest,
      selectedColor: scheme.secondaryContainer,
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      secondaryLabelStyle: TextStyle(fontSize: 12, color: scheme.onSurface),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      showCheckmark: false,
    ),
    // Explanations live in tooltips now, so they are a first-class surface.
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 350),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outline),
      ),
      textStyle: TextStyle(fontSize: 12, height: 1.45, color: scheme.onSurface),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
    ),
  );
}

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The design system's toggle: a 32×18 track with a 14px thumb.
///
/// Material's `Switch` is 52×32 in M3, with a thumb that grows while pressed
/// and a ripple halo behind it, and none of that is reachable through
/// `switchTheme` — the geometry is baked into `_SwitchConfig`. At three times
/// the area of every other control on the screen it was the loudest Material
/// object left in the app, so it is replaced rather than restyled.
///
/// What it keeps from the Material one, because a smaller switch is not an
/// excuse for a worse one:
///
///  * a nullable [onChanged] — null means disabled, drawn at reduced opacity
///    and unfocusable, exactly like `Switch`;
///  * keyboard focus with a visible ring, and space / enter to toggle;
///  * a hover state;
///  * semantics: the node announces as a toggle carrying its own state, so a
///    screen reader still reads "on" / "off" and its enabled-ness.
///
/// Pass [semanticLabel] when the switch is not already inside a row whose text
/// names it — a control with a tap action and no accessible name fails
/// `labeledTapTargetGuideline`.
class AppSwitch extends StatefulWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.focusNode,
    this.autofocus = false,
  });

  /// Whether the switch is on.
  final bool value;

  /// Called with the new value when the user toggles the switch.
  ///
  /// Null disables the control: no pointer states, no focus, reduced opacity.
  final ValueChanged<bool>? onChanged;

  /// Accessible name, for a switch whose own row does not already provide one.
  final String? semanticLabel;

  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

/// Kit geometry: track 32×18, thumb 14, so 2px of track shows around it.
const double _trackWidth = 32;
const double _trackHeight = 18;
const double _thumbSize = 14;

/// The focus ring is drawn around the track rather than on it — on an "on"
/// switch the track is already `primary`, and a primary ring on a primary
/// track is no ring at all. The gap is reserved at every state so focusing
/// never changes the widget's size.
const double _ringGap = 3;

const double _disabledOpacity = 0.4;

class _AppSwitchState extends State<AppSwitch> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() {
    widget.onChanged?.call(!widget.value);
  }

  Set<WidgetState> get _states => <WidgetState>{
    if (!_enabled) WidgetState.disabled,
    if (_hovered) WidgetState.hovered,
    if (_focused) WidgetState.focused,
    if (_pressed) WidgetState.pressed,
    if (widget.value) WidgetState.selected,
  };

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // On: the accent, with the thumb in the colour that reads against it.
    // Off: the outline tone the kit uses for an off track, with a muted thumb
    // so "off" stays legible instead of disappearing into the track.
    final track = widget.value ? scheme.primary : scheme.outline;
    final thumb = widget.value ? scheme.onPrimary : scheme.onSurfaceVariant;

    // The same hover / focus / press tints every themed button uses, blended
    // into the track instead of floating above it as a halo.
    final overlay = pointerOverlay(scheme.onSurface).resolve(_states);
    final tintedTrack = overlay == null
        ? track
        : Color.alphaBlend(overlay, track);

    final control = AnimatedContainer(
      duration: kStateChangeDuration,
      curve: kMotionCurve,
      width: _trackWidth + _ringGap * 2,
      height: _trackHeight + _ringGap * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular((_trackHeight + _ringGap * 2) / 2),
        border: Border.all(
          color: _focused ? scheme.primary : Colors.transparent,
          width: kFocusRingWidth,
        ),
      ),
      child: AnimatedContainer(
        duration: kStateChangeDuration,
        curve: kMotionCurve,
        width: _trackWidth,
        height: _trackHeight,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: tintedTrack,
          borderRadius: BorderRadius.circular(_trackHeight / 2),
        ),
        child: AnimatedAlign(
          duration: kStateChangeDuration,
          curve: kMotionCurve,
          alignment: widget.value
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: AnimatedContainer(
            duration: kStateChangeDuration,
            curve: kMotionCurve,
            width: _thumbSize,
            height: _thumbSize,
            decoration: BoxDecoration(color: thumb, shape: BoxShape.circle),
          ),
        ),
      ),
    );

    // A tap is the whole gesture vocabulary: a 32px track is not something a
    // pointer drags, and the Material switch's drag exists for thumbs.
    final interactive = FocusableActionDetector(
      enabled: _enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      mouseCursor: _enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onShowHoverHighlight: (value) {
        if (_hovered == value) return;
        setState(() => _hovered = value);
      },
      onShowFocusHighlight: (value) {
        if (_focused == value) return;
        setState(() => _focused = value);
      },
      // Space and Enter arrive as activation intents from the app's default
      // shortcuts; both toggle, the way the Material switch does.
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _toggle();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) {
            _toggle();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _enabled ? _toggle : null,
        onTapDown: _enabled ? (_) => _setPressed(true) : null,
        onTapUp: _enabled ? (_) => _setPressed(false) : null,
        onTapCancel: _enabled ? () => _setPressed(false) : null,
        child: _enabled
            ? control
            : Opacity(opacity: _disabledOpacity, child: control),
      ),
    );

    // Merged so the label, the toggled state, the enabled state and the tap
    // action land on one semantics node instead of a labelless tappable one.
    return MergeSemantics(
      child: Semantics(
        container: true,
        toggled: widget.value,
        enabled: _enabled,
        label: widget.semanticLabel,
        child: interactive,
      ),
    );
  }
}

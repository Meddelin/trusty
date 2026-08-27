// AppSwitch replaced Material's Switch, which is 52x32 with a fixed thumb and
// its own ripple. A hand-rolled control has to earn back everything the
// framework one gave for free, so this pins that contract: size, toggling by
// pointer AND keyboard, the disabled state, and the semantics a screen reader
// needs.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trusty/theme/app_theme.dart';
import 'package:trusty/widgets/app_switch.dart';

Future<void> _pump(
  WidgetTester tester, {
  required bool value,
  required ValueChanged<bool>? onChanged,
  bool autofocus = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.dark),
      home: Scaffold(
        body: Center(
          child: AppSwitch(
            value: value,
            onChanged: onChanged,
            semanticLabel: 'Anti-DPI',
            autofocus: autofocus,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('is the kit size, not the Material one', (tester) async {
    await _pump(tester, value: false, onChanged: (_) {});
    final size = tester.getSize(find.byType(AppSwitch));
    expect(size.width, lessThan(52), reason: 'Material Switch is 52 wide');
    expect(size.height, lessThan(32), reason: 'Material Switch is 32 tall');
  });

  testWidgets('a tap toggles it', (tester) async {
    bool? got;
    await _pump(tester, value: false, onChanged: (v) => got = v);
    await tester.tap(find.byType(AppSwitch));
    expect(got, isTrue);
  });

  testWidgets('space and enter toggle it from the keyboard', (tester) async {
    final seen = <bool>[];
    await _pump(tester, value: false, onChanged: seen.add, autofocus: true);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(seen, hasLength(2), reason: 'both keys must activate it');
  });

  testWidgets('a null callback disables it and it stops taking focus',
      (tester) async {
    await _pump(tester, value: true, onChanged: null);
    await tester.tap(find.byType(AppSwitch), warnIfMissed: false);
    await tester.pumpAndSettle();

    final node = tester.widget<Focus>(
      find.descendant(of: find.byType(AppSwitch), matching: find.byType(Focus)).first,
    );
    expect(node.canRequestFocus, isFalse);
  });

  testWidgets('a screen reader gets one node with the name and the state',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, value: true, onChanged: (_) {});

    expect(
      tester.getSemantics(find.byType(AppSwitch)),
      matchesSemantics(
        label: 'Anti-DPI',
        hasToggledState: true,
        isToggled: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });
}

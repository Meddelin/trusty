// The navigation rail's footer carries what belongs to the application rather
// than to a connection: how the window behaves on close, the project links and
// the running version. The close-action control used to live on the Servers
// screen; these tests followed it here.
//
// The footer is pumped on its own rather than through MainScreen: the shell
// starts an update check on a delayed timer and then a daily periodic one,
// which outlive a widget test and trip its pending-timer check.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:trusty/main.dart';

import 'harness.dart';

Future<void> _openPreferences(WidgetTester tester) async {
  final gear = find.byIcon(Icons.tune);
  expect(gear, findsOneWidget, reason: 'the rail footer has no preferences control');
  await tester.tap(gear);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the footer offers the three close actions and applies each one',
      (tester) async {
    await pumpScreen(tester, const RailFooter());
    await _openPreferences(tester);

    expect(find.text('On window close'), findsOneWidget);
    for (final option in ['ask', 'minimize', 'exit']) {
      expect(find.text(option), findsOneWidget, reason: 'missing option: $option');
    }

    await tester.tap(find.text('minimize'));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString('close_action'),
        'minimize');

    await _openPreferences(tester);
    await tester.tap(find.text('exit'));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getString('close_action'),
        'exit');

    await _openPreferences(tester);
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getString('close_action'),
      isNull,
      reason: '"ask" is the default, so choosing it clears the preference',
    );
  });

  testWidgets('the current choice is shown as checked when the menu opens',
      (tester) async {
    await pumpScreen(tester, const RailFooter(),
        prefs: {'close_action': 'exit'});
    await _openPreferences(tester);

    final checked = tester
        .widgetList<CheckedPopupMenuItem<String>>(
            find.byType(CheckedPopupMenuItem<String>))
        .where((item) => item.checked)
        .toList();
    expect(checked, hasLength(1));
    expect(checked.single.value, 'exit');
  });

  testWidgets('the footer links out to the project and the group',
      (tester) async {
    await pumpScreen(tester, const RailFooter());
    expect(find.byTooltip('Open the project on GitHub'), findsOneWidget);
    expect(find.byTooltip('Open the Telegram group'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/colors.dart';
import 'package:superduper/theme.dart';
import 'package:superduper/widgets.dart';

/// Draft A's rule, as a test: a card's surfaces never come from the bike's
/// colour, and the only place a label sits on a solid accent fill is a
/// selected segment — where it must be picked for contrast against it.
void main() {
  /// The card's own decorated box: the only one it paints with a border.
  /// Matched by that border rather than by position, so a wrapper widget
  /// inserting a box of its own cannot make this pick the wrong one.
  BoxDecoration cardDecoration(WidgetTester tester) => tester
      .widgetList<Container>(find.descendant(
          of: find.byType(ControlCard), matching: find.byType(Container)))
      .map((c) => c.decoration)
      .whereType<BoxDecoration>()
      .firstWhere((d) => d.border != null);

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(backgroundColor: SDSurface.page, body: child)));

  testWidgets('a card paints one surface for every bike colour', (tester) async {
    // 8 is Fiery Fuchsia, 26 is Pure White, 5 is a pastel. All must land on the
    // same graphite card: the old page painted each of these as a gradient.
    for (final colorIndex in [8, 26, 5]) {
      await pump(tester, ControlCard(title: 'Light', colorIndex: colorIndex));
      expect(cardDecoration(tester).color, SDSurface.card,
          reason: 'colour index $colorIndex must not reach the surface');
      expect(cardDecoration(tester).gradient, isNull);
    }
  });

  testWidgets('assist renders five segments and never wraps', (tester) async {
    await pump(
      tester,
      ControlCard(
        title: 'Assist',
        colorIndex: 8,
        showSwitch: false,
        body: SelectorBody(
          colorIndex: 8,
          layout: SelectorLayout.segments,
          items: [
            for (var level = 0; level <= 4; level++)
              SelectorItem(
                keyValue: 'assistChip:$level',
                label: '$level',
                tooltip: 'Select assist $level',
                selected: level == 2,
                onTap: () {},
              ),
          ],
        ),
      ),
    );

    final chips = tester.widgetList<SelectorChip>(find.byType(SelectorChip));
    expect(chips, hasLength(5));
    expect(chips.every((c) => c.layout == SelectorLayout.segments), isTrue);
    expect(find.byType(Wrap), findsNothing,
        reason: 'a Wrap is what put assist 4 on its own line');

    // One row: every segment shares the row's vertical centre.
    final tops = [
      for (var level = 0; level <= 4; level++)
        tester.getTopLeft(find.byKey(ValueKey('assistChip:$level'))).dy,
    ];
    expect(tops.every((t) => t == tops.first), isTrue,
        reason: 'the segments must sit on one line');
  });

  testWidgets('a selected segment label is picked for contrast on the accent',
      (tester) async {
    // Pure White: the accent is near-white, so a white label would vanish.
    // This is the case that breaks a design which hardcodes its label colour.
    const whiteIndex = 26;
    await pump(
      tester,
      SelectorBody(
        colorIndex: whiteIndex,
        layout: SelectorLayout.segments,
        items: [
          SelectorItem(
              keyValue: 'assistChip:0',
              label: '0',
              tooltip: 'Select assist 0',
              selected: true,
              onTap: () {}),
        ],
      ),
    );

    final label = tester.widget<Text>(find.descendant(
        of: find.byKey(const ValueKey('assistChip:0')),
        matching: find.byType(Text)));
    expect(label.style?.color, getColor(whiteIndex).onAccent());
    expect(label.style?.color, Colors.black,
        reason: 'a near-white accent needs a dark label');
  });
}

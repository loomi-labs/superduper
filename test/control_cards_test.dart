import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/colors.dart';
import 'package:superduper/models.dart';
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

  /// The padlock, driven the way a rider drives it: every tap moves the pin one
  /// step, and the widget is rebuilt from the new state.
  Future<void> pumpLock(WidgetTester tester) {
    var pin = PinState.open;
    return pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => EnhancedLockWidget(
          pin: pin,
          onTap: () => setState(() => pin = nextPin(pin)),
          tooltip: pinTooltip(pin, 'mode'),
        ),
      ),
    );
  }

  testWidgets('the padlock cycles open, startup and locked', (tester) async {
    await pumpLock(tester);

    final icons = <IconData?>[];
    final tooltips = <String?>[];
    for (var tap = 0; tap < 4; tap++) {
      icons.add(tester.widget<Icon>(find.byType(Icon)).icon);
      tooltips.add(tester.widget<IconButton>(find.byType(IconButton)).tooltip);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
    }

    expect(icons,
        [Icons.lock_open, Icons.push_pin, Icons.lock, Icons.lock_open],
        reason: 'the fourth tap must come back to open');
    // Colour alone cannot be read by a screen reader, so every state says what
    // it is.
    expect(tooltips.take(3).toSet(), hasLength(3),
        reason: 'each state must announce itself');
    expect(tooltips.take(3), everyElement(contains('mode')));
  });

  /// Two mode rows, the second one pinned when [pinned] is true.
  Widget modeRows({required bool pinned, VoidCallback? onTap}) => SelectorBody(
        colorIndex: 8,
        layout: SelectorLayout.rows,
        items: [
          SelectorItem(
              keyValue: 'modeChip:eco',
              label: 'ECO',
              tooltip: 'Select mode ECO',
              selected: true,
              onTap: () {}),
          SelectorItem(
              keyValue: 'modeChip:tour',
              label: 'Tour 30',
              tooltip: 'Select mode Tour 30',
              selected: false,
              pinned: pinned,
              onTap: onTap ?? () {}),
        ],
      );

  testWidgets('a startup pin marks the mode row it starts on', (tester) async {
    var taps = 0;
    await pump(tester, modeRows(pinned: true, onTap: () => taps++));

    expect(find.text('START'), findsOneWidget);
    expect(find.byKey(const ValueKey('pinMark:modeChip:tour')), findsOneWidget);
    expect(find.byKey(const ValueKey('pinMark:modeChip:eco')), findsNothing,
        reason: 'only the pinned row is marked');
    // The badge must not become a second Text inside the chip: the single-Text
    // finders in test/pickers_test.dart read the chip's label through one.
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('modeChip:tour')),
            matching: find.byType(Text)),
        findsOneWidget);

    // A badge that eats the row's tap makes the pinned mode unselectable.
    await tester.tap(find.byKey(const ValueKey('modeChip:tour')));
    expect(taps, 1);

    // The badge is painted over the row, so the row has to keep room for it:
    // a long mode name would otherwise run under it.
    final label = tester.getRect(find.descendant(
        of: find.byKey(const ValueKey('modeChip:tour')),
        matching: find.byType(Text)));
    final badge =
        tester.getRect(find.byKey(const ValueKey('pinMark:modeChip:tour')));
    expect(label.right, lessThanOrEqualTo(badge.left),
        reason: 'the badge must not sit on the label');
  });

  testWidgets('a startup pin marks the assist segment and says when',
      (tester) async {
    await pump(
      tester,
      SelectorBody(
        colorIndex: 8,
        layout: SelectorLayout.segments,
        caption: 'Starts at 2',
        items: [
          for (var level = 0; level <= 4; level++)
            SelectorItem(
              keyValue: 'assistChip:$level',
              label: '$level',
              tooltip: 'Select assist $level',
              selected: level == 0,
              pinned: level == 2,
              onTap: () {},
            ),
        ],
      ),
    );

    // A bare marker under a 48 dp segment cannot carry the meaning alone, so
    // the mark and the line come together.
    expect(find.byKey(const ValueKey('pinMark:assistChip:2')), findsOneWidget);
    expect(find.byKey(const ValueKey('pinMark:assistChip:3')), findsNothing);
    expect(find.text('Starts at 2'), findsOneWidget);

    final tops = [
      for (var level = 0; level <= 4; level++)
        tester.getTopLeft(find.byKey(ValueKey('assistChip:$level'))).dy,
    ];
    expect(tops.every((t) => t == tops.first), isTrue,
        reason: 'a mark must not push its own segment out of the row');
  });

  testWidgets('the light header says what the ride starts on', (tester) async {
    // Light has no list to mark, so the tag goes in the header.
    await pump(tester,
        const ControlCard(title: 'Light', colorIndex: 8, badge: 'STARTS ON'));
    expect(find.text('STARTS ON'), findsOneWidget);
  });

  testWidgets('an open pin shows no badge at all', (tester) async {
    await pump(tester, const ControlCard(title: 'Light', colorIndex: 8));
    expect(find.text('STARTS ON'), findsNothing);
    expect(find.text('STARTS OFF'), findsNothing);

    await pump(tester, modeRows(pinned: false));
    expect(find.text('START'), findsNothing);
    expect(find.byKey(const ValueKey('pinMark:modeChip:tour')), findsNothing);

    await pump(
      tester,
      SelectorBody(
        colorIndex: 8,
        layout: SelectorLayout.segments,
        items: [
          for (var level = 0; level <= 4; level++)
            SelectorItem(
                keyValue: 'assistChip:$level',
                label: '$level',
                tooltip: 'Select assist $level',
                selected: level == 0,
                onTap: () {}),
        ],
      ),
    );
    expect(find.byKey(const ValueKey('pinMark:assistChip:2')), findsNothing);
    expect(find.textContaining('Starts at'), findsNothing);
  });
}

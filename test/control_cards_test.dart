import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/colors.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/theme.dart';
import 'package:superduper/widgets.dart';

/// Draft A's rule, as a test: a card's surfaces never come from the bike's
/// colour, and the only place a label sits on a solid accent fill is a
/// selected segment — where it must be picked for contrast against it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  /// The card's rows/segments always drive the live bike now, whatever the
  /// pin says. Picking the value a ride starts on happens only in the sheet
  /// [showPinValueSheet] opens, and only the padlock's own tap opens it — and
  /// only when that tap is about to arm [PinState.startup].
  group('startup pin', () {
    const id = 'fa:ke:aa:bb:cc:dd';
    const sheetTitle = 'Start every ride with';

    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('superduper_start_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => tempDir.path,
      );
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    /// Lets the write chain run out without advancing the clock, so the poll
    /// and the debounce never fire. As in test/pickers_test.dart.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump();
      }
    }

    /// Opens a bike, pumps one of its control cards, and puts the connection
    /// where the test wants it.
    Future<ProviderContainer> pumpCard(
      WidgetTester tester, {
      required BikeState bike,
      required Widget Function(BikeState) build,
      required bool connected,
    }) async {
      final container = ProviderContainer();
      container.listen(bikeProvider(id), (previous, next) {});
      container.read(bikeProvider(id).notifier).writeStateData(bike);
      await settle(tester);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, child) =>
                  build(ref.watch(bikeProvider(id))),
            ),
          ),
        ),
      ));
      if (!connected) {
        // ignore: invalid_use_of_protected_member
        container.read(connectionHandlerProvider(id).notifier).state =
            SDBluetoothConnectionState.disconnected;
      }
      await settle(tester);
      return container;
    }

    /// A US bike on native mode 0, with two custom modes to aim at.
    BikeState usBike() => BikeState.defaultState(id)
        .copyWith(region: BikeRegion.us, customModes: const [])
        .withSelectedMode(nativeModeId(0));

    /// Moves a padlock [taps] steps, the way a rider does — calling the
    /// notifier directly, exactly as a widget's own [EnhancedLockWidget] tap
    /// would when it needs no sheet. WP3 leaves these notifier methods alone.
    Future<void> cycle(ProviderContainer container, VoidCallback tap,
        WidgetTester tester, int taps) async {
      for (var i = 0; i < taps; i++) {
        tap();
        await settle(tester);
      }
    }

    /// Taps from [PinState.open], the state a fresh bike opens on.
    const tapsTo = {PinState.open: 0, PinState.startup: 1, PinState.locked: 2};

    /// The only IconButton a pumped card ever has: its padlock.
    final padlock = find.byType(IconButton);

    /// Pumps the frames a real modal route needs to become hit-testable.
    /// [settle] deliberately never advances the clock (see its own comment),
    /// so an AnimationController-driven route never leaves its opening frame
    /// on settle() pumps alone. The explicit duration below finishes the
    /// entrance transition while staying far short of the 2 s write debounce
    /// and the 5 s poll, so opening a sheet never trips either.
    Future<void> openSheet(WidgetTester tester, Finder lock) async {
      await tester.tap(lock);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Taps a sheet row and lets the pick's write chain run out.
    Future<void> pickOption(WidgetTester tester, Finder row) async {
      await tester.tap(row);
      await tester.pump();
      await settle(tester);
    }

    /// Dismisses the sheet by tapping its scrim, well above the sheet's own
    /// content, which sits at the bottom of the test surface.
    Future<void> dismissSheet(WidgetTester tester) async {
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();
      await settle(tester);
    }

    for (final connected in [false, true]) {
      final where = connected ? 'connected' : 'disconnected';

      for (final MapEntry(key: pin, value: taps) in tapsTo.entries) {
        testWidgets(
            'a mode tap always drives the live mode ($where, pin ${pin.name})',
            (tester) async {
          final container = await pumpCard(tester,
              bike: usBike(),
              build: (b) => EnhancedModeControlWidget(bike: b),
              connected: connected);
          final control = container.read(bikeProvider(id).notifier);
          await cycle(container, control.cycleModePin, tester, taps);

          await tester
              .tap(find.byKey(ValueKey('modeChip:${nativeModeId(2)}')));
          await settle(tester);

          final state = container.read(bikeProvider(id));
          container.dispose();
          expect(state.pinMode, pin, reason: 'a row tap never moves the pin');
          expect(state.selectedMode.id,
              connected ? nativeModeId(2) : nativeModeId(0),
              reason: connected
                  ? 'a tap always drives the bike, whatever the pin'
                  : 'a disconnected bike ignores the tap');
        });

        testWidgets(
            'an assist tap always drives the live level ($where, pin ${pin.name})',
            (tester) async {
          final container = await pumpCard(tester,
              bike: usBike().copyWith(assist: 1),
              build: (b) => EnhancedAssistControlWidget(bike: b),
              connected: connected);
          final control = container.read(bikeProvider(id).notifier);
          await cycle(container, control.cycleAssistPin, tester, taps);

          await tester.tap(find.byKey(const ValueKey('assistChip:4')));
          await settle(tester);

          final state = container.read(bikeProvider(id));
          container.dispose();
          expect(state.pinAssist, pin,
              reason: 'a segment tap never moves the pin');
          expect(state.assist, connected ? 4 : 1,
              reason: connected
                  ? 'a tap always drives the bike, whatever the pin'
                  : 'a disconnected bike ignores the tap');
        });

        testWidgets(
            'a light tap always drives the live light ($where, pin ${pin.name})',
            (tester) async {
          final container = await pumpCard(tester,
              bike: usBike().copyWith(light: false),
              build: (b) => EnhancedLightControlWidget(bike: b),
              connected: connected);
          final control = container.read(bikeProvider(id).notifier);
          await cycle(container, control.cycleLightPin, tester, taps);

          await tester.tap(find.text('Light'));
          await settle(tester);

          final state = container.read(bikeProvider(id));
          container.dispose();
          expect(state.pinLight, pin, reason: 'a card tap never moves the pin');
          expect(state.light, connected,
              reason: connected
                  ? 'a tap always drives the bike, whatever the pin'
                  : 'a disconnected bike ignores the tap');
        });
      }
    }

    testWidgets('the padlock opens a sheet when it arms startup, mode',
        (tester) async {
      final container = await pumpCard(tester,
          bike: usBike(),
          build: (b) => EnhancedModeControlWidget(bike: b),
          connected: true);

      await openSheet(tester, padlock);
      expect(find.text(sheetTitle), findsOneWidget);
      expect(find.byKey(ValueKey('pinSheetOption:${nativeModeId(1)}')),
          findsOneWidget);

      await pickOption(
          tester, find.byKey(ValueKey('pinSheetOption:${nativeModeId(1)}')));

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinMode, PinState.startup);
      expect(state.startupModeId, nativeModeId(1));
      expect(state.selectedMode.id, nativeModeId(0),
          reason: 'picking a startup value never rides it');
    });

    testWidgets('the padlock opens a sheet when it arms startup, assist',
        (tester) async {
      final container = await pumpCard(tester,
          bike: usBike().copyWith(assist: 1),
          build: (b) => EnhancedAssistControlWidget(bike: b),
          connected: true);

      await openSheet(tester, padlock);
      expect(find.text(sheetTitle), findsOneWidget);
      expect(find.byKey(const ValueKey('pinSheetOption:4')), findsOneWidget);

      await pickOption(tester, find.byKey(const ValueKey('pinSheetOption:4')));

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinAssist, PinState.startup);
      expect(state.startupAssist, 4);
      expect(state.assist, 1, reason: 'picking a startup value never rides it');
    });

    testWidgets('the padlock opens a sheet when it arms startup, light',
        (tester) async {
      final container = await pumpCard(tester,
          bike: usBike().copyWith(light: false),
          build: (b) => EnhancedLightControlWidget(bike: b),
          connected: true);

      await openSheet(tester, padlock);
      expect(find.text(sheetTitle), findsOneWidget);
      expect(
          find.byKey(const ValueKey('pinSheetOption:true')), findsOneWidget);
      expect(
          find.byKey(const ValueKey('pinSheetOption:false')), findsOneWidget);

      await pickOption(
          tester, find.byKey(const ValueKey('pinSheetOption:true')));

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinLight, PinState.startup);
      expect(state.startupLight, isTrue);
      expect(state.light, isFalse,
          reason: 'picking a startup value never rides it');
    });

    testWidgets('dismissing the sheet leaves the pin exactly where it was',
        (tester) async {
      final container = await pumpCard(tester,
          bike: usBike(),
          build: (b) => EnhancedModeControlWidget(bike: b),
          connected: true);

      await openSheet(tester, padlock);
      expect(find.text(sheetTitle), findsOneWidget);

      await dismissSheet(tester);

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinMode, PinState.open);
      expect(state.startupModeId, isNull,
          reason: 'a dismissed sheet touches no startup field');
    });

    testWidgets('the sheet opens and saves a pick while disconnected, mode',
        (tester) async {
      // The point of the whole feature: a pin is app state, so it must work
      // with the bike out of range.
      final container = await pumpCard(tester,
          bike: usBike(),
          build: (b) => EnhancedModeControlWidget(bike: b),
          connected: false);

      await openSheet(tester, padlock);
      expect(find.text(sheetTitle), findsOneWidget);

      await pickOption(
          tester, find.byKey(ValueKey('pinSheetOption:${nativeModeId(2)}')));

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinMode, PinState.startup);
      expect(state.startupModeId, nativeModeId(2));
    });

    testWidgets('the sheet opens and saves a pick while disconnected, light',
        (tester) async {
      final container = await pumpCard(tester,
          bike: usBike().copyWith(light: false),
          build: (b) => EnhancedLightControlWidget(bike: b),
          connected: false);

      await openSheet(tester, padlock);
      expect(find.text(sheetTitle), findsOneWidget);

      await pickOption(
          tester, find.byKey(const ValueKey('pinSheetOption:true')));

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinLight, PinState.startup);
      expect(state.startupLight, isTrue);
    });

    testWidgets('the caption appears only while the pin is on startup',
        (tester) async {
      for (final (build, captionPrefix) in [
        ((BikeState b) => EnhancedModeControlWidget(bike: b), 'Starts with'),
        ((BikeState b) => EnhancedAssistControlWidget(bike: b), 'Starts with'),
        ((BikeState b) => EnhancedLightControlWidget(bike: b), 'Starts'),
      ]) {
        final container = await pumpCard(tester,
            bike: usBike(), build: build, connected: true);
        final control = container.read(bikeProvider(id).notifier);
        void cycleAll() {
          control.cycleModePin();
          control.cycleAssistPin();
          control.cycleLightPin();
        }

        expect(find.textContaining(captionPrefix), findsNothing,
            reason: 'open shows nothing');

        await cycle(container, cycleAll, tester, 1);
        expect(find.textContaining(captionPrefix), findsOneWidget);

        await cycle(container, cycleAll, tester, 1);
        expect(find.textContaining(captionPrefix), findsNothing,
            reason: 'a locked pin holds a value, it shows no caption');

        await cycle(container, cycleAll, tester, 1);
        expect(find.textContaining(captionPrefix), findsNothing,
            reason: 'back to open');
        container.dispose();
      }
    });

    testWidgets('the mode caption re-opens the sheet without re-arming the pin',
        (tester) async {
      final container = await pumpCard(tester,
          bike: usBike(),
          build: (b) => EnhancedModeControlWidget(bike: b),
          connected: true);
      final control = container.read(bikeProvider(id).notifier);
      // Arms startup: startupModeId captures the live mode, wire 0, "20 mph".
      await cycle(container, control.cycleModePin, tester, 1);

      await tester.tap(find.text('Starts with 20 mph · Change'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(sheetTitle), findsOneWidget);
      final markedIcon = tester.widget<Icon>(find.descendant(
          of: find.byKey(ValueKey('pinSheetOption:${nativeModeId(0)}')),
          matching: find.byType(Icon)));
      expect(markedIcon.icon, Icons.radio_button_checked,
          reason: 'the sheet premarks the current startup value');

      await pickOption(
          tester, find.byKey(ValueKey('pinSheetOption:${nativeModeId(3)}')));

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinMode, PinState.startup,
          reason: 'the caption re-aims, it does not re-arm');
      expect(state.startupModeId, nativeModeId(3));
    });

    testWidgets(
        'the assist caption re-opens the sheet without re-arming the pin',
        (tester) async {
      final container = await pumpCard(tester,
          bike: usBike().copyWith(assist: 1),
          build: (b) => EnhancedAssistControlWidget(bike: b),
          connected: true);
      final control = container.read(bikeProvider(id).notifier);
      await cycle(container, control.cycleAssistPin, tester, 1);

      await tester.tap(find.text('Starts with 1 · Change'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(sheetTitle), findsOneWidget);

      await pickOption(tester, find.byKey(const ValueKey('pinSheetOption:3')));

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinAssist, PinState.startup,
          reason: 'the caption re-aims, it does not re-arm');
      expect(state.startupAssist, 3);
    });

    testWidgets('the light caption re-opens the sheet without re-arming the pin',
        (tester) async {
      final container = await pumpCard(tester,
          bike: usBike().copyWith(light: false),
          build: (b) => EnhancedLightControlWidget(bike: b),
          connected: true);
      final control = container.read(bikeProvider(id).notifier);
      await cycle(container, control.cycleLightPin, tester, 1);

      await tester.tap(find.text('Starts off · Change'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(sheetTitle), findsOneWidget);

      await pickOption(
          tester, find.byKey(const ValueKey('pinSheetOption:true')));

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinLight, PinState.startup,
          reason: 'the caption re-aims, it does not re-arm');
      expect(state.startupLight, isTrue);
    });

    testWidgets('a locked padlock needs no sheet', (tester) async {
      final container = await pumpCard(tester,
          bike: usBike(),
          build: (b) => EnhancedModeControlWidget(bike: b),
          connected: false);
      final control = container.read(bikeProvider(id).notifier);
      // Startup, then locked: the second tap is the rider's way in, the third
      // is their way out, and neither needs a sheet once locked.
      await cycle(container, control.cycleModePin, tester, 2);
      expect(container.read(bikeProvider(id)).pinMode, PinState.locked);
      expect(find.textContaining('Starts with'), findsNothing);

      await tester.tap(padlock);
      await tester.pump();
      expect(find.text(sheetTitle), findsNothing,
          reason: 'a locked padlock cycles straight through, no sheet');

      final state = container.read(bikeProvider(id));
      container.dispose();
      expect(state.pinMode, PinState.open);
      expect(state.startupModeId, nativeModeId(0),
          reason: 'cycling past locked touches no startup field');
    });

    /// WP7: each card gates on its own measured capability. A firmware that
    /// refuses a write gets no picker for it — the row would do nothing when
    /// tapped — but the other two controls, if the bike accepts them, keep
    /// working exactly as before.
    group('capability gating', () {
      BikeCapabilities caps({
        List<int> acceptedWires = const [0, 1, 2, 3, 4, 5, 6, 7],
        List<int> acceptedAssist = const [0, 1, 2, 3, 4],
        bool lightWritable = true,
      }) =>
          BikeCapabilities(
            measuredAt: DateTime(2024),
            acceptedWires: acceptedWires,
            acceptedAssist: acceptedAssist,
            lightWritable: lightWritable,
          );

      testWidgets('a bike that refuses the mode shows its value plainly',
          (tester) async {
        final bike =
            usBike().copyWith(capabilities: caps(acceptedWires: const [0]));
        final container = await pumpCard(tester,
            bike: bike,
            build: (b) => EnhancedModeControlWidget(bike: b),
            connected: true);
        container.dispose();

        expect(find.byType(SelectorBody), findsNothing);
        expect(find.byType(EnhancedLockWidget), findsNothing);
        expect(find.text(bike.selectedMode.label(bike.region)),
            findsOneWidget);
        expect(find.text('This bike does not let the app change the mode.'),
            findsOneWidget);
      });

      testWidgets(
          'a bike that refuses the assist level shows its value plainly',
          (tester) async {
        final bike = usBike()
            .copyWith(assist: 2, capabilities: caps(acceptedAssist: const [2]));
        final container = await pumpCard(tester,
            bike: bike,
            build: (b) => EnhancedAssistControlWidget(bike: b),
            connected: true);
        container.dispose();

        expect(find.byType(SelectorBody), findsNothing);
        expect(find.byType(EnhancedLockWidget), findsNothing);
        expect(find.text('2'), findsOneWidget);
        expect(
            find.text(
                'This bike does not let the app change the assist level.'),
            findsOneWidget);
      });

      testWidgets('a bike that refuses the light shows its value plainly',
          (tester) async {
        final bike = usBike()
            .copyWith(light: true, capabilities: caps(lightWritable: false));
        final container = await pumpCard(tester,
            bike: bike,
            build: (b) => EnhancedLightControlWidget(bike: b),
            connected: true);

        expect(find.byType(EnhancedLockWidget), findsNothing);
        expect(find.text('On'), findsOneWidget);
        expect(find.text('This bike does not let the app change the light.'),
            findsOneWidget);

        await tester.tap(find.text('Light'));
        await settle(tester);
        final state = container.read(bikeProvider(id));
        container.dispose();
        expect(state.light, isTrue, reason: 'a locked light ignores the tap');
      });

      testWidgets(
          'each card gates on its own capability, not a combined flag',
          (tester) async {
        final onlyModeLocked = caps(acceptedWires: const [0]);

        var container = await pumpCard(tester,
            bike: usBike().copyWith(capabilities: onlyModeLocked),
            build: (b) => EnhancedModeControlWidget(bike: b),
            connected: true);
        expect(find.byType(EnhancedLockWidget), findsNothing,
            reason: 'mode is the one capability this bike refuses');
        container.dispose();

        container = await pumpCard(tester,
            bike: usBike().copyWith(assist: 1, capabilities: onlyModeLocked),
            build: (b) => EnhancedAssistControlWidget(bike: b),
            connected: true);
        expect(find.byType(EnhancedLockWidget), findsOneWidget,
            reason: 'assist is still writable even though mode is not');
        container.dispose();

        container = await pumpCard(tester,
            bike: usBike().copyWith(light: false, capabilities: onlyModeLocked),
            build: (b) => EnhancedLightControlWidget(bike: b),
            connected: true);
        expect(find.byType(EnhancedLockWidget), findsOneWidget,
            reason: 'light is still writable even though mode is not');
        container.dispose();
      });

      testWidgets(
          'capabilities == null falls back to fully writable, defensively',
          (tester) async {
        final bike = usBike().copyWith(capabilities: null);

        var container = await pumpCard(tester,
            bike: bike,
            build: (b) => EnhancedModeControlWidget(bike: b),
            connected: true);
        expect(find.byType(SelectorBody), findsOneWidget);
        expect(find.byType(EnhancedLockWidget), findsOneWidget);
        container.dispose();

        container = await pumpCard(tester,
            bike: bike.copyWith(assist: 1),
            build: (b) => EnhancedAssistControlWidget(bike: b),
            connected: true);
        expect(find.byType(SelectorBody), findsOneWidget);
        expect(find.byType(EnhancedLockWidget), findsOneWidget);
        container.dispose();

        container = await pumpCard(tester,
            bike: bike,
            build: (b) => EnhancedLightControlWidget(bike: b),
            connected: true);
        expect(find.byType(EnhancedLockWidget), findsOneWidget);
        container.dispose();
      });
    });
  });
}

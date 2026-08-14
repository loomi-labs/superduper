import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/db.dart';
import 'package:superduper/debug.dart';
import 'package:superduper/edit_bike.dart';

/// The Edit sheet: the pure [applySheetEdits] (what Save assembles) and the
/// widget behaviour around it — the custom-mode editor, its delete dialogs and
/// the auto-reconnect note.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'fa:ke:aa:bb:cc:dd';
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_edit_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// Opens the real Edit sheet over an empty page, so Save's `Navigator.pop`
  /// has a route to pop.
  Future<void> openSheet(WidgetTester tester, ProviderContainer container,
      BikeState bike) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    ));
    show(tester.element(find.byType(SizedBox)), bike);
    await tester.pumpAndSettle();
  }

  /// Drives the sheet the way a rider reaches it: [bike] on its own page, then
  /// the settings button in the app bar. A sheet pumped over a bare Scaffold
  /// skips that path, and a value that only survives there proves nothing about
  /// the app.
  Future<void> openFromBikePage(WidgetTester tester,
      ProviderContainer container, BikeState bike) async {
    container
        .read(bikeProvider(bike.id).notifier)
        .writeStateData(bike, saveToBike: false);
    await tester.pump();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: BikePage(bikeID: bike.id)),
    ));
    // Not pumpAndSettle: the page keeps a 5 s poll running for as long as it is
    // up, and the sheet's entrance is over well inside a second.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Bike settings'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// The checkbox as the rider sees it — the rendered tile, not the form's
  /// internal map nor the sheet's own mirror of it.
  bool? renderedAutoReconnect(WidgetTester tester) => tester
      .widget<CheckboxListTile>(find.descendant(
          of: find.byKey(const ValueKey('autoReconnectCheckbox')),
          matching: find.byType(CheckboxListTile)))
      .value;

  Future<void> tapAutoReconnect(WidgetTester tester) async {
    final checkbox = find.byKey(const ValueKey('autoReconnectCheckbox'));
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> selectRegion(WidgetTester tester, String from, String to) async {
    await tester.tap(find.text(from).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(to).last);
    await tester.pumpAndSettle();
  }

  const tour30 =
      CustomMode(id: 'c1', name: 'Tour 30', limitKmh: 30, throttle: true);
  const race45 =
      CustomMode(id: 'c2', name: 'Race 45', limitKmh: 45, throttle: false);

  group('applySheetEdits', () {
    /// The sheet with nothing touched: every named field defaults to what the
    /// bike already has, so each test names only what it changes.
    BikeState apply(BikeState live,
            {String? name,
            int? color,
            BikeRegion? region,
            List<CustomMode>? customModes,
            bool? autoReconnect}) =>
        applySheetEdits(live,
            name: name ?? live.name,
            color: color ?? live.color,
            region: region ?? live.region,
            customModes: customModes ?? live.customModes,
            autoReconnect: autoReconnect ?? live.autoReconnect);

    BikeState usBike() => BikeState.defaultState(id)
        .copyWith(region: BikeRegion.us, customModes: const [])
        .withSelectedMode(nativeModeId(2));

    test('copies the form fields and leaves a valid selection alone', () {
      final saved = apply(usBike(), name: 'Blue', color: 4);
      expect(saved.name, 'Blue');
      expect(saved.color, 4);
      expect(saved.selectedMode.id, nativeModeId(2));
      expect(saved.legacyMode, 2);
    });

    test('a region change moves a native mode into the new bank', () {
      final saved = apply(usBike(), region: BikeRegion.eu);
      expect(saved.region, BikeRegion.eu);
      expect(saved.selectedMode.id, nativeModeId(6),
          reason: 'the same place in the new bank, not a clamped index');
      expect(saved.legacyMode, 2, reason: 'the legacy projection follows');
    });

    test('off-road stays off-road across a region change', () {
      final saved = apply(usBike().withSelectedMode(nativeModeId(3)),
          region: BikeRegion.eu);
      expect(saved.selectedMode.id, nativeModeId(chWireOffroad));
    });

    test('a limited native going into CH lands on the seeded mode', () {
      final saved = apply(usBike(), region: BikeRegion.ch);
      expect(saved.customModes, const [seededChMode],
          reason: 'entering CH seeds the mode the region needs');
      expect(saved.selectedMode.id, seededChModeId,
          reason: 'a settings save never hands the rider an unlimited mode');
    });

    test('a custom selection survives a region change', () {
      final live = usBike()
          .copyWith(customModes: const [tour30]).withSelectedMode(tour30.id);
      final saved = apply(live, region: BikeRegion.eu);
      expect(saved.region, BikeRegion.eu);
      expect(saved.selectedMode.id, tour30.id,
          reason: 'a custom mode means the same thing in every region');
      expect(saved.needsSpeedSwitching, isTrue);
    });

    test('an unchanged CH region does not re-seed a deleted seeded mode', () {
      final live = BikeState.defaultState(id).copyWith(
          customModes: const [tour30]).withSelectedMode(tour30.id);
      final saved = apply(live, region: BikeRegion.ch);
      expect(saved.customModes, const [tour30],
          reason: 'the rider replaced the seeded mode with their own');
    });

    test('the custom modes list is replaced wholesale', () {
      final live = usBike().copyWith(customModes: const [tour30]);
      final saved = apply(live, customModes: const [race45]);
      expect(saved.customModes, const [race45]);
    });

    test('deleting the selected mode falls back through withSelectedMode', () {
      final live = usBike()
          .copyWith(customModes: const [tour30])
          .withSelectedMode(tour30.id)
          // A legacy projection that does not match the selection: only a
          // reselection through withSelectedMode brings it back in step.
          .copyWith(legacyMode: 3);
      final saved = apply(live, customModes: const []);
      expect(saved.selectedMode.id, nativeModeId(0),
          reason: 'the US fallback is its slowest limited native');
      expect(saved.modeId, nativeModeId(0), reason: 'not left dangling');
      expect(saved.legacyMode, 0, reason: 'the legacy projection follows');
    });

    test('deleting the last CH custom mode re-seeds instead of emptying', () {
      final live = BikeState.defaultState(id)
          .copyWith(customModes: const [tour30]).withSelectedMode(tour30.id);
      final saved = apply(live, customModes: const []);
      expect(saved.customModes, const [seededChMode]);
      expect(saved.selectedMode.id, seededChModeId);
    });

    test('rider-side light and assist survive a save', () {
      // The sheet was open while the poll brought in a handlebar change: Save
      // assembles onto the live bike, so the change is not written back.
      final live = usBike().copyWith(light: true, assist: 3);
      final saved = apply(live, name: 'Blue');
      expect(saved.assist, 3);
      expect(saved.light, isTrue);
    });

    test('the auto-reconnect setting passes through', () {
      expect(apply(usBike(), autoReconnect: false).autoReconnect, isFalse);
      expect(apply(usBike(), autoReconnect: true).autoReconnect, isTrue);
    });
  });

  testWidgets('Save moves a native selection into the new region bank',
      (tester) async {
    final container = ProviderContainer();
    container.listen(bikeProvider(id), (previous, next) {});
    final bike = BikeState.defaultState(id)
        .copyWith(region: BikeRegion.us, customModes: const [])
        .withSelectedMode(nativeModeId(2));
    container
        .read(bikeProvider(id).notifier)
        .writeStateData(bike, saveToBike: false);
    await tester.pump();

    await openSheet(tester, container, container.read(bikeProvider(id)));
    await selectRegion(tester, 'US', 'EU');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = container.read(bikeProvider(id));
    // Before the expects: the notifier's poll timer has to be cancelled while
    // the widget tree is still up, or the test framework fails on it instead.
    container.dispose();
    expect(saved.region, BikeRegion.eu);
    expect(saved.selectedMode.id, nativeModeId(6),
        reason: 'the same place in the new bank, not a clamped mode index');
    expect(saved.legacyMode, 2, reason: 'the legacy projection follows');
  });

  testWidgets('Save into CH keeps the rider on a limited mode', (tester) async {
    final container = ProviderContainer();
    container.listen(bikeProvider(id), (previous, next) {});
    final bike = BikeState.defaultState(id)
        .copyWith(region: BikeRegion.us, customModes: const [])
        .withSelectedMode(nativeModeId(2));
    container
        .read(bikeProvider(id).notifier)
        .writeStateData(bike, saveToBike: false);
    await tester.pump();

    await openSheet(tester, container, container.read(bikeProvider(id)));
    await selectRegion(tester, 'US', 'CH');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = container.read(bikeProvider(id));
    // Before the expects: the notifier's poll timer has to be cancelled while
    // the widget tree is still up, or the test framework fails on it instead.
    container.dispose();
    expect(saved.region, BikeRegion.ch);
    // CH has no limited native mode, and a settings save must never hand the
    // rider an unlimited one: the seeded mode stands in, and is seeded on the
    // way in if it is gone.
    expect(saved.selectedMode.id, seededChModeId);
    expect(saved.customModes, const [seededChMode]);
  });

  testWidgets('Save keeps a custom selection across a region change',
      (tester) async {
    const tour30 =
        CustomMode(id: 'c1', name: 'Tour 30', limitKmh: 30, throttle: true);
    final container = ProviderContainer();
    container.listen(bikeProvider(id), (previous, next) {});
    final bike = BikeState.defaultState(id)
        .copyWith(region: BikeRegion.us, customModes: const [tour30])
        .withSelectedMode(tour30.id);
    container
        .read(bikeProvider(id).notifier)
        .writeStateData(bike, saveToBike: false);
    await tester.pump();

    await openSheet(tester, container, container.read(bikeProvider(id)));
    await selectRegion(tester, 'US', 'EU');
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = container.read(bikeProvider(id));
    // Before the expects: the notifier's poll timer has to be cancelled while
    // the widget tree is still up, or the test framework fails on it instead.
    container.dispose();
    expect(saved.region, BikeRegion.eu);
    expect(saved.selectedMode.id, tour30.id,
        reason: 'a custom mode means the same thing in every region');
    expect(saved.needsSpeedSwitching, isTrue);
  });

  testWidgets('Save carries the auto-reconnect checkbox', (tester) async {
    final container = ProviderContainer();
    container.listen(bikeProvider(id), (previous, next) {});
    // Off-road: a static selection, so the setting takes full effect and the
    // sheet shows no override note.
    await openFromBikePage(tester, container,
        BikeState.defaultState(id).withSelectedMode(nativeModeId(chWireOffroad)));

    await tapAutoReconnect(tester);
    expect(renderedAutoReconnect(tester), isFalse,
        reason: 'the tap has to land on the box the rider is looking at');
    expect(find.byKey(const ValueKey('autoReconnectWarning')), findsNothing,
        reason: 'nothing overrides the setting for a static mode');

    await tapSave(tester);

    final saved = container.read(bikeProvider(id));
    // Before the expects: the notifier's poll timer has to be cancelled while
    // the widget tree is still up, or the test framework fails on it instead.
    container.dispose();
    expect(saved.autoReconnect, isFalse,
        reason: 'what the rider unchecked is what gets saved');
  });

  testWidgets('the sheet warns that a dynamic mode keeps reconnecting',
      (tester) async {
    final container = ProviderContainer();
    container.listen(bikeProvider(id), (previous, next) {});
    // A fresh CH bike rides the seeded 25 km/h mode, which switches by speed.
    await openFromBikePage(tester, container, BikeState.defaultState(id));
    final warning = find.byKey(const ValueKey('autoReconnectWarning'));
    expect(warning, findsNothing,
        reason: 'nothing to warn about while the setting is still on');
    // The caption says what the setting costs the rider, and nothing else.
    expect(
        find.text('The app runs in the background and connects to the bike '
            'whenever possible. This can use more battery.'),
        findsOneWidget);

    await tapAutoReconnect(tester);
    expect(renderedAutoReconnect(tester), isFalse);
    expect(warning, findsOneWidget,
        reason: 'the rider has to be told the setting does not fully apply');
    final warningText = tester.widget<Text>(
        find.descendant(of: warning, matching: find.byType(Text)));
    expect(
        warningText.data,
        'A dynamic mode is selected, so the app still reconnects for it '
        'after a drop.');

    // The box and the note are one thing, not two that can drift apart: a
    // second tap puts the setting back and takes the note with it.
    await tapAutoReconnect(tester);
    expect(renderedAutoReconnect(tester), isTrue);
    expect(warning, findsNothing);

    await tapAutoReconnect(tester);
    expect(renderedAutoReconnect(tester), isFalse);
    expect(warning, findsOneWidget);

    await tapSave(tester);
    final saved = container.read(bikeProvider(id));
    container.dispose();
    expect(saved.autoReconnect, isFalse);
  });

  testWidgets('the create sheet leaves nothing behind when it is dismissed',
      (tester) async {
    // The debug page opens the sheet on a bike nothing has persisted. Merely
    // looking at it must not create one: the notifier connects, polls and saves
    // what it reads, so touching the provider before Save leaves a bike the
    // rider never made.
    final container = ProviderContainer();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: DebugPage()),
    ));
    await tester.pump();

    await tester.tap(find.text('Create fake bike'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('autoReconnectCheckbox')), findsOneWidget,
        reason: 'the sheet is open on the new bike');

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    // Long enough for a connect, a poll (5 s) and its debounce (2 s) to have
    // written anything they were going to write.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 2));
    }

    final stored = container.read(bikesDBProvider);
    container.dispose();
    expect(stored, isEmpty, reason: 'a dismissed create sheet saves no bike');
  });

  testWidgets('Save keeps a handlebar change made while the sheet was open',
      (tester) async {
    final container = ProviderContainer();
    container.listen(bikeProvider(id), (previous, next) {});
    container
        .read(bikeProvider(id).notifier)
        .writeStateData(BikeState.defaultState(id), saveToBike: false);
    await tester.pump();

    // The sheet opens on the bike as it is now — assist 0, light off.
    await openSheet(tester, container, container.read(bikeProvider(id)));
    // ...and while it sits open, a poll brings in what the rider did on the
    // handlebar.
    final notifier = container.read(bikeProvider(id).notifier);
    notifier.writeStateData(
        container.read(bikeProvider(id)).copyWith(assist: 3, light: true),
        saveToBike: false);
    await tester.pump();

    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved = container.read(bikeProvider(id));
    container.dispose();
    expect(saved.assist, 3,
        reason: 'Save assembles onto the live bike, not onto the snapshot');
    expect(saved.light, isTrue);
  });

  group('the setup row', () {
    testWidgets('reads "Not set up yet" for a bike with no capabilities',
        (tester) async {
      final container = ProviderContainer();
      await openFromBikePage(
          tester, container, BikeState.defaultState(id).copyWith(
              capabilities: null, bootSignature: null));

      final row = find.byKey(const ValueKey('calibrateRow'));
      await tester.ensureVisible(row);
      expect(find.text('Set up this bike again'), findsOneWidget,
          reason: 'renamed from the old one-boot guide\'s title');
      expect(find.text('Not set up yet'), findsOneWidget);
      container.dispose();
    });

    testWidgets('reads the measured date for a bike with capabilities',
        (tester) async {
      final container = ProviderContainer();
      await openFromBikePage(
          tester,
          container,
          BikeState.defaultState(id).copyWith(
              capabilities: BikeCapabilities(
                  measuredAt: DateTime(2026, 8, 13),
                  acceptedWires: const [4, 5, 6, 7],
                  acceptedAssist: const [0, 1, 2, 3, 4],
                  lightWritable: true)));

      final row = find.byKey(const ValueKey('calibrateRow'));
      await tester.ensureVisible(row);
      expect(find.text('Set up 2026-08-13'), findsOneWidget,
          reason: 'reads BikeState.capabilities, not bootSignature');
      container.dispose();
    });

    testWidgets('tapping the row pushes the setup wizard', (tester) async {
      final container = ProviderContainer();
      await openFromBikePage(tester, container, BikeState.defaultState(id));

      final row = find.byKey(const ValueKey('calibrateRow'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('setupTitle')), findsOneWidget,
          reason: 'the row now opens SetupPage, not the old CalibrationPage');
      container.dispose();
    });
  });

  group('customModeNameFor', () {
    test('reads mph on a US bike', () {
      // 30 km/h is 18.64 mph, rounded to 19.
      expect(customModeNameFor(30, BikeRegion.us), '19 mph');
    });

    test('reads km/h on EU, CH and a legacy null region', () {
      // A null region has no bike behind it to call US, so it keeps the
      // metric storage unit — see the code comment on customModeNameFor.
      expect(customModeNameFor(30, BikeRegion.eu), '30 km/h');
      expect(customModeNameFor(30, BikeRegion.ch), '30 km/h');
      expect(customModeNameFor(30, null), '30 km/h');
    });
  });

  group('custom mode editor', () {
    const fast40 =
        CustomMode(id: 'c1', name: 'Fast', limitKmh: 40, throttle: false);

    /// A CH bike carrying [modes], selected on [modeId]. [region], when given,
    /// overrides the default CH region — the US/EU cases share this helper
    /// rather than a second one, so both paths build the bike the same way.
    /// [capabilities], when given, overrides the fake bike's seeded (fully
    /// writable) measurement — WP7's gate needs a bike proven to refuse a
    /// mode write.
    Future<ProviderContainer> openWith(WidgetTester tester,
        List<CustomMode> modes, String modeId,
        {BikeRegion? region, BikeCapabilities? capabilities}) async {
      final container = ProviderContainer();
      container.listen(bikeProvider(id), (previous, next) {});
      var bike = BikeState.defaultState(id).copyWith(customModes: modes);
      if (region != null) {
        bike = bike.copyWith(region: region);
      }
      if (capabilities != null) {
        bike = bike.copyWith(capabilities: capabilities);
      }
      container.read(bikeProvider(id).notifier).writeStateData(
          bike.withSelectedMode(modeId), saveToBike: false);
      await tester.pump();
      await openSheet(tester, container, container.read(bikeProvider(id)));
      return container;
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      final finder = find.byKey(ValueKey(key));
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    double sliderValue(WidgetTester tester) => tester
        .widget<Slider>(find.byKey(const ValueKey('customModeLimitSlider')))
        .value;

    /// The text the name field holds. Read from the controller, never through
    /// `find.text`: on a CH bike the auto name '25 km/h' is also the seeded
    /// tile's title, its delete tooltip and the slider readout, so a text
    /// finder proves nothing about the field.
    String nameFieldText(WidgetTester tester) => tester
        .widget<TextField>(find.descendant(
            of: find.byKey(const ValueKey('customModeNameField')),
            matching: find.byType(TextField)))
        .controller!
        .text;

    /// Raises the limit by [steps] km/h, one tap of the plus button each.
    Future<void> raiseLimit(WidgetTester tester, int steps) async {
      for (var i = 0; i < steps; i++) {
        await tapKey(tester, 'customModeLimitPlus');
      }
    }

    testWidgets('adding a mode opens the editor and lands a tile',
        (tester) async {
      final container = await openWith(
          tester, const [seededChMode], seededChModeId);

      await tapKey(tester, 'addCustomModeButton');
      expect(find.byKey(const ValueKey('customModeNameField')), findsOneWidget,
          reason: 'the editor opens on the new mode straight away');
      expect(sliderValue(tester), 25);

      await tester.enterText(
          find.byKey(const ValueKey('customModeNameField')), 'Tour 30');
      for (var i = 0; i < 5; i++) {
        await tapKey(tester, 'customModeLimitPlus');
      }
      await tapKey(tester, 'customModeEditorDone');

      container.dispose();
      expect(find.byKey(const ValueKey('customModeNameField')), findsNothing,
          reason: 'the editor closes on Done');
      expect(find.text('Tour 30'), findsOneWidget);
      expect(find.text('30 km/h'), findsOneWidget,
          reason: 'the tile names the limit the mode rides');
    });

    testWidgets('a cancelled add leaves no half-made mode behind',
        (tester) async {
      final container = await openWith(
          tester, const [seededChMode], seededChModeId);

      await tapKey(tester, 'addCustomModeButton');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      container.dispose();
      // The new mode carries the seeded mode's name, so counting the tiles is
      // the only proof left that the draft one is gone.
      expect(find.byTooltip('Delete 25 km/h'), findsOneWidget);
    });

    testWidgets('turning the throttle on keeps a limit above 32',
        (tester) async {
      // The 32 km/h throttle ceiling is gone: the mode rides an unlimited base
      // and the app holds the limit. The slider keeps the whole range.
      final container = await openWith(
          tester, const [seededChMode, fast40], seededChModeId);

      await tapKey(tester, 'customModeTile:${fast40.id}');
      expect(sliderValue(tester), 40);

      await tapKey(tester, 'customModeThrottleSwitch');

      final kept = sliderValue(tester);
      final slider = tester
          .widget<Slider>(find.byKey(const ValueKey('customModeLimitSlider')))
          .max;
      container.dispose();
      expect(kept, 40, reason: 'the throttle no longer takes the limit down');
      expect(slider, 45, reason: 'the ceiling is the same for every mode');
    });

    testWidgets('a throttle above 32 says the app holds the limit',
        (tester) async {
      final container = await openWith(
          tester, const [seededChMode, fast40], seededChModeId);

      await tapKey(tester, 'customModeTile:${fast40.id}');
      await tapKey(tester, 'customModeThrottleSwitch');

      final cost = find.text(
          'Above 32 km/h no firmware profile has both a throttle and a limit, '
          'so the bike rides OFFROAD below 40 km/h. This app holds the limit, '
          'not the bike: if Bluetooth drops while you ride below 40 km/h, the '
          'bike stays unlimited until the app reconnects. The app also needs '
          'live speed for the throttle. The bike sends no speed when it stands '
          'still, so the throttle does not work at a stop until you pedal '
          'away.');
      container.dispose();
      expect(cost, findsOneWidget,
          reason: 'the rider trades the dropout fail-safe for the throttle, '
              'and has to be told so');
    });

    testWidgets('the caption names the profile the switch just picked',
        (tester) async {
      // 32 km/h is an exact profile either way, and a different one each way:
      // the name has to be the one for the limit AND the throttle as they are
      // after the tap, not for the pair the sheet showed before it.
      const fast32 =
          CustomMode(id: 'c1', name: 'Fast', limitKmh: 32, throttle: false);
      final container =
          await openWith(tester, const [seededChMode, fast32], seededChModeId);

      await tapKey(tester, 'customModeTile:${fast32.id}');
      await tapKey(tester, 'customModeThrottleSwitch');

      expect(sliderValue(tester), 32);
      expect(
          find.text('Exactly matches the TOUR firmware profile — the bike '
              'enforces this limit itself, no app needed.'),
          findsOneWidget,
          reason: '32 km/h WITH a throttle is TOUR, not the throttle-less ECO');

      // And back: the same 32 km/h without a throttle is ECO. The caption
      // answers for the switch as it is, in the frame the switch moved in —
      // so ECO here is proof of a switch that is off, not of a stale lookup.
      await tapKey(tester, 'customModeThrottleSwitch');
      final eco = find.text('Exactly matches the ECO firmware profile — the '
          'bike enforces this limit itself, no app needed.');
      container.dispose();
      expect(eco, findsOneWidget);
    });

    testWidgets('the dropout caption follows the limit', (tester) async {
      final container = await openWith(
          tester, const [seededChMode, fast40], seededChModeId);

      await tapKey(tester, 'customModeTile:${fast40.id}');
      expect(
          find.text('If Bluetooth drops while riding below 40 km/h, the bike '
              'stays capped at 45 km/h until the app reconnects.'),
          findsOneWidget);

      // 45 km/h is MODE 3 exactly on this CH bike: one profile does the whole
      // job, and it is the EU bank's, not the US SPORT that caps at 45 too.
      for (var i = 0; i < 5; i++) {
        await tapKey(tester, 'customModeLimitPlus');
      }

      final exact = find.text(
          'Exactly matches the MODE 3 firmware profile — the bike enforces '
          'this limit itself, no app needed.');
      container.dispose();
      expect(exact, findsOneWidget);
    });

    testWidgets('a stored limit above the slider range opens clamped',
        (tester) async {
      // Hand-edited json, or a file from a build with a wider range: the tile
      // and the slider both show the limit the engine actually enforces.
      const overLimit =
          CustomMode(id: 'c9', name: 'Legacy', limitKmh: 60, throttle: true);
      final container = await openWith(
          tester, const [seededChMode, overLimit], seededChModeId);

      expect(find.text('45 km/h · throttle'), findsOneWidget,
          reason: 'the tile shows the limit the bike actually rides');

      await tapKey(tester, 'customModeTile:${overLimit.id}');

      final opened = sliderValue(tester);
      container.dispose();
      expect(opened, 45);
    });

    testWidgets('deleting a mode nobody is on asks nothing', (tester) async {
      final container = await openWith(
          tester, const [seededChMode, fast40], seededChModeId);

      final delete = find.byTooltip('Delete Fast');
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();

      container.dispose();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(ValueKey('customModeTile:${fast40.id}')), findsNothing);
    });

    testWidgets('deleting the selected mode names what replaces it',
        (tester) async {
      final container =
          await openWith(tester, const [seededChMode, fast40], fast40.id);

      final delete = find.byTooltip('Delete Fast');
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();

      expect(
          find.text('Fast is the selected mode. After saving, the bike will '
              'switch to 25 km/h.'),
          findsOneWidget);

      // Not find.text('Delete'): the sheet's own delete-bike button carries the
      // same label.
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Delete')));
      await tester.pumpAndSettle();

      // The delete only reaches the bike on Save.
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(bikeProvider(id));
      container.dispose();
      expect(saved.customModes, const [seededChMode]);
      expect(saved.selectedMode.id, seededChModeId);
    });

    /// A sheet over an arbitrary bike, so a test can start in any region.
    Future<ProviderContainer> openBike(
        WidgetTester tester, BikeState bike) async {
      final container = ProviderContainer();
      container.listen(bikeProvider(id), (previous, next) {});
      container
          .read(bikeProvider(id).notifier)
          .writeStateData(bike, saveToBike: false);
      await tester.pump();
      await openSheet(tester, container, container.read(bikeProvider(id)));
      return container;
    }

    /// Deletes [modeName] and returns the sentence the dialog showed, having
    /// confirmed it.
    Future<String> deleteAndConfirm(
        WidgetTester tester, String modeName) async {
      final delete = find.byTooltip('Delete $modeName');
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      final sentence = tester
          .widget<Text>(find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('is the selected mode')))
          .data!;
      // Not find.text('Delete'): the sheet's own delete-bike button carries the
      // same label.
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Delete')));
      await tester.pumpAndSettle();
      return sentence;
    }

    const alpha =
        CustomMode(id: 'c1', name: 'Alpha', limitKmh: 30, throttle: true);
    const bravo =
        CustomMode(id: 'c2', name: 'Bravo', limitKmh: 28, throttle: false);

    // The dialog may not answer on its own what Save is going to do. Save
    // resolves a selection the region dropdown invalidated in the OLD region
    // first and remaps the result; a dialog that computes its own fallback out
    // of the draft names a mode the rider never lands on.
    testWidgets('the delete dialog names what Save does, US to CH',
        (tester) async {
      final container = await openBike(
          tester,
          BikeState.defaultState(id)
              .copyWith(
                  region: BikeRegion.us, customModes: const [alpha, bravo])
              .withSelectedMode(alpha.id));

      await selectRegion(tester, 'US', 'CH');
      final sentence = await deleteAndConfirm(tester, 'Alpha');

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(bikeProvider(id));
      container.dispose();
      expect(saved.selectedMode.id, seededChModeId,
          reason: 'a US native going into CH lands on the built-in mode');
      expect(
          sentence,
          'Alpha is the selected mode. After saving, the bike will switch to '
          '${saved.selectedMode.name}.');
    });

    testWidgets('the delete dialog names what Save does, CH to US',
        (tester) async {
      final container = await openBike(
          tester,
          BikeState.defaultState(id)
              .copyWith(customModes: const [alpha, bravo])
              .withSelectedMode(alpha.id));

      await selectRegion(tester, 'CH', 'US');
      final sentence = await deleteAndConfirm(tester, 'Alpha');

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(bikeProvider(id));
      container.dispose();
      expect(saved.selectedMode.id, bravo.id,
          reason: 'the CH fallback is the first remaining custom mode, and a '
              'custom mode means the same thing in the US bank');
      expect(
          sentence,
          'Alpha is the selected mode. After saving, the bike will switch to '
          '${saved.selectedMode.name}.');
    });

    testWidgets('deleting the last custom mode of a CH bike is explained',
        (tester) async {
      // Not the seeded one, and nobody is on it: the re-seed would otherwise
      // silently swap the mode for one with another name.
      final container = await openWith(
          tester, const [fast40], nativeModeId(chWireOffroad));

      final delete = find.byTooltip('Delete Fast');
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();

      expect(
          find.text('Fast is the last custom mode. Switzerland has no limited '
              'firmware mode, so after saving the built-in 25 km/h mode takes '
              'its place.'),
          findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      container.dispose();
      expect(find.byKey(ValueKey('customModeTile:${fast40.id}')),
          findsOneWidget,
          reason: 'a cancelled dialog keeps the mode');
    });

    testWidgets('deleting the built-in mode of a fresh CH bike is refused',
        (tester) async {
      final container = await openWith(
          tester, const [seededChMode], seededChModeId);

      final delete = find.byTooltip('Delete 25 km/h');
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();

      expect(
          find.text('This is the built-in 25 km/h mode — deleting it just '
              'recreates it.'),
          findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      container.dispose();
      expect(find.byKey(const ValueKey('customModeTile:$seededChModeId')),
          findsOneWidget);
    });

    testWidgets('Save persists an edited mode', (tester) async {
      final container = await openWith(
          tester, const [seededChMode, fast40], seededChModeId);

      await tapKey(tester, 'customModeTile:${fast40.id}');
      await tester.enterText(
          find.byKey(const ValueKey('customModeNameField')), 'Tour 38');
      await tapKey(tester, 'customModeThrottleSwitch');
      for (var i = 0; i < 2; i++) {
        await tapKey(tester, 'customModeLimitMinus');
      }
      await tapKey(tester, 'customModeEditorDone');

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(bikeProvider(id));
      container.dispose();
      expect(saved.customModes, const [
        seededChMode,
        CustomMode(id: 'c1', name: 'Tour 38', limitKmh: 38, throttle: true)
      ]);
    });

    testWidgets('the reconnect note follows the draft selection',
        (tester) async {
      // Race 45 is an exact firmware match: nothing switches, so the setting
      // takes full effect and there is nothing to note.
      const race45 =
          CustomMode(id: 'c2', name: 'Race 45', limitKmh: 45, throttle: false);
      final container =
          await openWith(tester, const [race45, seededChMode], race45.id);

      await tapKey(tester, 'autoReconnectCheckbox');
      expect(find.byKey(const ValueKey('autoReconnectWarning')), findsNothing);

      // Deleting it hands the bike the seeded mode, which does switch — the
      // note has to follow what Save is about to do, not what the sheet found.
      final delete = find.byTooltip('Delete Race 45');
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Delete')));
      await tester.pumpAndSettle();

      final warning = find.byKey(const ValueKey('autoReconnectWarning'));
      container.dispose();
      expect(warning, findsOneWidget);
    });

    testWidgets('the create flow saves a bike that never existed',
        (tester) async {
      // What the debug page does: the sheet is opened on a state nothing has
      // persisted yet, so Save has to create the record, custom modes and all.
      const newId = 'fa:ke:11:22:33:44';
      final container = ProviderContainer();
      // A widget test runs on fake time, so the real bikes.json read never
      // lands. Marked loaded by hand: while it is not, [BikesDB] holds every
      // save back and Save could not create the record.
      container.read(bikesDBProvider.notifier).debugMarkLoaded();
      container.listen(bikeProvider(newId), (previous, next) {});
      await openSheet(tester, container, BikeState.defaultState(newId));

      await tapKey(tester, 'addCustomModeButton');
      await tester.enterText(
          find.byKey(const ValueKey('customModeNameField')), 'Tour 30');
      for (var i = 0; i < 5; i++) {
        await tapKey(tester, 'customModeLimitPlus');
      }
      await tapKey(tester, 'customModeEditorDone');

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final saved = container.read(bikeProvider(newId));
      final stored = container.read(bikesDBProvider);
      container.dispose();
      expect(saved.customModes.last.name, 'Tour 30');
      expect(saved.customModes.last.limitKmh, 30);
      expect(saved.selectedMode.id, seededChModeId,
          reason: 'a fresh CH bike still rides its seeded mode');
      expect(stored.map((b) => b.id), contains(newId));
    });

    testWidgets('an empty name keeps the editor open', (tester) async {
      final container = await openWith(
          tester, const [seededChMode, fast40], seededChModeId);

      await tapKey(tester, 'customModeTile:${fast40.id}');
      await tester.enterText(
          find.byKey(const ValueKey('customModeNameField')), '   ');
      await tapKey(tester, 'customModeEditorDone');

      final field = find.byKey(const ValueKey('customModeNameField'));
      container.dispose();
      expect(field, findsOneWidget);
    });

    // A new mode used to open as 'Custom', so two of them said nothing about
    // what they do. It now follows its limit until the rider types a name.
    group('auto name', () {
      testWidgets('a new mode opens named after its limit', (tester) async {
        final container =
            await openWith(tester, const [seededChMode], seededChModeId);

        await tapKey(tester, 'addCustomModeButton');

        final opened = nameFieldText(tester);
        container.dispose();
        expect(opened, '25 km/h',
            reason: 'the name says the speed, not the word Custom');
      });

      testWidgets('the name follows the slider', (tester) async {
        final container =
            await openWith(tester, const [seededChMode], seededChModeId);

        await tapKey(tester, 'addCustomModeButton');
        await raiseLimit(tester, 5);

        final followed = nameFieldText(tester);
        container.dispose();
        expect(followed, '30 km/h');
      });

      testWidgets('a typed name stops the slider from renaming it',
          (tester) async {
        final container =
            await openWith(tester, const [seededChMode], seededChModeId);

        await tapKey(tester, 'addCustomModeButton');
        await tester.enterText(
            find.byKey(const ValueKey('customModeNameField')), 'Trail');
        await raiseLimit(tester, 10);

        final kept = nameFieldText(tester);
        final limit = sliderValue(tester);
        container.dispose();
        expect(limit, 35, reason: 'the slider still moves');
        expect(kept, 'Trail', reason: 'the name belongs to the rider now');
      });

      testWidgets('clearing the name brings the auto name back', (tester) async {
        final container =
            await openWith(tester, const [seededChMode], seededChModeId);

        await tapKey(tester, 'addCustomModeButton');
        await tester.enterText(
            find.byKey(const ValueKey('customModeNameField')), 'Trail');
        await tester.enterText(
            find.byKey(const ValueKey('customModeNameField')), '');
        await raiseLimit(tester, 5);

        expect(nameFieldText(tester), '30 km/h',
            reason: 'an empty name is untouched again');
        expect(find.text('Required'), findsNothing,
            reason: 'the rider never sees the validator for a name the app '
                'fills in itself');

        // And the mode saves: the refilled name passes the validator, so the
        // editor closes on Done.
        await tapKey(tester, 'customModeEditorDone');

        final field = find.byKey(const ValueKey('customModeNameField'));
        container.dispose();
        expect(field, findsNothing);
      });

      testWidgets('an existing mode keeps its name', (tester) async {
        // Auto-naming is for new modes only: a name the rider gave a mode
        // survives every later edit of its limit.
        const trail = CustomMode(
            id: 'c1', name: 'Trail', limitKmh: 30, throttle: false);
        final container =
            await openWith(tester, const [seededChMode, trail], seededChModeId);

        await tapKey(tester, 'customModeTile:${trail.id}');
        await raiseLimit(tester, 5);

        final kept = nameFieldText(tester);
        final limit = sliderValue(tester);
        container.dispose();
        expect(limit, 35);
        expect(kept, 'Trail');
      });
    });

    // The one inconsistency WP1 left: a US bike's default modes read in mph,
    // but a custom mode still read km/h. These guard the editor's US branch
    // and the EU/CH path it must not disturb.
    group('mph on a US bike', () {
      testWidgets('the slider bounds and label read mph', (tester) async {
        final container = await openWith(tester, const [fast40], fast40.id,
            region: BikeRegion.us);

        await tapKey(tester, 'customModeTile:${fast40.id}');
        final slider = tester.widget<Slider>(
            find.byKey(const ValueKey('customModeLimitSlider')));

        container.dispose();
        // 25/45 km/h round to 16/28 mph; 40 km/h rounds to 25 mph.
        expect(slider.min, 16);
        expect(slider.max, 28);
        expect(slider.divisions, 12);
        expect(slider.value, 25);
        expect(slider.label, '25 mph');
      });

      testWidgets('the trailing readout reads mph', (tester) async {
        final container = await openWith(tester, const [fast40], fast40.id,
            region: BikeRegion.us);

        await tapKey(tester, 'customModeTile:${fast40.id}');
        final readout = find.text('25 mph');

        container.dispose();
        expect(readout, findsWidgets,
            reason: 'both the tile subtitle and the editor readout say so');
      });

      testWidgets('the +/- buttons step by one mph, not one km/h',
          (tester) async {
        final container = await openWith(tester, const [fast40], fast40.id,
            region: BikeRegion.us);

        await tapKey(tester, 'customModeTile:${fast40.id}');
        expect(sliderValue(tester), 25);

        await tapKey(tester, 'customModeLimitPlus');
        expect(sliderValue(tester), 26);

        await tapKey(tester, 'customModeLimitMinus');
        await tapKey(tester, 'customModeLimitMinus');
        final result = sliderValue(tester);
        container.dispose();
        expect(result, 24);
      });

      testWidgets('a slider position stores its km/h equivalent',
          (tester) async {
        final container = await openWith(tester, const [fast40], fast40.id,
            region: BikeRegion.us);

        await tapKey(tester, 'customModeTile:${fast40.id}');
        // 25 mph -> 23 mph.
        await tapKey(tester, 'customModeLimitMinus');
        await tapKey(tester, 'customModeLimitMinus');
        expect(sliderValue(tester), 23);
        await tapKey(tester, 'customModeEditorDone');

        await tester.ensureVisible(find.text('Save'));
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        final saved = container.read(bikeProvider(id));
        container.dispose();
        // 23 mph rounds to 37 km/h, not a straight unit swap.
        expect(saved.customModes.single.limitKmh, 37);
      });

      testWidgets('the name follows the slider in mph', (tester) async {
        final container = await openWith(
            tester, const [], nativeModeId(0),
            region: BikeRegion.us);

        await tapKey(tester, 'addCustomModeButton');
        // 25 km/h -> 16 mph, the mode's opening limit.
        expect(nameFieldText(tester), '16 mph');

        // Each plus tap steps the DISPLAY by one mph, so 5 taps land on
        // 16 + 5 = 21 mph (34 km/h stored) — not the 30 km/h a km/h-mode
        // custom mode would land on for the same 5 taps.
        await raiseLimit(tester, 5);
        final followed = nameFieldText(tester);
        container.dispose();
        expect(followed, '21 mph');
      });

      testWidgets('the tile subtitle reads mph', (tester) async {
        final container = await openWith(tester, const [fast40], fast40.id,
            region: BikeRegion.us);

        final subtitle = find.text('25 mph');
        container.dispose();
        expect(subtitle, findsOneWidget,
            reason: 'no editor is open, so only the tile shows the limit');
      });
    });

    group('km/h unchanged outside the US', () {
      testWidgets('the editor still shows km/h on an EU bike', (tester) async {
        final container = await openWith(tester, const [fast40], fast40.id,
            region: BikeRegion.eu);

        await tapKey(tester, 'customModeTile:${fast40.id}');
        final slider = tester.widget<Slider>(
            find.byKey(const ValueKey('customModeLimitSlider')));

        container.dispose();
        expect(slider.min, 25);
        expect(slider.max, 45);
        expect(slider.divisions, 20);
        expect(slider.value, 40);
        expect(slider.label, '40 km/h');
      });

      testWidgets('the tile subtitle stays km/h on a CH bike', (tester) async {
        final container = await openWith(
            tester, const [seededChMode, fast40], seededChModeId);

        final subtitle = find.text('40 km/h');
        container.dispose();
        expect(subtitle, findsOneWidget);
      });
    });

    group('capability gating', () {
      BikeCapabilities caps({List<int> acceptedWires = const [
        0, 1, 2, 3, 4, 5, 6, 7
      ]}) =>
          BikeCapabilities(
            measuredAt: DateTime(2024),
            acceptedWires: acceptedWires,
            acceptedAssist: const [0, 1, 2, 3, 4],
            lightWritable: true,
          );

      testWidgets(
          'a bike that refuses the mode hides the custom-mode section and '
          'says why', (tester) async {
        final container = await openWith(
            tester, const [seededChMode], seededChModeId,
            capabilities: caps(acceptedWires: const [4]));

        container.dispose();
        expect(find.text('Custom Modes'), findsNothing);
        expect(find.byKey(const ValueKey('addCustomModeButton')), findsNothing);
        expect(find.byKey(ValueKey('customModeTile:$seededChModeId')),
            findsNothing);
        expect(
            find.byKey(const ValueKey('customModesDisabledNote')),
            findsOneWidget);
        expect(
            find.text('This bike does not let the app change the mode, so '
                'custom modes have no effect here.'),
            findsOneWidget);
      });

      testWidgets('a bike that accepts the mode shows the section as always',
          (tester) async {
        final container = await openWith(
            tester, const [seededChMode], seededChModeId,
            capabilities: caps());

        container.dispose();
        expect(find.text('Custom Modes'), findsOneWidget);
        expect(
            find.byKey(const ValueKey('addCustomModeButton')), findsOneWidget);
        expect(find.byKey(ValueKey('customModeTile:$seededChModeId')),
            findsOneWidget);
        expect(find.byKey(const ValueKey('customModesDisabledNote')),
            findsNothing);
      });
    });
  });
}

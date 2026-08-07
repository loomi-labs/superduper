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

    await tapAutoReconnect(tester);
    expect(renderedAutoReconnect(tester), isFalse);
    expect(warning, findsOneWidget,
        reason: 'the rider has to be told the setting does not fully apply');

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

  group('custom mode editor', () {
    const fast40 =
        CustomMode(id: 'c1', name: 'Fast', limitKmh: 40, throttle: false);

    /// A CH bike carrying [modes], selected on [modeId].
    Future<ProviderContainer> openWith(WidgetTester tester,
        List<CustomMode> modes, String modeId) async {
      final container = ProviderContainer();
      container.listen(bikeProvider(id), (previous, next) {});
      container.read(bikeProvider(id).notifier).writeStateData(
          BikeState.defaultState(id)
              .copyWith(customModes: modes)
              .withSelectedMode(modeId),
          saveToBike: false);
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
      expect(find.text('Custom'), findsNothing);
    });

    testWidgets('turning the throttle on clamps the limit to 32',
        (tester) async {
      final container = await openWith(
          tester, const [seededChMode, fast40], seededChModeId);

      await tapKey(tester, 'customModeTile:${fast40.id}');
      expect(sliderValue(tester), 40);
      expect(find.byKey(const ValueKey('customModeThrottleCaption')),
          findsNothing);

      await tapKey(tester, 'customModeThrottleSwitch');

      final clamped = sliderValue(tester);
      final caption = find.byKey(const ValueKey('customModeThrottleCaption'));
      container.dispose();
      expect(clamped, 32,
          reason: 'above 32 km/h every profile with a throttle is unlimited');
      expect(caption, findsOneWidget);
    });

    testWidgets('the caption names the profile the switch just picked',
        (tester) async {
      // 37 km/h has no exact profile; the throttle clamps it to 32, which does
      // — and the name has to be the one for the limit AND the throttle as they
      // are after the tap, not for the pair the sheet showed before it.
      const fast37 =
          CustomMode(id: 'c1', name: 'Fast', limitKmh: 37, throttle: false);
      final container =
          await openWith(tester, const [seededChMode, fast37], seededChModeId);

      await tapKey(tester, 'customModeTile:${fast37.id}');
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

      // 45 km/h is SPORT exactly: one profile does the whole job.
      for (var i = 0; i < 5; i++) {
        await tapKey(tester, 'customModeLimitPlus');
      }

      final exact = find.text(
          'Exactly matches the SPORT firmware profile — the bike enforces '
          'this limit itself, no app needed.');
      container.dispose();
      expect(exact, findsOneWidget);
    });

    testWidgets('a stored limit above what the mode rides opens clamped',
        (tester) async {
      // Hand-edited json: 40 km/h with a throttle is a limit no profile holds,
      // and the engine rides 32.
      const overLimit =
          CustomMode(id: 'c9', name: 'Legacy', limitKmh: 40, throttle: true);
      final container = await openWith(
          tester, const [seededChMode, overLimit], seededChModeId);

      expect(find.text('32 km/h · throttle'), findsOneWidget,
          reason: 'the tile shows the limit the bike actually rides');

      await tapKey(tester, 'customModeTile:${overLimit.id}');

      final opened = sliderValue(tester);
      container.dispose();
      expect(opened, 32);
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
          find.byKey(const ValueKey('customModeNameField')), 'Tour 30');
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
        CustomMode(id: 'c1', name: 'Tour 30', limitKmh: 30, throttle: true)
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
  });
}

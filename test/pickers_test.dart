import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/theme.dart';
import 'package:superduper/widgets.dart';

/// A switching custom mode: base wire 1 (32 km/h + throttle), cap wire 4.
const tour30 =
    CustomMode(id: 'c1', name: 'Tour 30', limitKmh: 30, throttle: true);

/// An exact firmware match (US Class 3, wire 2): base == cap, never switches.
const sport45 = CustomMode(id: 'c2', name: 'Sport 45', limitKmh: 45);

/// The mode and assist pickers, driven the way a rider drives them: taps on
/// chips, checked against the byte the fake bike ends up holding.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'fa:ke:aa:bb:cc:dd';

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_picker_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  int bikeWire(ProviderContainer container) =>
      container.read(fakeBikeStoreProvider).read(id)[5];

  int bikeAssist(ProviderContainer container) =>
      container.read(fakeBikeStoreProvider).read(id)[2];

  int bikeLight(ProviderContainer container) =>
      container.read(fakeBikeStoreProvider).read(id)[4];

  /// Lets the write chain (microtasks, db saves) run out. Deliberately does not
  /// advance the clock, so the 2 s debounce and the 5 s poll never fire and
  /// every write a test sees was caused by the test.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump();
    }
  }

  /// Opens a bike the way the app does, then pumps the control card for it.
  /// The card is rebuilt from the provider, so a tap's result shows up in the
  /// chips rather than in a snapshot taken before it.
  Future<ProviderContainer> pumpControl(
    WidgetTester tester, {
    required BikeState bike,
    required Widget Function(BikeState) build,
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
            builder: (context, ref, child) => build(ref.watch(bikeProvider(id))),
          ),
        ),
      ),
    ));
    await tester.pump();
    return container;
  }

  /// The label a chip is showing.
  String chipLabel(WidgetTester tester, String keyValue) => tester
      .widget<Text>(find.descendant(
        of: find.byKey(ValueKey(keyValue)),
        matching: find.byType(Text),
      ))
      .data!;

  /// Whether a chip renders as the selected one — the bold label the filled
  /// pill carries.
  bool chipSelected(WidgetTester tester, String keyValue) =>
      tester
          .widget<Text>(find.descendant(
            of: find.byKey(ValueKey(keyValue)),
            matching: find.byType(Text),
          ))
          .style
          ?.fontWeight ==
      FontWeight.bold;

  List<SelectorChip> chips(WidgetTester tester) =>
      tester.widgetList<SelectorChip>(find.byType(SelectorChip)).toList();

  testWidgets('the mode card shows one chip per selectable mode',
      (tester) async {
    final container = await pumpControl(
      tester,
      bike: BikeState.defaultState(id)
          .copyWith(region: BikeRegion.us, customModes: const [tour30, sport45])
          .withSelectedMode(tour30.id),
      build: (bike) => EnhancedModeControlWidget(bike: bike),
    );

    // US: four native modes, then the bike's own two.
    expect(find.byType(SelectorChip), findsNWidgets(6));
    expect(chipLabel(tester, 'modeChip:${nativeModeId(0)}'), 'ECO');
    expect(chipLabel(tester, 'modeChip:${tour30.id}'), 'Tour 30');
    expect(chipLabel(tester, 'modeChip:${sport45.id}'), 'Sport 45');

    final selected = chips(tester).where((c) => c.item.selected).toList();
    // Before the expects: the notifier's poll timer has to be cancelled while
    // the widget tree is still up, or the test framework fails on it instead.
    container.dispose();
    expect(selected, hasLength(1));
    expect(selected.single.item.keyValue, 'modeChip:${tour30.id}');
    expect(selected.single.item.tooltip, 'Select mode Tour 30');
  });

  testWidgets('tapping a mode chip puts that mode on the wire', (tester) async {
    final container = await pumpControl(
      tester,
      bike: BikeState.defaultState(id)
          .copyWith(region: BikeRegion.us, customModes: const [tour30, sport45])
          .withSelectedMode(nativeModeId(0)),
      build: (bike) => EnhancedModeControlWidget(bike: bike),
    );
    expect(bikeWire(container), 0);

    await tester.tap(find.byKey(ValueKey('modeChip:${tour30.id}')));
    await settle(tester);

    final wire = bikeWire(container);
    final selected = container.read(bikeProvider(id)).selectedMode.id;
    final tappedIsSelected = chipSelected(tester, 'modeChip:${tour30.id}');
    final oldIsSelected = chipSelected(tester, 'modeChip:${nativeModeId(0)}');
    container.dispose();
    expect(selected, tour30.id);
    expect(wire, 1, reason: 'Tour 30 is entered on its base profile');
    expect(tappedIsSelected, isTrue);
    expect(oldIsSelected, isFalse);
  });

  testWidgets('a selection outside the selectable modes selects no chip',
      (tester) async {
    // A CH bike with no custom modes left: its selection resolves to the seeded
    // fallback, which lives in memory only and is not in [selectableModes].
    final container = await pumpControl(
      tester,
      bike: BikeState.defaultState(id)
          .copyWith(region: BikeRegion.ch, customModes: const [])
          .withSelectedMode(seededChModeId),
      build: (bike) => EnhancedModeControlWidget(bike: bike),
    );

    final state = container.read(bikeProvider(id));
    final rendered = chips(tester);
    container.dispose();
    expect(state.selectableModes.map((m) => m.id),
        isNot(contains(state.selectedMode.id)),
        reason: 'the test only means something while the selection dangles');
    expect(rendered, hasLength(1), reason: 'CH natives are off-road alone');
    expect(rendered.where((c) => c.item.selected), isEmpty);
  });

  testWidgets('the assist card shows the five levels', (tester) async {
    final container = await pumpControl(
      tester,
      bike: BikeState.defaultState(id).copyWith(assist: 2),
      build: (bike) => EnhancedAssistControlWidget(bike: bike),
    );

    final labels = chips(tester).map((c) => c.item.label).toList();
    final selected = chips(tester).where((c) => c.item.selected).toList();
    container.dispose();
    expect(labels, ['0', '1', '2', '3', '4']);
    expect(selected, hasLength(1));
    expect(selected.single.item.keyValue, 'assistChip:2');
    expect(selected.single.item.tooltip, 'Select assist 2');
  });

  testWidgets('tapping an assist chip writes that level to the bike',
      (tester) async {
    final container = await pumpControl(
      tester,
      bike: BikeState.defaultState(id)
          .withSelectedMode(nativeModeId(chWireOffroad)),
      build: (bike) => EnhancedAssistControlWidget(bike: bike),
    );
    // The rider turned the light on at the handlebar and the app has not polled
    // it yet: only the assist byte may come out of app state.
    container.read(fakeBikeStoreProvider).toggleLight(id);

    await tester.tap(find.byKey(const ValueKey('assistChip:3')));
    await settle(tester);

    final assist = bikeAssist(container);
    final light = bikeLight(container);
    final tappedIsSelected = chipSelected(tester, 'assistChip:3');
    container.dispose();
    expect(assist, 3);
    expect(light, 1,
        reason: 'the field the rider did not touch comes off the bike');
    expect(tappedIsSelected, isTrue);
  });

  testWidgets('a disconnected bike ignores assist taps', (tester) async {
    final container = await pumpControl(tester,
        bike: BikeState.defaultState(id).copyWith(assist: 1),
        build: (b) => EnhancedAssistControlWidget(bike: b));
    // ignore: invalid_use_of_protected_member
    container.read(connectionHandlerProvider(id).notifier).state =
        SDBluetoothConnectionState.disconnected;
    await settle(tester);

    await tester.tap(find.byKey(const ValueKey('assistChip:3')));
    await settle(tester);

    final assist = container.read(bikeProvider(id)).assist;
    final onWire = bikeAssist(container);
    container.dispose();
    expect(assist, 1,
        reason: 'an offline change cannot reach the bike; the control must '
            'not pretend it did');
    expect(onWire, isNot(3));
  });

  testWidgets('a disconnected bike ignores mode taps', (tester) async {
    final container = await pumpControl(tester,
        bike: BikeState.defaultState(id)
            .copyWith(region: BikeRegion.us, customModes: const [tour30, sport45])
            .withSelectedMode(sport45.id),
        build: (b) => EnhancedModeControlWidget(bike: b));
    // ignore: invalid_use_of_protected_member
    container.read(connectionHandlerProvider(id).notifier).state =
        SDBluetoothConnectionState.disconnected;
    await settle(tester);

    await tester.tap(find.byKey(ValueKey('modeChip:${tour30.id}')));
    await settle(tester);

    final selected = container.read(bikeProvider(id)).selectedMode.id;
    container.dispose();
    expect(selected, sport45.id);
  });

  testWidgets('a disconnected bike ignores light taps', (tester) async {
    final container = await pumpControl(tester,
        bike: BikeState.defaultState(id).copyWith(light: false),
        build: (b) => EnhancedLightControlWidget(bike: b));
    // ignore: invalid_use_of_protected_member
    container.read(connectionHandlerProvider(id).notifier).state =
        SDBluetoothConnectionState.disconnected;
    await settle(tester);

    await tester.tap(find.text('Light'));
    await settle(tester);

    final light = container.read(bikeProvider(id)).light;
    container.dispose();
    expect(light, isFalse);
  });

  /// How faded a card renders. A [ControlCard] dims itself from the inside, so
  /// the [Opacity] widgets are its descendants, not its ancestor: one around
  /// the header, and one more around the body when the card has one.
  List<double> cardOpacities(WidgetTester tester) => tester
      .widgetList<Opacity>(find.descendant(
        of: find.byType(ControlCard),
        matching: find.byType(Opacity),
      ))
      .map((o) => o.opacity)
      .toList();

  /// Proves the lock sits outside every dimmed part of the card. Scoped to the
  /// card's own [Opacity] widgets rather than searched upwards from the lock,
  /// because a route can put widgets of its own above the whole page.
  void expectLockOutsideDimming(WidgetTester tester) {
    final dimmed = find.descendant(
      of: find.byType(ControlCard),
      matching: find.byType(Opacity),
    );
    for (var i = 0; i < tester.widgetList<Opacity>(dimmed).length; i++) {
      expect(
          find.descendant(
              of: dimmed.at(i), matching: find.byType(EnhancedLockWidget)),
          findsNothing,
          reason: 'the lock must keep full contrast while the bike is away');
    }
  }

  testWidgets('a disconnected assist card is greyed out and inert',
      (tester) async {
    final container = await pumpControl(tester,
        bike: BikeState.defaultState(id).copyWith(assist: 1),
        build: (b) => EnhancedAssistControlWidget(bike: b));
    expect(cardOpacities(tester), everyElement(1.0),
        reason: 'a connected bike must render at full strength');

    // ignore: invalid_use_of_protected_member
    container.read(connectionHandlerProvider(id).notifier).state =
        SDBluetoothConnectionState.disconnected;
    await settle(tester);

    final opacities = cardOpacities(tester);
    final taps = chips(tester).map((c) => c.item.onTap).toList();
    expectLockOutsideDimming(tester);
    container.dispose();
    expect(opacities, isNotEmpty);
    expect(opacities, everyElement(0.5));
    expect(taps, everyElement(isNull),
        reason: 'a null onTap is what makes the chip inert');
  });

  testWidgets('a disconnected mode card is greyed out and inert',
      (tester) async {
    final container = await pumpControl(tester,
        bike: BikeState.defaultState(id)
            .copyWith(region: BikeRegion.us, customModes: const [tour30])
            .withSelectedMode(tour30.id),
        build: (b) => EnhancedModeControlWidget(bike: b));
    expect(cardOpacities(tester), everyElement(1.0),
        reason: 'a connected bike must render at full strength');

    // ignore: invalid_use_of_protected_member
    container.read(connectionHandlerProvider(id).notifier).state =
        SDBluetoothConnectionState.disconnected;
    await settle(tester);

    final opacities = cardOpacities(tester);
    final taps = chips(tester).map((c) => c.item.onTap).toList();
    expectLockOutsideDimming(tester);
    container.dispose();
    expect(opacities, isNotEmpty);
    expect(opacities, everyElement(0.5));
    expect(taps, everyElement(isNull));
  });

  testWidgets('a disconnected light card is greyed out and inert',
      (tester) async {
    final container = await pumpControl(tester,
        bike: BikeState.defaultState(id).copyWith(light: false),
        build: (b) => EnhancedLightControlWidget(bike: b));
    expect(cardOpacities(tester), everyElement(1.0),
        reason: 'a connected bike must render at full strength');

    // ignore: invalid_use_of_protected_member
    container.read(connectionHandlerProvider(id).notifier).state =
        SDBluetoothConnectionState.disconnected;
    await settle(tester);

    final opacities = cardOpacities(tester);
    final onTap = tester.widget<ControlCard>(find.byType(ControlCard)).onTap;
    // The lock button is app state and works offline, so it stays live.
    final lockOnTap =
        tester.widget<EnhancedLockWidget>(find.byType(EnhancedLockWidget)).onTap;
    expectLockOutsideDimming(tester);
    container.dispose();
    expect(opacities, isNotEmpty);
    expect(opacities, everyElement(0.5));
    expect(onTap, isNull);
    expect(lockOnTap, isNotNull);
  });

  testWidgets('a degraded padlock is marked and says why', (tester) async {
    // The padlock is on, but nothing can hold the value while the phone is in
    // a pocket. Pumped directly: which platform and which permission put it
    // there is [pinDegraded]'s job, and that is tested on its own.
    Future<Icon> pumpLock({required bool degraded}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EnhancedLockWidget(
            locked: true,
            degraded: degraded,
            onTap: () {},
            tooltip: 'Lock the mode',
          ),
        ),
      ));
      return tester.widget<Icon>(find.byType(Icon));
    }

    final plain = await pumpLock(degraded: false);
    expect(plain.color, SDSurface.text);
    expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip,
        'Lock the mode');

    final degraded = await pumpLock(degraded: true);
    expect(degraded.color, SDSurface.warning,
        reason: 'a padlock that cannot hold must not look like one that can');
    expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip,
        contains('only holds while the app is open'));
  });
}

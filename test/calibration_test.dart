import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/calibration_page.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/repository.dart';

/// The guided boot calibration: the pure classification, the guide itself
/// (stage, off, on, record, classify) and the two entries that start it.
///
/// The guide is driven exactly the way a rider drives it — buttons, and the
/// link going down and coming back — so a step that only works when a test
/// calls the notifier directly cannot pass here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'fa:ke:aa:bb:cc:dd';

  /// The window's reads, compressed: a widget test has to walk the whole flow,
  /// and the real schedule spends eight seconds doing it.
  const fastSchedule = <Duration>[
    Duration(milliseconds: 10),
    Duration(milliseconds: 20),
  ];

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_calibration_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// An EU bike on native mode 5, whose wire (5) is neither the EU boot wire
  /// (4) nor a wire any other step here writes.
  BikeState euBike() => BikeState.defaultState(id)
      .copyWith(region: BikeRegion.eu, customModes: const [])
      .withSelectedMode(nativeModeId(5));

  /// Opens the bike the way the app does: a listener on the provider, and the
  /// record saved through the notifier.
  Bike openBike(ProviderContainer container, [BikeState? bike]) {
    container.listen(bikeProvider(id), (previous, next) {});
    final notifier = container.read(bikeProvider(id).notifier);
    notifier.writeStateData(bike ?? euBike(), saveToBike: false);
    return notifier;
  }

  void setConnection(
      ProviderContainer container, SDBluetoothConnectionState next) {
    // ignore: invalid_use_of_protected_member
    container.read(connectionHandlerProvider(id).notifier).state = next;
  }

  /// Lets the flow's awaits and one round of timers run out. Deliberately
  /// short: the poll is 5 s away and must not fire between two steps.
  Future<void> pump(WidgetTester tester,
      [Duration duration = const Duration(milliseconds: 200)]) async {
    await tester.pump();
    await tester.pump(duration);
    await tester.pump();
  }

  /// Pushes the guide over an empty page, so its own pop has a route to land
  /// on — the way both entries reach it.
  Future<void> openGuide(
      WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    ));
    Navigator.of(tester.element(find.byType(SizedBox))).push(
        MaterialPageRoute<void>(
            builder: (_) =>
                const CalibrationPage(bikeID: id, schedule: fastSchedule)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await pump(tester);
  }

  int bikeAssist(ProviderContainer container) =>
      container.read(fakeBikeStoreProvider).read(id)[2];

  int bikeWire(ProviderContainer container) =>
      container.read(fakeBikeStoreProvider).read(id)[5];

  /// The bike comes up on the EU boot wire with assist 0, which is what the
  /// 2026-08-11 logs recorded.
  void bootBike(ProviderContainer container) {
    container
        .read(fakeBikeStoreProvider)
        .write(id, [0, 209, 0, 0, 4, 0, 0, 0, 0, 0]);
  }

  group('classifyBootSignature', () {
    final at = DateTime(2026, 8, 11);

    test('a byte that changed is the boot value', () {
      final signature = classifyBootSignature(
          preOff: (assist: 2, wire: 5),
          settled: (assist: 0, wire: 4),
          measuredAt: at);
      expect(signature.bootAssist, 0);
      expect(signature.bootWire, 4);
      expect(signature.preOffAssist, 2);
      expect(signature.preOffWire, 5);
      expect(signature.measuredAt, at);
    });

    test('a byte that came back unchanged is unusable', () {
      final signature = classifyBootSignature(
          preOff: (assist: 2, wire: 5),
          settled: (assist: 2, wire: 4),
          measuredAt: at);
      expect(signature.bootAssist, isNull,
          reason: 'the firmware kept it, so it carries no boot news');
      expect(signature.bootWire, 4);
    });

    test('both unchanged classifies both as unusable', () {
      final signature = classifyBootSignature(
          preOff: (assist: 2, wire: 5),
          settled: (assist: 2, wire: 5),
          measuredAt: at);
      expect(signature.bootAssist, isNull);
      expect(signature.bootWire, isNull);
      expect(signature.preOffWire, 5,
          reason: 'the staged values stay, so a later audit can read them');
    });
  });

  group('bootSignatureSummary', () {
    BootSignature signature({int? wire, int? assist}) => BootSignature(
        measuredAt: DateTime(2026, 8, 11),
        bootWire: wire,
        bootAssist: assist,
        preOffWire: 5,
        preOffAssist: 2);

    test('names both bytes when both reset', () {
      final text = bootSignatureSummary(signature(wire: 4, assist: 0));
      expect(text, contains('EPAC'));
      expect(text, contains('assist to 0'));
    });

    test('says which byte is kept when only one resets', () {
      expect(bootSignatureSummary(signature(wire: 4)),
          contains('keeps its assist'));
      expect(bootSignatureSummary(signature(assist: 0)),
          contains('keeps its mode'));
    });

    test('says plainly that a bike that keeps both cannot be detected', () {
      expect(bootSignatureSummary(signature()),
          contains('not possible on this bike'));
    });
  });

  group('the guide', () {
    testWidgets('stages, records the boot and saves the signature',
        (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await openGuide(tester, container);

      await tap(tester, 'calibrationStart');
      expect(bikeAssist(container), 2,
          reason: 'a pre-off state equal to the boot state cannot be measured');
      expect(bikeWire(container), 5, reason: 'and the selected mode\'s wire');
      expect(bike.debugCalibrating, isTrue,
          reason: 'the window opens once the staging write is on the bike');
      expect(find.text('Turn the bike off'), findsOneWidget);

      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      expect(find.text('Turn the bike on'), findsOneWidget);

      bootBike(container);
      setConnection(container, SDBluetoothConnectionState.connected);
      // Past the connect settle the re-assert holds, so the guide's own window
      // is the only thing that touched the bike in between.
      await pump(tester, const Duration(seconds: 2));

      final saved = container.read(bikeProvider(id)).bootSignature;
      expect(saved, isNotNull);
      expect(saved!.bootAssist, 0, reason: 'the boot reset the assist');
      expect(saved.bootWire, 4, reason: 'and the mode, to the EU boot wire');
      expect(saved.preOffAssist, 2);
      expect(saved.preOffWire, 5);
      expect(bike.debugCalibrating, isFalse,
          reason: 'the window must not stay open past the flow');
      expect(find.textContaining('resets its mode'), findsOneWidget);
      container.dispose();
    });

    testWidgets('a bike that keeps both bytes is saved as undetectable',
        (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await openGuide(tester, container);

      await tap(tester, 'calibrationStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      // Nothing touches the register: the bike comes back exactly as it was
      // staged, which is what a firmware that persists everything does.
      setConnection(container, SDBluetoothConnectionState.connected);
      await pump(tester, const Duration(seconds: 2));

      final saved = container.read(bikeProvider(id)).bootSignature;
      expect(saved, isNotNull, reason: 'a measurement of nothing is a result');
      expect(saved!.bootAssist, isNull);
      expect(saved.bootWire, isNull);
      expect(find.textContaining('not possible on this bike'), findsOneWidget);
      expect(bike.debugCalibrating, isFalse);
      container.dispose();
    });

    testWidgets('Later saves nothing and leaves the window closed',
        (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await openGuide(tester, container);

      await tap(tester, 'calibrationLater');
      await pump(tester, const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('calibrationStart')), findsNothing,
          reason: 'the guide is gone');
      expect(container.read(bikeProvider(id)).bootSignature, isNull);
      expect(bike.debugCalibrating, isFalse);
      expect(bikeAssist(container), 0,
          reason: 'a skipped guide never staged anything');
      container.dispose();
    });

    testWidgets('Cancel leaves no staged state and no window behind',
        (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await openGuide(tester, container);

      await tap(tester, 'calibrationStart');
      expect(bikeAssist(container), 2);

      await tap(tester, 'calibrationCancel');
      await pump(tester, const Duration(seconds: 1));

      expect(bike.debugCalibrating, isFalse,
          reason: 'a cancelled guide must not hold the writes off');
      expect(container.read(bikeProvider(id)).bootSignature, isNull,
          reason: 'nothing measured, nothing saved');
      expect(bikeAssist(container), 0,
          reason: 'the staged assist goes back where the rider had it');
      container.dispose();
    });
  });

  group('the entries', () {
    testWidgets('an uncalibrated bike offers the guide on its page',
        (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BikePage(bikeID: id)),
      ));
      await tester.pump(const Duration(seconds: 1));

      final prompt = find.byKey(const ValueKey('calibrationPrompt'));
      expect(prompt, findsOneWidget);

      await tester.ensureVisible(prompt);
      await tester.tap(find.byKey(const ValueKey('calibrationPromptLater')));
      await pump(tester);
      expect(prompt, findsNothing, reason: 'Later takes the offer away');
      container.dispose();
    });

    testWidgets('the offer goes away while the bike rides', (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BikePage(bikeID: id)),
      ));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('calibrationPrompt')), findsOneWidget);

      container.read(fakeBikeStoreProvider).setSpeed(id, 20);
      await pump(tester);

      expect(find.byKey(const ValueKey('calibrationPrompt')), findsNothing,
          reason: 'the first step writes to the bike, so it needs a standstill');
      container.dispose();
    });

    testWidgets('a calibrated bike is not asked again', (tester) async {
      final container = ProviderContainer();
      openBike(
          container,
          euBike().copyWith(
              bootSignature: BootSignature(
                  measuredAt: DateTime(2026, 8, 11),
                  bootWire: 4,
                  bootAssist: 0,
                  preOffWire: 5,
                  preOffAssist: 2)));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BikePage(bikeID: id)),
      ));
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('calibrationPrompt')), findsNothing);
      container.dispose();
    });

    testWidgets('the settings sheet re-runs it on a calibrated bike',
        (tester) async {
      final container = ProviderContainer();
      final bike = euBike().copyWith(
          bootSignature: BootSignature(
              measuredAt: DateTime(2026, 8, 11),
              bootWire: 4,
              bootAssist: 0,
              preOffWire: 5,
              preOffAssist: 2));
      openBike(container, bike);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BikePage(bikeID: id)),
      ));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byTooltip('Bike settings'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final row = find.byKey(const ValueKey('calibrateRow'));
      expect(row, findsOneWidget);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('calibrationStart')), findsOneWidget,
          reason: 'the guide re-runs whatever the bike already measured');
      container.dispose();
    });
  });
}

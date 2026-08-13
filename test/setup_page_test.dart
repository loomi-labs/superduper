import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/setup_page.dart';
import 'package:superduper/widgets.dart';

/// A bike that answers every read with something that is not a settings
/// packet at all, standing in for a read [Bike.readBikeState] must reject.
class _GarbageReadStore extends FakeBikeStore {
  @override
  List<int> read(String deviceId) => const [9, 9, 9, 9, 9, 9, 9, 9, 9, 9];
}

/// A bike whose read throws instead of answering with anything at all, once —
/// standing in for a real BLE failure, distinct from [_GarbageReadStore],
/// which answers with a value [Bike.readBikeState] rejects rather than an
/// exception the wizard has to catch. Only once, and not on every read from
/// here on: a real reconnect also fires the control loop's own unrelated
/// re-assert read (see [Bike._reassertAfterReconnect]), and that one throwing
/// too would just be test noise around the one call this exists to fail.
class _ThrowingReadStore extends FakeBikeStore {
  bool _thrown = false;

  @override
  List<int> read(String deviceId) {
    if (!_thrown) {
      _thrown = true;
      throw Exception('BLE read failed');
    }
    return super.read(deviceId);
  }
}

/// A [ConnectionHandler] whose [write] genuinely pauses on its
/// [pauseOnWrite]-th call (1-indexed) until the test completes [resume].
///
/// The fake bike store's own read/write are plain synchronous calls, so
/// [Bike.probeCapabilities]'s sweep otherwise runs to completion inside a
/// single microtask drain, well before a widget-driven Cancel tap could ever
/// land on it — there is no real await for a test to interleave with. This is
/// the one seam that creates a genuine one: the sweep's own await on this
/// write is what a test can hold open while it drives the rest of the wizard.
class _SlowConnectionHandler extends ConnectionHandler {
  int _writeCount = 0;
  int pauseOnWrite = -1;
  final resume = Completer<void>();

  @override
  Future<void> write(List<int> data) async {
    _writeCount++;
    if (_writeCount == pauseOnWrite) {
      await resume.future;
    }
    return super.write(data);
  }
}

/// The setup wizard: the ten-step flow (stage, two power cycles, probe,
/// save), the gate it feeds on [BikePage], and the two entries that reach it.
///
/// Driven exactly the way a rider drives it — buttons, and the link going
/// down and coming back — so a step that only works when a test calls the
/// notifier directly cannot pass here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'fa:ke:aa:bb:cc:dd';

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_setup_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// An EU bike, ungated: [BikeState.defaultState] seeds capabilities for
  /// every fake bike id (so the debug console and test_driver reach the
  /// controls with no wizard to drive), so every test that means to drive
  /// the wizard itself has to undo that seed explicitly.
  BikeState freshBike() => BikeState.defaultState(id)
      .copyWith(
          region: BikeRegion.eu,
          customModes: const [],
          capabilities: null,
          bootSignature: null)
      .withSelectedMode(nativeModeId(5));

  /// Opens the bike the way the app does: a listener on the provider, and the
  /// record saved through the notifier.
  Bike openBike(ProviderContainer container, [BikeState? bike]) {
    container.listen(bikeProvider(id), (previous, next) {});
    final notifier = container.read(bikeProvider(id).notifier);
    notifier.writeStateData(bike ?? freshBike(), saveToBike: false);
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

  /// Ticks the fake clock in small steps until [found] is true, or
  /// [maxTicks] is reached. Deliberately not `pumpAndSettle`: the wizard
  /// shows an indeterminate spinner while busy, which schedules a frame
  /// forever and would make `pumpAndSettle` hang.
  ///
  /// Finishes with a further 2 s pump regardless of how quickly [found]
  /// turned true: neither a fake read nor [Bike.probeCapabilities] has any
  /// real delay in it, so the wizard can reach its next screen well before
  /// the connection handler's own 1 s connect-settle timer
  /// ([Bike._reassertAfterReconnect]) — armed by the very reconnect that
  /// got the wizard there — has fired. A Timer still pending when the test
  /// ends fails flutter_test's own teardown invariant, whatever it belongs
  /// to.
  Future<void> pumpUntil(WidgetTester tester, bool Function() found,
      {int maxTicks = 300}) async {
    for (var i = 0; i < maxTicks && !found(); i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump(const Duration(seconds: 2));
  }

  bool textShown(String text) => find.text(text).evaluate().isNotEmpty;

  /// Pushes the wizard over an empty page, so its own pop has a route to land
  /// on — the way both entries reach it.
  Future<void> openWizard(
      WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    ));
    Navigator.of(tester.element(find.byType(SizedBox))).push(
        MaterialPageRoute<void>(builder: (_) => const SetupPage(bikeID: id)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await pump(tester);
  }

  /// Stands in for the bike reporting a fresh boot: the settings register as
  /// the firmware would report it right after a power-on.
  void bootBike(ProviderContainer container,
          {required bool light, required int assist, required int wire}) =>
      container.read(fakeBikeStoreProvider).write(
          id, [0, 209, light ? 1 : 0, assist, wire, 0, 0, 0, 0, 0]);

  group('the intro', () {
    testWidgets('has no Later, only Start', (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await openWizard(tester, container);

      expect(find.byKey(const ValueKey('setupStart')), findsOneWidget);
      expect(find.text('Later'), findsNothing);
      expect(find.byType(TextButton), findsNothing,
          reason: 'the intro has no secondary button of any kind');
      container.dispose();
    });

    testWidgets('Start opens the write-suppression window and moves on',
        (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await openWizard(tester, container);

      await tap(tester, 'setupStart');

      expect(bike.debugCalibrating, isTrue);
      expect(find.text('Switch the bike off'), findsOneWidget);
      container.dispose();
    });
  });

  group('the connection-wait steps', () {
    testWidgets('the off hint appears only after its timeout', (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await openWizard(tester, container);
      await tap(tester, 'setupStart');

      await tester.pump(const Duration(seconds: 29));
      expect(find.byKey(const ValueKey('setupHint')), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('setupHint')), findsOneWidget);
      container.dispose();
    });

    testWidgets('the on hint appears only after its timeout', (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await openWizard(tester, container);
      await tap(tester, 'setupStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      expect(find.text('Switch the bike on'), findsOneWidget);

      await tester.pump(const Duration(seconds: 44));
      expect(find.byKey(const ValueKey('setupHint')), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('setupHint')), findsOneWidget);
      container.dispose();
    });

    testWidgets('Connect calls the connection handler\'s manual connect',
        (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await openWizard(tester, container);
      await tap(tester, 'setupStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);

      // Checked before any further pump: the tap's own gesture handling
      // already ran connect() synchronously, and a fake bike's connect()
      // sets it connected straight away, with no real delay to wait out.
      await tester.tap(find.byKey(const ValueKey('setupConnect')));
      expect(container.read(connectionHandlerProvider(id)),
          SDBluetoothConnectionState.connected);

      // Pumping now carries the flow on to the next connection wait — the
      // probe and a fake read have no real delay either. Cancel there
      // (rather than drive a second power cycle this test has no stake in)
      // and flush the connect-settle timer the reconnect above armed, so
      // nothing is left pending for the test framework's own teardown check.
      await pump(tester);
      final cancel = find.byKey(const ValueKey('setupCancel'));
      if (cancel.evaluate().isNotEmpty) {
        await tester.tap(cancel);
      }
      await pump(tester, const Duration(seconds: 2));
      container.dispose();
    });

    testWidgets('Cancel at the first off step closes the window and pops',
        (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await openWizard(tester, container);
      await tap(tester, 'setupStart');

      await tap(tester, 'setupCancel');
      await pump(tester, const Duration(seconds: 1));

      expect(bike.debugCalibrating, isFalse);
      expect(container.read(bikeProvider(id)).capabilities, isNull);
      expect(container.read(bikeProvider(id)).bootSignature, isNull);
      expect(find.byKey(const ValueKey('setupTitle')), findsNothing,
          reason: 'the wizard popped off the stack');
      container.dispose();
    });
  });

  group('a full run', () {
    testWidgets(
        'reaches done, and capabilities/bootSignature stay null until then',
        (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await openWizard(tester, container);

      await tap(tester, 'setupStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      bootBike(container, light: false, assist: 0, wire: 0);
      setConnection(container, SDBluetoothConnectionState.connected);

      // Somewhere in the middle of the probe: the bike is still ungated.
      await pump(tester, const Duration(milliseconds: 50));
      expect(container.read(bikeProvider(id)).capabilities, isNull,
          reason: 'nothing is saved before the second power cycle');

      await pumpUntil(tester, () => textShown('Switch the bike off'));
      expect(container.read(bikeProvider(id)).capabilities, isNull,
          reason: 'the probe finished, but nothing is saved until done');

      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      bootBike(container, light: false, assist: 0, wire: 0);
      setConnection(container, SDBluetoothConnectionState.connected);
      await pumpUntil(tester, () => textShown('Setup complete'));

      final saved = container.read(bikeProvider(id));
      expect(saved.capabilities, isNotNull);
      expect(saved.bootSignature, isNotNull);
      expect(saved.capabilities!.acceptedWires, hasLength(8),
          reason: 'the fake store accepts every write');
      expect(find.textContaining('accepts every mode'), findsOneWidget);
      expect(find.textContaining('resets'), findsOneWidget);

      await tap(tester, 'setupDone');
      container.dispose();
    });

    testWidgets(
        'cancelling after the probe succeeds still leaves capabilities null',
        (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await openWizard(tester, container);

      await tap(tester, 'setupStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      bootBike(container, light: false, assist: 0, wire: 0);
      setConnection(container, SDBluetoothConnectionState.connected);
      // Mid-way through the second power cycle: the probe already ran once.
      await pumpUntil(tester, () => textShown('Switch the bike off'));

      await tap(tester, 'setupCancel');
      await pump(tester, const Duration(seconds: 1));

      expect(bike.debugCalibrating, isFalse);
      expect(container.read(bikeProvider(id)).capabilities, isNull,
          reason: 'the whole point of holding the probe result in local '
              'widget state: a cancel this late must still leave the bike '
              'ungated');
      expect(container.read(bikeProvider(id)).bootSignature, isNull);
      container.dispose();
    });
  });

  group('cancelling mid-probe', () {
    testWidgets(
        'does not stop the sweep, and finishes cleanly with nothing saved '
        'once it completes on its own', (tester) async {
      final slowHandler = _SlowConnectionHandler();
      final container = ProviderContainer(overrides: [
        connectionHandlerProvider(id).overrideWith(() => slowHandler),
      ]);
      final bike = openBike(container);
      await openWizard(tester, container);

      await tap(tester, 'setupStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      bootBike(container, light: false, assist: 0, wire: 0);
      // Pauses on the sweep's own third write — part-way through the wire
      // loop (wires 0 and 1 already tried), genuinely still running.
      slowHandler.pauseOnWrite = 3;
      setConnection(container, SDBluetoothConnectionState.connected);
      await pump(tester);

      expect(textShown('Testing the bike'), isTrue,
          reason: 'the sweep is paused mid-flight, not finished, so the '
              'wizard must still be showing the probing step');
      expect(find.byKey(const ValueKey('setupCancel')), findsOneWidget);

      await tap(tester, 'setupCancel');

      expect(find.textContaining('Finishing the test'), findsOneWidget,
          reason: "the tap is acknowledged, but the sweep can't actually "
              'be stopped mid-flight');
      expect(bike.debugCalibrating, isTrue,
          reason: 'the sweep is still running below the write-suppression '
              "guard — closing it now would reopen the exact write race a "
              'previous fix closed');
      expect(find.byKey(const ValueKey('setupTitle')), findsOneWidget,
          reason: 'the page must not have popped yet either');

      // Let the sweep run to completion, exactly as if the tap had never
      // happened.
      slowHandler.resume.complete();
      await pump(tester, const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('setupTitle')), findsNothing,
          reason: 'once the sweep actually finishes, the deferred cancel '
              'runs the same cleanup an ordinary one would: the wizard pops');
      expect(bike.debugCalibrating, isFalse,
          reason: 'the guard is released once the sweep actually finishes');
      expect(container.read(bikeProvider(id)).capabilities, isNull,
          reason: 'a cancel mid-probe must never reach saveCapabilities, '
              'exactly like a cancel at any other step');
      expect(container.read(bikeProvider(id)).bootSignature, isNull);
      container.dispose();
    });
  });

  group('failure and retry', () {
    testWidgets('a bad read of the first boot reaches failed, with a retry',
        (tester) async {
      final store = _GarbageReadStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      openBike(container);
      await openWizard(tester, container);

      await tap(tester, 'setupStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      setConnection(container, SDBluetoothConnectionState.connected);
      await pumpUntil(tester, () => textShown('Setup stopped'));

      expect(find.byKey(const ValueKey('setupRetry')), findsOneWidget);
      expect(find.byKey(const ValueKey('setupClose')), findsOneWidget);
      // readBoot2 shares the exact same call ([Bike.readBikeState]) and the
      // exact same failure branch as readBoot1 — a bad read at either point
      // reaches [SetupStep.failed] through identical code.
      container.dispose();
    });

    testWidgets('the probe refusing to run reaches failed, with a retry',
        (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await openWizard(tester, container);

      await tap(tester, 'setupStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      bootBike(container, light: false, assist: 0, wire: 0);
      setConnection(container, SDBluetoothConnectionState.connected);
      // The bike is still "moving" when the probe would start: probeCapabilities
      // refuses outright and returns null.
      container.read(fakeBikeStoreProvider).setSpeed(id, 20);
      await pump(tester);

      await pumpUntil(tester, () => textShown('Setup stopped'));

      expect(find.byKey(const ValueKey('setupRetry')), findsOneWidget);
      container.dispose();
    });

    testWidgets(
        'a step that throws (not just returns null) still reaches failed, '
        'with the guard released', (tester) async {
      final store = _ThrowingReadStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      final bike = openBike(container);
      await openWizard(tester, container);

      await tap(tester, 'setupStart');
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      // readBoot1's Bike.readBikeState() call throws outright here, instead
      // of returning null the way _GarbageReadStore's read above does.
      // Without a try/catch around the whole flow this is an unhandled
      // Future error: _step gets stuck on readBoot1 forever, with the
      // calibration guard held open.
      setConnection(container, SDBluetoothConnectionState.connected);
      await pumpUntil(tester, () => textShown('Setup stopped'));

      expect(find.textContaining('Something went wrong'), findsOneWidget,
          reason: 'a generic message, not a technical one the rider cannot '
              'act on');
      expect(find.byKey(const ValueKey('setupRetry')), findsOneWidget);
      expect(bike.debugCalibrating, isFalse,
          reason: 'the guard must close even when a step throws, not just '
              'when one returns a plain failure');
      container.dispose();
    });
  });

  group('the gate on BikePage', () {
    testWidgets('an unset-up bike shows the intro card, not the controls',
        (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BikePage(bikeID: id)),
      ));
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('setupGate')), findsOneWidget);
      expect(find.byType(SelectorBody), findsNothing,
          reason: 'no mode/assist rows for a bike never measured');

      await tester.ensureVisible(find.byKey(const ValueKey('setupGateStart')));
      await tester.tap(find.byKey(const ValueKey('setupGateStart')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('setupTitle')), findsOneWidget,
          reason: 'Start pushed the wizard');
      container.dispose();
    });

    testWidgets('a set-up bike shows the normal controls, not the gate',
        (tester) async {
      final container = ProviderContainer();
      openBike(
          container,
          freshBike().copyWith(
              capabilities: BikeCapabilities(
                  measuredAt: DateTime(2026, 8, 13),
                  acceptedWires: const [4, 5, 6, 7],
                  acceptedAssist: const [0, 1, 2, 3, 4],
                  lightWritable: true)));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BikePage(bikeID: id)),
      ));
      await tester.pump(const Duration(seconds: 1));

      expect(find.byKey(const ValueKey('setupGate')), findsNothing);
      expect(find.byType(SelectorBody), findsWidgets,
          reason: 'the mode/assist cards are back');
      container.dispose();
    });
  });
}

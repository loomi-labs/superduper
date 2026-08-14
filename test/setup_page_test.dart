import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/db.dart';
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

/// Counts calls to [read], standing in for the settings reads the wizard
/// takes — the one before the probe and the one after the power cycle. The
/// count says when a read happened, which is what the timing tests need.
class _CountingReadStore extends FakeBikeStore {
  int readCount = 0;

  @override
  List<int> read(String deviceId) {
    readCount++;
    return super.read(deviceId);
  }
}

/// Records every write, so a test can prove one specific packet reached the
/// bike even where the app's own control loop writes again after it.
class _RecordingStore extends FakeBikeStore {
  final writes = <List<int>>[];

  @override
  void write(String deviceId, List<int> data) {
    writes.add(List.of(data));
    super.write(deviceId, data);
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

/// Counts calls to [connect], standing in for the wizard's fast reconnect
/// poll while a step waits for the bike to come back.
///
/// [respondToConnect] is false by default, so a call only counts and does
/// nothing else: a fake bike's own connect() flips it straight to connected
/// (see [ConnectionHandler._connect]'s `isFakeBike` branch), which would
/// otherwise make it impossible to hold a step "stuck" long enough to prove
/// the poll keeps trying, or to isolate one specific call (a manual Connect
/// tap) from the poll's own automatic ones — every call, poll or manual,
/// reaches this same method. The tests below drive the actual connection
/// transitions themselves, through `setConnection`, or flip
/// [respondToConnect] to true around the one call they want to take effect.
class _CountingConnectionHandler extends ConnectionHandler {
  int connectCount = 0;
  bool respondToConnect = false;

  @override
  Future<void> connect({Duration timeout = const Duration(seconds: 5)}) {
    connectCount++;
    if (!respondToConnect) {
      return Future<void>.value();
    }
    return super.connect(timeout: timeout);
  }
}

/// The setup wizard: the flow (read, probe, one power cycle, read, save), the
/// gate it feeds on [BikePage], and the two entries that reach it.
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
    // A widget test runs on fake time, so the real bikes.json read never lands.
    // Marked loaded by hand: while it is not, [BikesDB] holds every save back
    // and the record below would never reach the DB.
    container.read(bikesDBProvider.notifier).debugMarkLoaded();
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
  ///
  /// The wizard starts its flow on its first frame, so [settle] says how much
  /// of that flow a test wants to let run before it looks: a timing test opens
  /// with [Duration.zero] and steps the clock itself.
  Future<void> openWizard(WidgetTester tester, ProviderContainer container,
      {Duration settle = const Duration(seconds: 1)}) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    ));
    Navigator.of(tester.element(find.byType(SizedBox))).push(
        MaterialPageRoute<void>(builder: (_) => const SetupPage(bikeID: id)));
    await tester.pump();
    await tester.pump(settle);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await pump(tester);
  }

  /// Ends a test that stops in the middle of the flow: stops the wizard and
  /// waits for it to pop, so no timer of the sweep is left for the test
  /// framework's own teardown check.
  Future<void> closeWizard(WidgetTester tester) async {
    for (final key in ['setupCancel', 'setupClose', 'setupDone']) {
      final button = find.byKey(ValueKey(key));
      if (button.evaluate().isNotEmpty) {
        await tester.tap(button);
        break;
      }
    }
    await pumpUntil(
        tester, () => find.byKey(const ValueKey('setupTitle')).evaluate().isEmpty,
        maxTicks: 1000);
  }

  /// Stands in for the bike reporting a fresh boot: the settings register as
  /// the firmware would report it right after a power-on.
  void bootBike(ProviderContainer container,
          {required bool light, required int assist, required int wire}) =>
      container.read(fakeBikeStoreProvider).write(
          id, [0, 209, light ? 1 : 0, assist, wire, 0, 0, 0, 0, 0]);

  group('starting immediately', () {
    testWidgets('the flow runs with no button to press', (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await openWizard(tester, container, settle: Duration.zero);

      expect(find.byKey(const ValueKey('setupStart')), findsNothing,
          reason: 'the gate card is the one start screen');
      expect(bike.debugCalibrating, isTrue,
          reason: 'the window opens before the wizard touches the bike');
      expect(find.byKey(const ValueKey('setupTitle')), findsOneWidget);
      expect(find.text(setupIntroBody), findsNothing,
          reason: 'the wizard never repeats what the gate card said');

      await pumpUntil(tester, () => textShown('Testing the bike'));
      expect(find.text('Testing the bike'), findsOneWidget,
          reason: 'the flow walked on by itself, with no tap');

      await closeWizard(tester);
      container.dispose();
    });

    testWidgets('a connected bike is read without waiting for a settle',
        (tester) async {
      final store = _CountingReadStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      // Seeded directly rather than through openBike(): that helper's own
      // writeStateData call arms the ordinary 2 s update debounce, which would
      // call read() on its own and be mistaken for the read under test.
      container.read(bikesDBProvider.notifier).debugMarkLoaded();
      container.read(bikesDBProvider.notifier).saveBike(freshBike());
      container.listen(bikeProvider(id), (previous, next) {});
      container.read(bikeProvider(id).notifier);
      store.readCount = 0;

      await openWizard(tester, container, settle: Duration.zero);
      await tester.pump(const Duration(milliseconds: 10));

      expect(store.readCount, greaterThan(0),
          reason: 'the connection is settled already, so nothing is waited '
              'out before the first read');

      await closeWizard(tester);
      container.dispose();
    });

    testWidgets(
        'a bike that is away is polled for, and read only after the settle',
        (tester) async {
      final store = _CountingReadStore();
      final handler = _CountingConnectionHandler();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
        connectionHandlerProvider(id).overrideWith(() => handler),
      ]);
      container.read(bikesDBProvider.notifier).debugMarkLoaded();
      container.read(bikesDBProvider.notifier).saveBike(freshBike());
      container.listen(bikeProvider(id), (previous, next) {});
      container.read(bikeProvider(id).notifier);
      setConnection(container, SDBluetoothConnectionState.disconnected);

      await openWizard(tester, container, settle: Duration.zero);
      await pump(tester);
      expect(find.byKey(const ValueKey('setupConnect')), findsOneWidget,
          reason: 'a rider whose bike is away needs the manual way back');
      final afterArming = handler.connectCount;
      expect(afterArming, greaterThanOrEqualTo(1),
          reason: 'the step asks for the bike the instant it starts waiting');

      await tester.pump(const Duration(seconds: 6));
      expect(handler.connectCount, greaterThan(afterArming + 1),
          reason: 'the fast poll asks again while the rider waits');

      store.readCount = 0;
      setConnection(container, SDBluetoothConnectionState.connected);
      await tester.pump();
      await tester.pump(Bike.connectSettle - const Duration(milliseconds: 1));
      expect(store.readCount, 0,
          reason: 'a read this soon after connecting could still land on the '
              "transport's own re-selected register");

      await tester.pump(const Duration(milliseconds: 2));
      expect(store.readCount, greaterThan(0),
          reason: 'once Bike.connectSettle has elapsed, the read goes through');

      await closeWizard(tester);
      container.dispose();
    });
  });

  group('the connection-wait steps', () {
    /// Runs the wizard as far as the power cycle: the probe is done, and the
    /// bike waits to be switched off.
    Future<void> reachTurnOff(
        WidgetTester tester, ProviderContainer container) async {
      await openWizard(tester, container);
      await pumpUntil(tester, () => textShown('Switch the bike off'));
    }

    testWidgets('the off hint appears only after its timeout', (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await reachTurnOff(tester, container);

      // Not the full 30 s of the timeout: reaching this step already consumed
      // a couple of seconds of the fake clock.
      await tester.pump(const Duration(seconds: 25));
      expect(find.byKey(const ValueKey('setupHint')), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      expect(find.byKey(const ValueKey('setupHint')), findsOneWidget);
      await closeWizard(tester);
      container.dispose();
    });

    testWidgets('the on hint appears only after its timeout', (tester) async {
      // The wizard's own fast reconnect poll (see the group below) fires a
      // connect() the instant this wait starts, and a fake bike's connect()
      // would otherwise succeed straight away, resolving the wait before
      // this test can ever observe it still pending. The connection handler
      // is swapped out so nothing here actually reconnects the bike.
      final container = ProviderContainer(overrides: [
        connectionHandlerProvider(id)
            .overrideWith(() => _CountingConnectionHandler()),
      ]);
      openBike(container);
      await reachTurnOff(tester, container);
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      expect(find.text('Switch the bike on'), findsOneWidget);

      await tester.pump(const Duration(seconds: 44));
      expect(find.byKey(const ValueKey('setupHint')), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('setupHint')), findsOneWidget);
      await closeWizard(tester);
      container.dispose();
    });

    testWidgets(
        'the boot read waits until Bike.connectSettle has elapsed',
        (tester) async {
      // A real device log caught this exact race: a settings read taken the
      // instant the wizard sees the reconnect can land while the transport's
      // own post-connect handshake has already re-selected a different
      // register for its own ride-data request, so the read comes back with
      // ride data instead of settings and the wizard fails outright.
      // The connection handler is swapped out for the same reason as in
      // 'the on hint appears only after its timeout' above: the wizard's own
      // fast reconnect poll fires a connect() the instant the wait starts,
      // and a fake bike's real connect() would otherwise reconnect it right
      // there — before this test's own controlled setConnection(connected)
      // call below, which is what drives the timing this test cares about.
      final container = ProviderContainer(overrides: [
        connectionHandlerProvider(id)
            .overrideWith(() => _CountingConnectionHandler()),
      ]);
      openBike(container);
      await reachTurnOff(tester, container);
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      bootBike(container, light: false, assist: 0, wire: 0);
      setConnection(container, SDBluetoothConnectionState.connected);
      // Flushes the microtask that carries the flow from "connected" into
      // the wait for Bike.connectSettle, without advancing the fake clock
      // far enough for that wait to resolve.
      await tester.pump();

      await tester.pump(Bike.connectSettle - const Duration(milliseconds: 1));
      expect(textShown('Reading the bike'), isTrue,
          reason: 'the read has not been taken yet: this soon after '
              "reconnecting it could still land on the transport's own "
              're-selected register, exactly as the real device log showed');

      await tester.pump(const Duration(milliseconds: 2));
      await pump(tester);
      expect(textShown('Setup complete'), isTrue,
          reason: 'once Bike.connectSettle has elapsed, the read goes through '
              'and finishes the flow');

      await closeWizard(tester);
      container.dispose();
    });

    testWidgets('Connect calls the connection handler\'s manual connect',
        (tester) async {
      // The wizard's own fast reconnect poll also calls connect() the
      // instant the wait starts, and on a fake bike that call would succeed
      // immediately too — leaving nothing left for a manual tap to prove.
      // The handler is swapped out so only the tap's own call is let
      // through, isolating exactly what this test means to check.
      final handler = _CountingConnectionHandler();
      final container = ProviderContainer(overrides: [
        connectionHandlerProvider(id).overrideWith(() => handler),
      ]);
      openBike(container);
      await reachTurnOff(tester, container);
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);

      // Checked before any further pump: the tap's own gesture handling
      // already ran connect() synchronously, and a fake bike's connect()
      // sets it connected straight away, with no real delay to wait out.
      handler.respondToConnect = true;
      await tester.tap(find.byKey(const ValueKey('setupConnect')));
      expect(container.read(connectionHandlerProvider(id)),
          SDBluetoothConnectionState.connected);

      await pump(tester);
      await closeWizard(tester);
      container.dispose();
    });

    testWidgets('Cancel at the off step closes the window and pops',
        (tester) async {
      final container = ProviderContainer();
      final bike = openBike(container);
      await reachTurnOff(tester, container);

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

  group('the fast reconnect poll while waiting for the bike to come back',
      () {
    // A real device log showed 28s and 49s gaps with zero connection
    // attempts at exactly this step — the background reconnect ladder is
    // deliberately slow, and stops entirely with Auto-reconnect off. These
    // tests guard the fix: a dedicated fast retry, local to the wizard.

    /// Runs the wizard as far as the power cycle, then switches the bike off.
    Future<void> reachTurnOn(
        WidgetTester tester, ProviderContainer container) async {
      await openWizard(tester, container);
      await pumpUntil(tester, () => textShown('Switch the bike off'));
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
    }

    testWidgets(
        'keeps retrying roughly every 1.5s while stuck waiting for the '
        'bike to come back on', (tester) async {
      final handler = _CountingConnectionHandler();
      final container = ProviderContainer(overrides: [
        connectionHandlerProvider(id).overrideWith(() => handler),
      ]);
      openBike(container);
      await reachTurnOn(tester, container);
      expect(find.text('Switch the bike on'), findsOneWidget);

      final afterArming = handler.connectCount;
      expect(afterArming, greaterThanOrEqualTo(1),
          reason: 'the step fires one attempt the instant it starts '
              'waiting');

      await tester.pump(const Duration(seconds: 6));

      expect(handler.connectCount, greaterThan(afterArming + 1),
          reason: 'six seconds at a 1.5s cadence must produce several '
              'more attempts, not just the one the step started with — '
              "today's bug is zero further attempts at all");

      // Let the wait resolve and flush the poll timer, so nothing is left
      // pending for the test framework's own teardown check.
      bootBike(container, light: false, assist: 0, wire: 0);
      setConnection(container, SDBluetoothConnectionState.connected);
      await pumpUntil(tester, () => textShown('Setup complete'));
      await closeWizard(tester);
      container.dispose();
    });

    testWidgets(
        'stops polling the instant the bike is seen connected, with no '
        'timer left running', (tester) async {
      final handler = _CountingConnectionHandler();
      final container = ProviderContainer(overrides: [
        connectionHandlerProvider(id).overrideWith(() => handler),
      ]);
      openBike(container);
      await reachTurnOn(tester, container);
      expect(find.text('Switch the bike on'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      final beforeConnect = handler.connectCount;
      expect(beforeConnect, greaterThan(1),
          reason: 'sanity check: the poll must have ticked at least once '
              'by now');

      bootBike(container, light: false, assist: 0, wire: 0);
      setConnection(container, SDBluetoothConnectionState.connected);
      await pumpUntil(tester, () => textShown('Setup complete'));

      expect(handler.connectCount, beforeConnect,
          reason: 'the poll must stop the instant the connection is seen '
              'as connected, not keep ticking through the boot read');

      // A clean end with the widget disposed: if _reconnectPollTimer were
      // not cancelled, flutter_test's own teardown check would fail here
      // with a leaked Timer.
      await closeWizard(tester);
      container.dispose();
    });

    testWidgets(
        'polls on its own cadence even when Auto-reconnect is off for '
        'this bike', (tester) async {
      final handler = _CountingConnectionHandler();
      final container = ProviderContainer(overrides: [
        connectionHandlerProvider(id).overrideWith(() => handler),
      ]);
      openBike(container, freshBike().copyWith(autoReconnect: false));
      await reachTurnOn(tester, container);
      expect(find.text('Switch the bike on'), findsOneWidget);
      expect(handler.debugAutoReconnect, isFalse,
          reason: 'sanity check: the bike record really did carry the '
              'setting through to the connection handler');

      final afterArming = handler.connectCount;
      await tester.pump(const Duration(seconds: 6));

      expect(handler.connectCount, greaterThan(afterArming + 1),
          reason: "the wizard's own fast retry never consults "
              'autoReconnect — only the background ladder does');

      bootBike(container, light: false, assist: 0, wire: 0);
      setConnection(container, SDBluetoothConnectionState.connected);
      await pumpUntil(tester, () => textShown('Setup complete'));
      await closeWizard(tester);
      container.dispose();
    });
  });

  group('a full run', () {
    testWidgets(
        'reaches done, and capabilities/bootSignature stay null until then',
        (tester) async {
      final container = ProviderContainer();
      openBike(container);
      await openWizard(tester, container, settle: Duration.zero);

      // Somewhere in the middle of the probe: the bike is still ungated.
      await pump(tester, const Duration(milliseconds: 50));
      expect(container.read(bikeProvider(id)).capabilities, isNull,
          reason: 'nothing is saved before the power cycle');

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

    testWidgets('a CH bike reads its summary in km/h, not mph',
        (tester) async {
      final container = ProviderContainer();
      openBike(
          container,
          BikeState.defaultState(id)
              .copyWith(
                  region: BikeRegion.ch,
                  customModes: const [seededChMode],
                  capabilities: null,
                  bootSignature: null)
              .withSelectedMode(seededChModeId));
      // Wire 4 is EPAC: 25 km/h, or '16 mph' for a bike of unknown region.
      // The bike sits on it before the probe as well, so the sweep parks
      // somewhere else and the boot below really does say something.
      bootBike(container, light: false, assist: 0, wire: 4);
      await openWizard(tester, container);

      await pumpUntil(tester, () => textShown('Switch the bike off'));
      setConnection(container, SDBluetoothConnectionState.disconnected);
      await pump(tester);
      bootBike(container, light: false, assist: 0, wire: 4);
      setConnection(container, SDBluetoothConnectionState.connected);
      await pumpUntil(tester, () => textShown('Setup complete'));

      expect(container.read(bikeProvider(id)).region, BikeRegion.ch);
      expect(find.textContaining('25 km/h'), findsOneWidget,
          reason: 'the rider reads the cap in the unit of the region the bike '
              'is actually set to');
      expect(find.textContaining('mph'), findsNothing,
          reason: 'BikeCapabilities.detectedRegion is null for every CH bike, '
              'and a null region renders mph, so the summary has to take the '
              "region off the bike's own record");
      await tap(tester, 'setupDone');
      container.dispose();
    });

    testWidgets(
        'cancelling after the probe succeeds still leaves capabilities null',
        (tester) async {
      final store = _RecordingStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      final bike = openBike(container);
      // The bike sits on its own boot triple before the probe starts: light
      // off, assist 0, wire 0 — the baseline the wizard has to put back.
      bootBike(container, light: false, assist: 0, wire: 0);
      await openWizard(tester, container);

      // The probe already ran; the rider is asked for the power cycle.
      await pumpUntil(tester, () => textShown('Switch the bike off'));

      final beforeCancel = store.writes.length;
      await tap(tester, 'setupCancel');
      await pump(tester, const Duration(seconds: 1));

      expect(bike.debugCalibrating, isFalse);
      expect(container.read(bikeProvider(id)).capabilities, isNull,
          reason: 'the whole point of holding the probe result in local '
              'widget state: a cancel this late must still leave the bike '
              'ungated');
      expect(container.read(bikeProvider(id)).bootSignature, isNull);
      // The sweep parks the bike on values of its own (a safe wire, the
      // parting assist, the flipped light) and restores the boot values itself
      // only when it could not finish. A discarded result has to be undone
      // here instead: with capabilities still null, the gate hides the very
      // controls the rider would need to put the bike back by hand.
      expect(
          store.writes
              .skip(beforeCancel)
              .any((write) => write[2] == 0 && write[3] == 0 && write[4] == 0),
          isTrue,
          reason: 'the whole boot triple — light off, assist 0, wire 0 — goes '
              'back on the bike as the wizard leaves');
      // The register itself is only asserted for light and assist: once the
      // window closes, the ordinary control loop heals the bike onto the wire
      // the selected mode asserts, which is the app doing its job rather than
      // a leftover of the probe.
      final register = store.read(id);
      expect(register[2], 0, reason: 'the assist is back on the boot level');
      expect(register[4], 0, reason: 'and the light back off');
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
      bootBike(container, light: false, assist: 0, wire: 0);
      // Pauses on the sweep's own third write — part-way through the wire
      // loop (wires 0 and 1 already tried), genuinely still running.
      slowHandler.pauseOnWrite = 3;
      await openWizard(tester, container, settle: Duration.zero);
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
      // happened. Bike._probeSettle now puts a real pause between every
      // write and its readback, so the remaining steps of the sweep (most
      // of the wire loop, the whole assist loop, the light test) need
      // several seconds of virtual time to finish — pumpUntil's small ticks
      // are used rather than one large pump(duration): the pop's own route
      // transition needs several discrete frames of its own to settle, which
      // a single big time jump followed by one frame does not give it.
      slowHandler.resume.complete();
      await pumpUntil(
          tester, () => find.byKey(const ValueKey('setupTitle')).evaluate().isEmpty,
          maxTicks: 1000);

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
      await pumpUntil(tester, () => textShown('Setup stopped'));

      expect(find.byKey(const ValueKey('setupRetry')), findsOneWidget);
      expect(find.byKey(const ValueKey('setupClose')), findsOneWidget);
      // The boot read shares the exact same call ([Bike.readBikeState]) and
      // the exact same failure branch as the read before the probe — a bad
      // read at either point reaches [SetupStep.failed] through identical
      // code.
      container.dispose();
    });

    testWidgets('the probe refusing to run reaches failed, with a retry',
        (tester) async {
      final container = ProviderContainer();
      openBike(container);
      bootBike(container, light: false, assist: 0, wire: 0);
      // The bike is moving when the wizard opens: probeCapabilities refuses
      // outright and returns null.
      container.read(fakeBikeStoreProvider).setSpeed(id, 20);
      await openWizard(tester, container);

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
      // Seeded directly rather than through openBike(): that helper's own
      // writeStateData call arms the ordinary 2 s update debounce, which
      // would otherwise call read() on its own before readBoot1 does,
      // consuming this store's one throw on a read this test has no stake
      // in, and reaching probing instead of failed. Bike.connectSettle's
      // wait (the fix under test elsewhere in this file) is exactly what
      // pushes readBoot1's own read late enough to lose that race.
      container.read(bikesDBProvider.notifier).debugMarkLoaded();
      container.read(bikesDBProvider.notifier).saveBike(freshBike());
      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);

      // The first read of the flow throws outright here, instead of returning
      // null the way _GarbageReadStore's read above does. Without a try/catch
      // around the whole flow this is an unhandled Future error: _step gets
      // stuck on the read forever, with the calibration guard held open.
      await openWizard(tester, container);
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

      await closeWizard(tester);
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

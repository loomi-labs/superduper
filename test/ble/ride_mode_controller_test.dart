import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/ble/bike_protocol.dart';
import 'package:superduper/src/ble/bike_session.dart';
import 'package:superduper/src/ble/bike_transport.dart';
import 'package:superduper/src/ble/ride_mode_controller.dart';
import 'package:superduper/src/domain/bike.dart';
import 'package:superduper/src/domain/ride_modes.dart';

import '../support/fake_bike_transport.dart';

void main() {
  late FakeBikeConnection connection;
  late BikeSession session;
  late RideModeController controller;

  SavedBike chBike({
    SetOnConnect setOnConnect = const SetOnConnect(),
    List<CustomMode> customModes = const [seededChMode],
    bool streetLegal = false,
    int? stockMode,
  }) {
    return SavedBike(
      bike: Bike(
        deviceId: 'bike',
        displayName: 'CH',
        protocol: BikeProtocolVersion.v1,
        region: BikeRegion.ch,
        color: BikeColor.royalHorizon,
        sortOrder: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        lastConnectedAt: null,
      ),
      setOnConnect: setOnConnect,
      customModes: customModes,
      streetLegalOnQuickRestart: streetLegal,
      streetLegalStockMode: stockMode,
    );
  }

  Future<void> start(
    SavedBike bike, {
    required int bootWire,
    Duration speedTimeout = const Duration(seconds: 5),
    DateTime Function()? clock,
    int historyMarker = BikeGatt.sessionAppliedMarker,
  }) async {
    connection.readFrames.add(v1StateFrame(mode: bootWire));
    if (bike.streetLegalOnQuickRestart) {
      connection.readFrames.add(
        v1HistoryFrame(marker: historyMarker, mode: bootWire),
      );
    }
    session = BikeSession(
      connection: connection,
      setOnConnect: resolveSetOnConnect(bike).patch,
      protocol: BikeProtocolVersion.v1,
      readDiagnosticsOnConnect: false,
      reconnectDelays: const [Duration(milliseconds: 10)],
      streetLegalOnQuickRestart: bike.streetLegalOnQuickRestart,
      streetLegalStockMode: resolveStockMode(bike),
      counterSampleTimeout: const Duration(milliseconds: 20),
      clock: clock,
    );
    controller = RideModeController(
      session: session,
      bike: bike,
      speedTimeout: speedTimeout,
      clock: clock,
      watchdogInterval: const Duration(milliseconds: 20),
    );
    await session.connect();
    await Future<void>.delayed(Duration.zero);
  }

  List<int> modeWrites() => connection.writes
      .where(
        (w) =>
            w.characteristicUuid == BikeGatt.stateRegister &&
            w.value[1] == 0xd1,
      )
      .map((w) => w.value[4])
      .toList();

  void speed(double kmh) {
    final raw = (kmh * 100).round();
    connection.emitNotification([
      2,
      1,
      raw & 0xff,
      (raw >> 8) & 0xff,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  }

  setUp(() {
    connection = FakeBikeConnection(deviceId: 'bike');
  });

  tearDown(() async {
    controller.dispose();
    await session.dispose();
  });

  test(
    'set-on-connect custom mode becomes the selection on the entry wire',
    () async {
      await start(
        chBike(
          setOnConnect: const SetOnConnect(mode: CustomModeRef(seededChModeId)),
        ),
        bootWire: 7,
      );
      expect(session.observed.value?.mode, 1);
      expect(controller.selection.value, const CustomRideMode(seededChMode));
      expect(controller.needsBackgroundHold.value, isTrue);
    },
  );

  late Future<void> connecting;

  Future<void> connectGated(SavedBike bike) async {
    connection
      ..connectGate = Completer<void>()
      ..readFrames.add(v1StateFrame(mode: 7));
    session = BikeSession(
      connection: connection,
      setOnConnect: resolveSetOnConnect(bike).patch,
      protocol: BikeProtocolVersion.v1,
      readDiagnosticsOnConnect: false,
      reconnectDelays: const [Duration(milliseconds: 10)],
    );
    controller = RideModeController(session: session, bike: bike);
    connecting = session.connect();
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'a switching set-on-connect mode holds before the first connection',
    () async {
      await connectGated(
        chBike(
          setOnConnect: const SetOnConnect(mode: CustomModeRef(seededChModeId)),
        ),
      );

      expect(controller.selection.value, isNull);
      expect(controller.needsBackgroundHold.value, isTrue);

      connection.connectGate!.complete();
      await connecting;
    },
  );

  test(
    'without set-on-connect nothing holds before the first connection',
    () async {
      await connectGated(chBike());

      expect(controller.selection.value, isNull);
      expect(controller.needsBackgroundHold.value, isFalse);

      connection.connectGate!.complete();
      await connecting;
    },
  );

  test(
    'without set-on-connect the selection follows the observed wire',
    () async {
      await start(chBike(), bootWire: 7);
      expect(controller.selection.value, const NativeRideMode(7));
      expect(controller.needsBackgroundHold.value, isFalse);
    },
  );

  test('switches up above the limit and down below the band', () async {
    await start(
      chBike(
        setOnConnect: const SetOnConnect(mode: CustomModeRef(seededChModeId)),
      ),
      bootWire: 7,
    );
    final before = modeWrites().length;
    speed(24);
    await Future<void>.delayed(Duration.zero);
    expect(modeWrites().length, before);
    speed(26);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(modeWrites().last, 4);
    speed(24);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(modeWrites().last, 4);
    speed(22);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(modeWrites().last, 1);
  });

  test(
    'select writes the entry wire and select native stops the loop',
    () async {
      await start(chBike(), bootWire: 7);
      await controller.select(const CustomRideMode(seededChMode));
      expect(modeWrites().last, 1);
      expect(controller.needsBackgroundHold.value, isTrue);
      await controller.select(const NativeRideMode(7));
      expect(modeWrites().last, 7);
      expect(controller.needsBackgroundHold.value, isFalse);
      speed(30);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(modeWrites().last, 7);
    },
  );

  test('a foreign observed wire makes the selection follow', () async {
    await start(chBike(), bootWire: 1);
    await controller.select(const CustomRideMode(seededChMode));
    connection.emitNotification([3, 0, 0, 0, 0, 7, 0, 0, 0, 0]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.selection.value, const NativeRideMode(7));
    expect(controller.needsBackgroundHold.value, isFalse);
  });

  test(
    'reconnect on one of the pair wires keeps the custom selection',
    () async {
      await start(chBike(), bootWire: 7);
      await controller.select(const CustomRideMode(seededChMode));
      connection.readFrames.add(v1StateFrame(mode: 4));
      connection.emitState(BikeConnectionState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(session.state.value, isA<SessionReady>());
      expect(controller.selection.value, const CustomRideMode(seededChMode));
      expect(controller.assertedWire, 4);
    },
  );

  test('power cycle onto a foreign wire without set-on-connect follows', () async {
    await start(chBike(), bootWire: 1);
    await controller.select(const CustomRideMode(seededChMode));
    final before = modeWrites().length;
    connection.readFrames.add(v1StateFrame(mode: 7));
    connection.emitState(BikeConnectionState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(controller.selection.value, const NativeRideMode(7));
    // Only the session's write-back of the observed state, never a custom wire.
    expect(modeWrites().sublist(before), everyElement(7));
  });

  test(
    'a power cycle onto a foreign wire keeps the hold with set-on-connect',
    () async {
      await start(
        chBike(
          setOnConnect: const SetOnConnect(mode: CustomModeRef(seededChModeId)),
        ),
        bootWire: 7,
      );
      final holds = <bool>[];
      final cleanup = controller.needsBackgroundHold.subscribe(holds.add);

      connection.readFrames.add(v1StateFrame(mode: 7));
      connection.emitState(BikeConnectionState.disconnected);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cleanup();

      expect(session.state.value, isA<SessionReady>());
      expect(session.observed.value?.mode, 1);
      expect(controller.selection.value, const CustomRideMode(seededChMode));
      expect(holds, everyElement(isTrue));
    },
  );

  test('speed while reconnecting writes nothing', () async {
    await start(
      chBike(
        setOnConnect: const SetOnConnect(mode: CustomModeRef(seededChModeId)),
      ),
      bootWire: 7,
    );
    connection
      ..connectGate = Completer<void>()
      ..emitState(BikeConnectionState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    final before = modeWrites().length;
    speed(40);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(modeWrites().length, before);
    connection.readFrames.add(v1StateFrame(mode: 1));
    connection.connectGate!.complete();
  });

  test('watchdog re-requests ride data and caps an unlimited base', () async {
    const fast = CustomMode(id: 'f', name: '35t', limitKmh: 35, throttle: true);
    await start(
      chBike(
        setOnConnect: const SetOnConnect(mode: CustomModeRef('f')),
        customModes: const [fast],
      ),
      bootWire: 7,
      speedTimeout: const Duration(milliseconds: 30),
    );
    expect(modeWrites().last, 5);
    speed(10);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(modeWrites().last, 7);
    final requestsBefore = connection.writes
        .where((w) => w.value[0] == 2 && w.value[1] == 3)
        .length;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(modeWrites().last, 5);
    expect(
      connection.writes.where((w) => w.value[0] == 2 && w.value[1] == 3).length,
      greaterThan(requestsBefore),
    );
  });

  test(
    'updateBike with the selected mode removed falls back to the observed wire',
    () async {
      await start(chBike(), bootWire: 7);
      await controller.select(const CustomRideMode(seededChMode));
      controller.updateBike(chBike(customModes: const []));
      await Future<void>.delayed(Duration.zero);
      expect(controller.selection.value, const NativeRideMode(1));
      expect(controller.needsBackgroundHold.value, isFalse);
    },
  );

  test('a failed select keeps the previous state', () async {
    await start(chBike(), bootWire: 7);
    await session.disconnect();

    await expectLater(
      controller.select(const CustomRideMode(seededChMode)),
      throwsA(isA<BikeSessionNotReady>()),
    );

    expect(controller.selection.value, const NativeRideMode(7));
    expect(controller.assertedWire, 7);
    expect(controller.needsBackgroundHold.value, isFalse);
  });

  test('the hold stays while the bike is unreachable', () async {
    var now = DateTime(2026, 1, 1, 12);
    await start(
      chBike(
        setOnConnect: const SetOnConnect(mode: CustomModeRef(seededChModeId)),
      ),
      bootWire: 7,
      clock: () => now,
    );
    expect(controller.needsBackgroundHold.value, isTrue);

    connection
      ..connectGate = Completer<void>()
      ..emitState(BikeConnectionState.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    now = now.add(const Duration(hours: 2));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.needsBackgroundHold.value, isTrue);

    connection.readFrames.add(v1StateFrame(mode: 1));
    connection.connectGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.state.value, isA<SessionReady>());
    expect(controller.needsBackgroundHold.value, isTrue);
  });

  test('a static custom mode never holds the background', () async {
    const exact = CustomMode(
      id: 'x',
      name: '32t',
      limitKmh: 32,
      throttle: true,
    );
    await start(chBike(customModes: const [exact]), bootWire: 7);
    await controller.select(const CustomRideMode(exact));
    expect(modeWrites().last, 1);
    expect(controller.needsBackgroundHold.value, isFalse);
  });

  group('street-legal lock', () {
    late DateTime now;

    setUp(() => now = DateTime(2026, 10, 3, 12));

    SavedBike lockingBike({int? stockMode}) => chBike(
      setOnConnect: const SetOnConnect(mode: CustomModeRef(seededChModeId)),
      streetLegal: true,
      stockMode: stockMode,
    );

    Future<void> startLocking({
      int? stockMode,
      int historyMarker = BikeGatt.sessionAppliedMarker,
      int? counter,
    }) async {
      connection.auxiliaryCounter = counter;
      await start(
        lockingBike(stockMode: stockMode),
        bootWire: 7,
        clock: () => now,
        historyMarker: historyMarker,
      );
    }

    Future<void> tick() =>
        Future<void>.delayed(const Duration(milliseconds: 50));

    /// Waits until the lock is on, at most 1 second.
    Future<void> waitForLock() async {
      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (!session.streetLegalLocked.value &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    CharacteristicWrite lastControlWrite() => connection.writes.lastWhere(
      (w) =>
          w.characteristicUuid == BikeGatt.stateRegister && w.value[1] == 0xd1,
    );

    test('the preference holds the background on a native mode', () async {
      await start(chBike(streetLegal: true), bootWire: 7, clock: () => now);

      expect(controller.selection.value, const NativeRideMode(7));
      expect(controller.needsBackgroundHold.value, isTrue);

      await session.disconnect();
      expect(controller.needsBackgroundHold.value, isFalse);
    });

    test('the lock selects the wire the bike reports', () async {
      await startLocking(historyMarker: BikeGatt.sessionLockedMarker);

      expect(session.streetLegalLocked.value, isTrue);
      expect(controller.selection.value, const NativeRideMode(7));
      expect(controller.parkedMinutesLeft.value, isNull);

      now = now.add(const Duration(minutes: 20));
      await tick();
      expect(modeWrites(), everyElement(7));
    });

    test('a mode choice ends the lock and starts the timer', () async {
      await startLocking(historyMarker: BikeGatt.sessionLockedMarker);

      await controller.select(const CustomRideMode(seededChMode));

      expect(session.streetLegalLocked.value, isFalse);
      expect(lastControlWrite().value[5], BikeGatt.sessionAppliedMarker);
      expect(controller.parkedMinutesLeft.value, 10);
    });

    test('a failed mode choice keeps the lock', () async {
      await startLocking(historyMarker: BikeGatt.sessionLockedMarker);
      await session.disconnect();

      await expectLater(
        controller.select(const CustomRideMode(seededChMode)),
        throwsA(isA<BikeSessionNotReady>()),
      );

      expect(session.streetLegalLocked.value, isTrue);
    });

    test('the timer does not run with the preference off', () async {
      await start(
        chBike(
          setOnConnect: const SetOnConnect(mode: CustomModeRef(seededChModeId)),
        ),
        bootWire: 7,
        clock: () => now,
      );
      expect(controller.parkedMinutesLeft.value, isNull);

      now = now.add(const Duration(minutes: 20));
      await tick();

      expect(modeWrites().last, 1);
      expect(session.streetLegalLocked.value, isFalse);
    });

    test('the timer does not run in the stock mode', () async {
      await start(chBike(streetLegal: true), bootWire: 7, clock: () => now);
      expect(controller.parkedMinutesLeft.value, 10);

      await controller.select(const NativeRideMode(4));
      expect(controller.parkedMinutesLeft.value, isNull);

      now = now.add(const Duration(minutes: 20));
      await tick();

      expect(session.streetLegalLocked.value, isFalse);
    });

    test(
      'expiry writes the stock mode with marker 2 and starts the lock',
      () async {
        await startLocking();
        expect(controller.parkedMinutesLeft.value, 10);

        now = now.add(const Duration(minutes: 10));
        await waitForLock();

        final last = lastControlWrite();
        expect(last.value[4], 4);
        expect(last.value[5], BikeGatt.sessionLockedMarker);
        expect(session.streetLegalLocked.value, isTrue);
        expect(controller.selection.value, const NativeRideMode(4));
        expect(controller.parkedMinutesLeft.value, isNull);
        expect(controller.needsBackgroundHold.value, isTrue);
      },
    );

    test('speed above 0 restarts the timer', () async {
      await startLocking();
      now = now.add(const Duration(minutes: 9));
      speed(5);
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(minutes: 9));
      await tick();

      expect(session.streetLegalLocked.value, isFalse);
      expect(controller.parkedMinutesLeft.value, 1);

      now = now.add(const Duration(minutes: 1));
      await waitForLock();
      expect(session.streetLegalLocked.value, isTrue);
    });

    test('assist, light and zero speed do not restart the timer', () async {
      await startLocking();
      now = now.add(const Duration(minutes: 9));
      await session.setAssist(2);
      await session.setLight(true);
      speed(0);
      await Future<void>.delayed(Duration.zero);

      now = now.add(const Duration(minutes: 1));
      await waitForLock();

      expect(session.streetLegalLocked.value, isTrue);
    });

    test('a mode choice restarts the timer', () async {
      await startLocking();
      now = now.add(const Duration(minutes: 9));
      await controller.select(const NativeRideMode(7));

      now = now.add(const Duration(minutes: 9));
      await tick();

      expect(session.streetLegalLocked.value, isFalse);
      expect(controller.parkedMinutesLeft.value, 1);
    });

    test('expiry stops the speed switching of a custom mode first', () async {
      await startLocking(stockMode: 5);
      final gate = Completer<void>();
      connection
        ..configurationWriteGate = gate
        ..configurationWriteGateAfterStarts =
            connection.configurationWriteStarts;
      now = now.add(const Duration(minutes: 10));
      await tick();
      final before = modeWrites().length;

      // Above the limit the custom mode would write its cap wire 4.
      speed(30);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      gate.complete();
      connection.configurationWriteGate = null;
      await waitForLock();

      expect(modeWrites().sublist(before), [5]);
      expect(session.streetLegalLocked.value, isTrue);
      expect(controller.selection.value, const NativeRideMode(5));
    });

    test('a failed lock write leaves the lock off and tries again', () async {
      await startLocking();
      connection.writeError = StateError('write failed');
      now = now.add(const Duration(minutes: 10));
      await tick();

      expect(session.streetLegalLocked.value, isFalse);
      expect(controller.selection.value, const CustomRideMode(seededChMode));

      connection
        ..writeError = null
        ..readFrames.addAll([v1StateFrame(mode: 1), v1HistoryFrame(mode: 1)]);
      await waitForLock();

      final last = lastControlWrite();
      expect(last.value[4], 4);
      expect(last.value[5], BikeGatt.sessionLockedMarker);
      expect(session.streetLegalLocked.value, isTrue);
    });

    test('a dropout pauses the timer and marker 1 continues it', () async {
      await startLocking(counter: 100);
      now = now.add(const Duration(minutes: 6));
      await tick();
      expect(controller.parkedMinutesLeft.value, 4);

      // The link is down for 3 minutes. The bike is on for 2 of them.
      connection
        ..auxiliaryCounter = 220
        ..readFrames.addAll([v1StateFrame(mode: 1), v1HistoryFrame(mode: 1)])
        ..emitState(BikeConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(minutes: 3));
      await tick();

      expect(session.state.value, isA<SessionReady>());
      expect(session.streetLegalLocked.value, isFalse);
      // 6 minutes before the dropout and 2 minutes of bike on time.
      expect(controller.parkedMinutesLeft.value, 2);

      now = now.add(const Duration(minutes: 2));
      await waitForLock();
      expect(session.streetLegalLocked.value, isTrue);
    });
  });
}

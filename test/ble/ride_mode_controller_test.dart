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
    );
  }

  Future<void> start(
    SavedBike bike, {
    required int bootWire,
    Duration speedTimeout = const Duration(seconds: 5),
  }) async {
    connection.readFrames.add(v1StateFrame(mode: bootWire));
    session = BikeSession(
      connection: connection,
      setOnConnect: resolveSetOnConnect(bike).patch,
      protocol: BikeProtocolVersion.v1,
      readDiagnosticsOnConnect: false,
      reconnectDelays: const [Duration(milliseconds: 10)],
    );
    controller = RideModeController(
      session: session,
      bike: bike,
      speedTimeout: speedTimeout,
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
}

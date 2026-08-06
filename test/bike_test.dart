import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/db.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/repository.dart';

/// A bike whose BLE writes fail, to check the notifier does not report a write
/// that never landed — and does not latch itself.
class _FailingWriteStore extends FakeBikeStore {
  @override
  void write(String deviceId, List<int> data) {
    throw Exception('BLE write failed');
  }
}

/// A bike that answers the next read with a ride data frame instead of its
/// settings register, standing in for a read that arrived after the ride data
/// register was selected on the shared characteristic.
class _RideDataStore extends FakeBikeStore {
  bool serveRideData = false;

  @override
  List<int> read(String deviceId) {
    if (!serveRideData) {
      return super.read(deviceId);
    }
    serveRideData = false;
    // [2, 1, speed_lo, speed_hi, ...]: read as a settings packet this would be
    // assist 4, light on, and wire byte 3 — US off-road.
    return const [2, 1, 4, 0, 1, 3, 0, 0, 0, 0];
  }
}

/// Controller tests for the CH dynamic mode, driven through the fake bike: the
/// phone is the speed limiter here, so the wire mode byte the bike ends up with
/// is the thing that matters.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'fa:ke:aa:bb:cc:dd';

  /// A raw mode byte the app never writes, so any write becomes visible.
  const unusedWire = 9;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_bike_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// Lets the fire-and-forget chains (speed stream, writes, db saves) run out.
  /// Deliberately does not advance real time: the 2 s debounce and the 5 s poll
  /// must not fire, so every write a test sees was caused by the test.
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  /// Opens a bike the way the app does (a listener on the provider, state saved
  /// through the notifier) and returns its notifier.
  Future<Bike> openBike(
    ProviderContainer container, {
    required BikeRegion region,
    int mode = 0,
  }) async {
    container.listen(bikeProvider(id), (previous, next) {});
    final bike = container.read(bikeProvider(id).notifier);
    bike.writeStateData(
        BikeState.defaultState(id).copyWith(region: region, mode: mode));
    await settle();
    return bike;
  }

  /// Stands in for the bike's mode byte changing behind the app's back (a lost
  /// write, another app writing a mode, or a power-cycle — the bike itself has
  /// no mode button).
  void setBikeWire(ProviderContainer container, int wire) {
    container
        .read(fakeBikeStoreProvider)
        .write(id, [0, 209, 0, 0, wire, 0, 0, 0, 0, 0]);
  }

  int bikeWire(ProviderContainer container) =>
      container.read(fakeBikeStoreProvider).read(id)[5];

  test('dynamic mode follows the speed over the threshold', () async {
    final container = makeContainer();
    await openBike(container, region: BikeRegion.ch);
    final store = container.read(fakeBikeStoreProvider);
    expect(bikeWire(container), chWireLow,
        reason: 'dynamic mode starts on the throttle wire byte');

    store.setSpeed(id, 10);
    await settle();
    expect(bikeWire(container), chWireLow, reason: 'below the threshold');

    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh, reason: 'above the threshold');
    expect(container.read(bikeProvider(id)).mode, 0,
        reason: 'the app stays in dynamic mode across a transition');

    store.setSpeed(id, 10);
    await settle();
    expect(bikeWire(container), chWireLow, reason: 'back below the threshold');
  });

  test('samples inside a band write only on the transition', () async {
    final container = makeContainer();
    await openBike(container, region: BikeRegion.ch);
    final store = container.read(fakeBikeStoreProvider);

    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh);

    // Nothing changes above the threshold, so nothing may be written: the
    // marker byte survives only if the controller stayed quiet.
    setBikeWire(container, unusedWire);
    for (var speed in [24.0, 31.5, 45.0]) {
      store.setSpeed(id, speed);
      await settle();
    }
    expect(bikeWire(container), unusedWire,
        reason: 'samples that do not cross the threshold must not write');
  });

  test('a zero speed sample keeps the current wire byte', () async {
    final container = makeContainer();
    await openBike(container, region: BikeRegion.ch);
    final store = container.read(fakeBikeStoreProvider);

    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh);

    store.setSpeed(id, 0);
    await settle();
    expect(bikeWire(container), chWireHigh,
        reason: 'a zero speed reading is no information, not "slow"');
  });

  test('CH mode 1 ignores speed samples', () async {
    final container = makeContainer();
    await openBike(container, region: BikeRegion.ch, mode: 1);
    final store = container.read(fakeBikeStoreProvider);

    setBikeWire(container, unusedWire);
    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), unusedWire,
        reason: 'only dynamic mode reacts to speed');
  });

  test('EU modes ignore speed samples', () async {
    final container = makeContainer();
    await openBike(container, region: BikeRegion.eu, mode: 1);
    final store = container.read(fakeBikeStoreProvider);

    setBikeWire(container, unusedWire);
    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), unusedWire,
        reason: 'only dynamic mode reacts to speed');
  });

  test('the poll re-asserts a lost dynamic transition write', () async {
    final container = makeContainer();
    final bike = await openBike(container, region: BikeRegion.ch);
    final store = container.read(fakeBikeStoreProvider);

    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh);

    // The transition write never reached the bike: it is still limiting like
    // US Class 2 while the app thinks it is an EPAC.
    setBikeWire(container, chWireLow);
    await bike.updateStateDataNow();
    await settle();
    expect(bikeWire(container), chWireHigh,
        reason: 'a lost transition write must be re-asserted by the poll');
    expect(container.read(bikeProvider(id)).mode, 0,
        reason: 'both wire bytes read back as dynamic mode');
  });

  test('the poll does not fight a mode the rider set on the bike', () async {
    final container = makeContainer();
    final bike = await openBike(container, region: BikeRegion.ch);
    expect(bikeWire(container), chWireLow);

    // Rider switched the bike itself to off-road.
    setBikeWire(container, chWireOffroad);
    await bike.updateStateDataNow();
    await settle();
    expect(container.read(bikeProvider(id)).mode, 2,
        reason: 'the app must follow a mode it did not set');
    expect(bikeWire(container), chWireOffroad,
        reason: 'the app must not fight the rider');
  });

  test('the poll re-asserts a dynamic CH bike off an unmapped wire byte',
      () async {
    final container = makeContainer();
    final bike = await openBike(container, region: BikeRegion.ch);
    final store = container.read(fakeBikeStoreProvider);

    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh);

    // Another app (or a power-cycle) put the bike on wire 5 — the EU 35 km/h
    // profile, which has no CH mode. The read-back cannot see it: the app
    // would keep claiming dynamic mode while nothing limits the bike to
    // 25 km/h any more.
    setBikeWire(container, 5);
    await bike.updateStateDataNow();
    await settle();
    expect(bikeWire(container), chWireHigh,
        reason: 'in the CH region the app owns the mode: a byte it cannot map '
            'must be re-asserted');
    expect(container.read(bikeProvider(id)).mode, 0,
        reason: 'the app stays in the mode it asserts');
  });

  test('the poll re-asserts a static CH mode off an unmapped wire byte',
      () async {
    final container = makeContainer();
    // CH mode 2 (index 1) is US Class 2, wire byte 1.
    final bike = await openBike(container, region: BikeRegion.ch, mode: 1);
    expect(bikeWire(container), chWireLow);

    // Wire 6 is the EU 45 km/h profile: unmapped for CH, and invisible to the
    // mode comparison because the read-back keeps the old mode.
    setBikeWire(container, 6);
    await bike.updateStateDataNow();
    await settle();
    expect(bikeWire(container), chWireLow,
        reason: 'every CH mode is re-asserted, not just the dynamic one');
    expect(container.read(bikeProvider(id)).mode, 1);
  });

  test('the poll follows the rider to off-road from any CH mode', () async {
    for (var startMode in [0, 1]) {
      final container = makeContainer();
      final bike =
          await openBike(container, region: BikeRegion.ch, mode: startMode);

      // Wire 7 is a byte the CH read-back does map, so it is the rider's.
      setBikeWire(container, chWireOffroad);
      await bike.updateStateDataNow();
      await settle();
      expect(container.read(bikeProvider(id)).mode, 2,
          reason: 'a mapped byte is followed, from mode $startMode');
      expect(bikeWire(container), chWireOffroad,
          reason: 'the app must not fight the rider, from mode $startMode');
    }
  });

  test('a ride data frame on the shared register is not used as settings',
      () async {
    final store = _RideDataStore();
    final container = ProviderContainer(overrides: [
      fakeBikeStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);
    container.listen(bikeProvider(id), (previous, next) {});
    final bike = container.read(bikeProvider(id).notifier);
    bike.writeStateData(
        BikeState.defaultState(id).copyWith(region: BikeRegion.ch, mode: 1));
    await settle();
    final before = container.read(bikeProvider(id));

    // Ride data requests select another register on the same characteristic, so
    // a mis-sequenced read can return one of those frames. Parsed as settings
    // it is a speed byte in assist and wire byte 3 (off-road) in the mode.
    store.serveRideData = true;
    setBikeWire(container, unusedWire);
    await bike.updateStateDataNow(force: true);
    await settle();

    expect(container.read(bikeProvider(id)), before,
        reason: 'a read that is not a settings packet must be dropped');
    expect(bikeWire(container), unusedWire,
        reason: 'and must never be written back to the bike');
  });

  test('deleting a bike tears down its control loop', () async {
    final container = makeContainer();
    // Let the initial (empty) bikes.json load finish, so the only state changes
    // left are the ones this test causes.
    container.read(bikesDBProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final sub = container.listen(bikeProvider(id), (previous, next) {});
    final bike = container.read(bikeProvider(id).notifier);
    // A CH dynamic bike: its notifier is kept alive without any UI.
    bike.writeStateData(
        BikeState.defaultState(id).copyWith(region: BikeRegion.ch));
    await settle();
    final saved = container.read(bikeProvider(id));
    expect(container.read(bikesDBProvider.notifier).getBike(id), isNotNull);

    bike.deleteStateData(saved);
    await settle();
    // The Edit sheet and BikePage are popped right after the delete.
    sub.close();
    await settle();

    // Anything that used to drive a write: a speed sample crossing the
    // threshold, and a poll.
    setBikeWire(container, unusedWire);
    container.read(fakeBikeStoreProvider).setSpeed(id, 30);
    await settle();
    await bike.updateStateDataNow(force: true);
    await settle();

    expect(bikeWire(container), unusedWire,
        reason: 'a deleted bike must not be written to any more');
    expect(container.read(bikesDBProvider.notifier).getBike(id), isNull,
        reason: 'a deleted bike must not be resurrected by its own loop');
  });

  test('a light toggle above the threshold keeps the high wire byte', () async {
    final container = makeContainer();
    final bike = await openBike(container, region: BikeRegion.ch);
    final store = container.read(fakeBikeStoreProvider);

    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh);

    bike.toggleLight();
    await settle();
    expect(container.read(fakeBikeStoreProvider).read(id)[4], 1,
        reason: 'the light must actually be written');
    expect(bikeWire(container), chWireHigh,
        reason: 'toggling the light must not drop the bike back to throttle');
  });

  test('dynamic mode keeps controlling after the UI is gone', () async {
    final container = makeContainer();
    final sub = container.listen(bikeProvider(id), (previous, next) {});
    container.read(bikeProvider(id).notifier).writeStateData(
        BikeState.defaultState(id).copyWith(region: BikeRegion.ch));
    await settle();
    expect(bikeWire(container), chWireLow);

    // BikePage is popped: nothing listens to the provider any more.
    sub.close();
    await settle();

    container.read(fakeBikeStoreProvider).setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh,
        reason: 'the speed limiter must survive the UI unmounting');
  });

  test('dynamic mode survives a connection dropout with no UI', () async {
    final container = makeContainer();
    final sub = container.listen(bikeProvider(id), (previous, next) {});
    container.read(bikeProvider(id).notifier).writeStateData(
        BikeState.defaultState(id).copyWith(region: BikeRegion.ch));
    await settle();
    expect(bikeWire(container), chWireLow);

    // BikePage is popped, and then the bike drops the connection and comes
    // back. A fake bike is otherwise always connected, so the states are set
    // directly. Watching (rather than listening to) the handler would
    // invalidate this notifier here, and with no listeners left riverpod
    // disposes it instead of rebuilding it — killing the limiter for good.
    sub.close();
    await settle();
    for (var next in [
      SDBluetoothConnectionState.disconnected,
      SDBluetoothConnectionState.connected,
    ]) {
      // ignore: invalid_use_of_protected_member
      container.read(connectionHandlerProvider(id).notifier).state = next;
      await settle();
    }

    container.read(fakeBikeStoreProvider).setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh,
        reason: 'a connection dropout must not tear down the controller');
  });

  test('a non-dynamic bike is re-asserted after a reconnect', () async {
    final container = makeContainer();
    // EU mode 2 (index 1) writes wire byte 5.
    await openBike(container, region: BikeRegion.eu, mode: 1);
    expect(bikeWire(container), 5);

    // The bike came back on wire byte 1. For an EU bike that reads back as the
    // very same mode (both 1 and 5 map to index 1), so nothing but a *forced*
    // re-assert can turn it back into a 5: an unforced read finds no
    // difference and returns early.
    setBikeWire(container, 1);
    for (var next in [
      SDBluetoothConnectionState.disconnected,
      SDBluetoothConnectionState.connected,
    ]) {
      // ignore: invalid_use_of_protected_member
      container.read(connectionHandlerProvider(id).notifier).state = next;
      await settle();
    }
    expect(bikeWire(container), 1,
        reason: 'the re-assert waits out the connect settle first');

    // Real time, because the re-assert deliberately waits a second for the
    // transport's own connect-time register use. Still short of the 2 s
    // debounce and the 5 s poll, so nothing else can cause this write.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await settle();
    expect(bikeWire(container), 5,
        reason: 'every bike, not just a dynamic one, is re-asserted on '
            'reconnect instead of waiting for the next poll');
  });

  test('a failed write is not reported as applied', () async {
    final container = ProviderContainer(overrides: [
      fakeBikeStoreProvider.overrideWithValue(_FailingWriteStore()),
    ]);
    addTearDown(container.dispose);
    container.listen(bikeProvider(id), (previous, next) {});
    final bike = container.read(bikeProvider(id).notifier);
    bike.writeStateData(
        BikeState.defaultState(id).copyWith(region: BikeRegion.ch));
    await settle();

    bike.toggleLight();
    await settle();
    expect(container.read(bikeProvider(id)).light, isFalse,
        reason: 'a write that threw must not update the app state');
  });

  group('background lock ownership', () {
    /// Stands in for the Android-only auto-enable, which cannot run in tests.
    Future<Bike> autoLockedBike(ProviderContainer container,
        {required bool auto}) async {
      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(BikeState.defaultState(id).copyWith(
          region: BikeRegion.ch, modeLock: true, modeLockAuto: auto));
      await settle();
      return bike;
    }

    test('leaving dynamic mode turns off the lock it turned on', () async {
      final container = makeContainer();
      final bike = await autoLockedBike(container, auto: true);

      bike.toggleMode();
      await settle();
      final state = container.read(bikeProvider(id));
      expect(state.isDynamicMode, isFalse);
      expect(state.modeLock, isFalse,
          reason: 'dynamic mode cleans up its own lock');
      expect(state.modeLockAuto, isFalse);
    });

    test('a lock the rider turned on is left alone', () async {
      final container = makeContainer();
      final bike = await autoLockedBike(container, auto: false);

      bike.toggleMode();
      await settle();
      final state = container.read(bikeProvider(id));
      expect(state.isDynamicMode, isFalse);
      expect(state.modeLock, isTrue,
          reason: 'a rider enabled lock is never auto-disabled');
    });

    test('a rider toggle takes the lock over from dynamic mode', () async {
      final container = makeContainer();
      final bike = await autoLockedBike(container, auto: true);

      // Rider turns the lock off and on again: it is theirs now.
      bike.toggleBackgroundLock();
      await settle();
      bike.toggleBackgroundLock();
      await settle();
      expect(container.read(bikeProvider(id)).modeLock, isTrue);
      expect(container.read(bikeProvider(id)).modeLockAuto, isFalse);

      bike.toggleMode();
      await settle();
      expect(container.read(bikeProvider(id)).modeLock, isTrue,
          reason: 'leaving dynamic mode must not undo the rider');
    });
  });
}

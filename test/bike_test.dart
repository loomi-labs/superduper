import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/db.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/utils/logger.dart';

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

/// A bike whose next [failWrites] writes fail, standing in for a settings write
/// that never reached the controller.
class _FlakyWriteStore extends FakeBikeStore {
  int failWrites = 0;

  @override
  void write(String deviceId, List<int> data) {
    if (failWrites > 0) {
      failWrites--;
      throw Exception('BLE write failed');
    }
    super.write(deviceId, data);
  }
}

/// A bike that lets a test act at the exact moment a write composes its fresh
/// read — i.e. from inside the register queue slot that write holds.
class _ReentrantReadStore extends FakeBikeStore {
  void Function()? onRead;

  @override
  List<int> read(String deviceId) {
    final callback = onRead;
    onRead = null;
    callback?.call();
    return super.read(deviceId);
  }
}

/// A switching custom mode: base wire 1 (32 km/h + throttle), cap wire 4
/// (EPAC 25). Switches up above 30 km/h, back down below 28.
const tour30 =
    CustomMode(id: 'c1', name: 'Tour 30', limitKmh: 30, throttle: true);

/// An exact firmware match (US Class 3, wire 2): base == cap, never switches.
const sport45 = CustomMode(id: 'c2', name: 'Sport 45', limitKmh: 45);

/// Base wire 2, cap wire 5 — a pair that contains neither [chWireLow] nor any
/// wire of the other modes here.
const fast40 = CustomMode(id: 'c3', name: 'Fast 40', limitKmh: 40);

/// Controller tests, driven through the fake bike: the phone is the speed
/// limiter for a switching custom mode, so the wire mode byte the bike ends up
/// with is the thing that matters.
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

  /// Puts bikes into bikes.json before anything reads it, so a bike can be
  /// restored the way an app restart restores it.
  void seedBikesFile(List<BikeState> bikes) {
    File('${tempDir.path}/bikes.json').writeAsStringSync(jsonEncode(bikes));
  }

  /// Waits out the asynchronous bikes.json load of [BikesDB].
  Future<void> loadBikesDB(ProviderContainer container) async {
    container.read(bikesDBProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// Opens a bike the way the app does (a listener on the provider, state saved
  /// through the notifier) and returns its notifier. Defaults to a fresh CH
  /// bike, which rides the seeded 25 km/h switching mode.
  Future<Bike> openBike(
    ProviderContainer container, {
    required BikeRegion region,
    String modeId = seededChModeId,
    List<CustomMode> customModes = const [seededChMode],
  }) async {
    container.listen(bikeProvider(id), (previous, next) {});
    final bike = container.read(bikeProvider(id).notifier);
    bike.writeStateData(BikeState.defaultState(id)
        .copyWith(region: region, customModes: customModes)
        .withSelectedMode(modeId));
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

  int bikeAssist(ProviderContainer container) =>
      container.read(fakeBikeStoreProvider).read(id)[2];

  int bikeLight(ProviderContainer container) =>
      container.read(fakeBikeStoreProvider).read(id)[4];

  String selectedId(ProviderContainer container) =>
      container.read(bikeProvider(id)).selectedMode.id;

  group('speed switching', () {
    test('a switching mode follows the speed over its limit', () async {
      final container = makeContainer();
      await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);
      expect(bikeWire(container), chWireLow,
          reason: 'a switching mode starts on its base profile');

      store.setSpeed(id, 10);
      await settle();
      expect(bikeWire(container), chWireLow, reason: 'below the limit');

      store.setSpeed(id, 30);
      await settle();
      expect(bikeWire(container), chWireHigh, reason: 'above the limit');
      expect(selectedId(container), seededChModeId,
          reason: 'the app stays in the same mode across a transition');

      store.setSpeed(id, 10);
      await settle();
      expect(bikeWire(container), chWireLow, reason: 'back below the limit');
    });

    test('every mode switches at its own limit', () async {
      final container = makeContainer();
      await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
      final store = container.read(fakeBikeStoreProvider);
      expect(bikeWire(container), 1, reason: 'Tour 30 rides US Class 2 below');

      store.setSpeed(id, 30);
      await settle();
      expect(bikeWire(container), 1, reason: 'riding at the limit is not over');

      store.setSpeed(id, 35);
      await settle();
      expect(bikeWire(container), 4, reason: 'over 30 the 25 km/h cap engages');

      store.setSpeed(id, 29);
      await settle();
      expect(bikeWire(container), 4, reason: 'inside the hysteresis band');

      store.setSpeed(id, 27.9);
      await settle();
      expect(bikeWire(container), 1, reason: 'below the band it switches back');
    });

    test('samples inside a band write only on the transition', () async {
      final container = makeContainer();
      await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);

      store.setSpeed(id, 30);
      await settle();
      expect(bikeWire(container), chWireHigh);

      // Nothing changes above the limit, so nothing may be written: the marker
      // byte survives only if the controller stayed quiet.
      setBikeWire(container, unusedWire);
      for (var speed in [24.0, 31.5, 45.0]) {
        store.setSpeed(id, speed);
        await settle();
      }
      expect(bikeWire(container), unusedWire,
          reason: 'samples that do not cross the limit must not write');
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

    test('a CH native mode ignores speed samples', () async {
      final container = makeContainer();
      await openBike(container,
          region: BikeRegion.ch, modeId: nativeModeId(chWireOffroad));
      final store = container.read(fakeBikeStoreProvider);

      setBikeWire(container, unusedWire);
      store.setSpeed(id, 30);
      await settle();
      expect(bikeWire(container), unusedWire,
          reason: 'only a switching custom mode reacts to speed');
    });

    test('EU native modes ignore speed samples', () async {
      final container = makeContainer();
      await openBike(container,
          region: BikeRegion.eu,
          modeId: nativeModeId(5),
          customModes: const []);
      final store = container.read(fakeBikeStoreProvider);

      setBikeWire(container, unusedWire);
      store.setSpeed(id, 30);
      await settle();
      expect(bikeWire(container), unusedWire,
          reason: 'only a switching custom mode reacts to speed');
    });

    test('an exact-match custom mode is really static', () async {
      final container = makeContainer();
      await openBike(container,
          region: BikeRegion.us,
          modeId: sport45.id,
          customModes: const [sport45]);
      final store = container.read(fakeBikeStoreProvider);
      expect(container.read(bikeProvider(id)).needsSpeedSwitching, isFalse);
      expect(bikeWire(container), 2,
          reason: 'one profile does the whole job: US Class 3');

      setBikeWire(container, unusedWire);
      for (var speed in [10.0, 44.0, 45.0, 46.0, 60.0, 20.0, 0.0]) {
        store.setSpeed(id, speed);
        await settle();
      }
      expect(bikeWire(container), unusedWire,
          reason: 'a mode with nothing to switch never writes on speed');
    });

    test('an exact-match custom mode is not kept alive without UI', () async {
      final container = makeContainer();
      final sub = container.listen(bikeProvider(id), (previous, next) {});
      container.read(bikeProvider(id).notifier).writeStateData(
          BikeState.defaultState(id)
              .copyWith(region: BikeRegion.us, customModes: const [sport45])
              .withSelectedMode(sport45.id));
      await settle();
      expect(container.exists(bikeProvider(id)), isTrue);

      // BikePage is popped: with nothing to limit, the control loop has no
      // reason to outlive it.
      sub.close();
      await settle();
      expect(container.exists(bikeProvider(id)), isFalse,
          reason: 'a static mode must not hold the notifier alive');
    });

    test('a switching mode keeps controlling after the UI is gone', () async {
      final container = makeContainer();
      final sub = container.listen(bikeProvider(id), (previous, next) {});
      container.read(bikeProvider(id).notifier).writeStateData(
          BikeState.defaultState(id)
              .copyWith(region: BikeRegion.us, customModes: const [tour30])
              .withSelectedMode(tour30.id));
      await settle();
      expect(bikeWire(container), 1);

      // BikePage is popped: nothing listens to the provider any more.
      sub.close();
      await settle();
      expect(container.exists(bikeProvider(id)), isTrue,
          reason: 'a switching mode holds the notifier alive');

      container.read(fakeBikeStoreProvider).setSpeed(id, 35);
      await settle();
      expect(bikeWire(container), 4,
          reason: 'the speed limiter must survive the UI unmounting');
    });

    test('a switching mode survives a connection dropout with no UI', () async {
      final container = makeContainer();
      final sub = container.listen(bikeProvider(id), (previous, next) {});
      container.read(bikeProvider(id).notifier).writeStateData(
          BikeState.defaultState(id)
              .copyWith(region: BikeRegion.us, customModes: const [tour30])
              .withSelectedMode(tour30.id));
      await settle();
      expect(bikeWire(container), 1);

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

      container.read(fakeBikeStoreProvider).setSpeed(id, 35);
      await settle();
      expect(bikeWire(container), 4,
          reason: 'a connection dropout must not tear down the controller');
    });
  });

  group('wire verdict in the poll', () {
    test('the poll re-asserts a lost transition write', () async {
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
      expect(selectedId(container), seededChModeId,
          reason: 'the app owns which half of the pair it is on');
    });

    test('the poll heals a custom mode off a foreign wire', () async {
      // Another app (or a power-cycle) put the bike on a profile that is not
      // the mode's. Wires stopped being 1:1 with modes, so there is nothing to
      // follow: the app composed this mode and has to put it back.
      for (final (region, modeId, customModes, foreign, expected)
          in <(BikeRegion, String, List<CustomMode>, int, int)>[
        (BikeRegion.ch, seededChModeId, [seededChMode], 5, chWireLow),
        (BikeRegion.us, tour30.id, [tour30], 6, 1),
        (BikeRegion.eu, tour30.id, [tour30], 0, 1),
        (BikeRegion.us, sport45.id, [sport45], 6, 2),
      ]) {
        final container = makeContainer();
        final bike = await openBike(container,
            region: region, modeId: modeId, customModes: customModes);
        expect(bikeWire(container), expected, reason: '$region $modeId');

        setBikeWire(container, foreign);
        await bike.updateStateDataNow();
        await settle();
        expect(bikeWire(container), expected,
            reason: '$region $modeId must be re-asserted off wire $foreign');
        expect(selectedId(container), modeId,
            reason: '$region $modeId: the app stays in the mode it asserts');
      }
    });

    test('the poll heals a native mode off another bank wire', () async {
      // Deliberately not the old mod-4 remap: an EU bike reporting wire 1 is
      // not "EU mode 2", it is a bike that left the mode the app selected.
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.eu,
          modeId: nativeModeId(5),
          customModes: const []);
      expect(bikeWire(container), 5);

      setBikeWire(container, 1);
      await bike.updateStateDataNow();
      await settle();
      expect(bikeWire(container), 5,
          reason: 'a wire from another region bank is healed, not adopted');
      expect(selectedId(container), nativeModeId(5));
    });

    test('the poll follows a native mode of the same bank', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: nativeModeId(2),
          customModes: const []);
      expect(bikeWire(container), 2);

      // Another app selected US Class 2: a mode this bike really has.
      setBikeWire(container, 1);
      await bike.updateStateDataNow();
      await settle();
      expect(selectedId(container), nativeModeId(1),
          reason: 'the app must follow a mode it did not set');
      expect(bikeWire(container), 1, reason: 'and must not fight the rider');
    });

    test('a locked mode is healed instead of followed', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: nativeModeId(2),
          customModes: const []);
      bike.toggleModeLocked();
      await settle();
      expect(container.read(bikeProvider(id)).modeLocked, isTrue);

      setBikeWire(container, 1);
      await bike.updateStateDataNow();
      await settle();
      expect(selectedId(container), nativeModeId(2),
          reason: 'a locked mode does not follow the bike');
      expect(bikeWire(container), 2,
          reason: 'and the locked mode is written back');
    });

    test('the poll follows the rider to off-road, in every region', () async {
      for (final (region, modeId, customModes, reported, want)
          in <(BikeRegion, String, List<CustomMode>, int, int)>[
        (BikeRegion.ch, seededChModeId, [seededChMode], chWireOffroad,
            chWireOffroad),
        (BikeRegion.ch, seededChModeId, [seededChMode], chWireUsOffroad,
            chWireOffroad),
        (BikeRegion.ch, nativeModeId(chWireOffroad), [seededChMode],
            chWireOffroad, chWireOffroad),
        (BikeRegion.us, tour30.id, [tour30], chWireUsOffroad, chWireUsOffroad),
        (BikeRegion.eu, tour30.id, [tour30], chWireOffroad, chWireOffroad),
        (BikeRegion.us, sport45.id, [sport45], chWireUsOffroad, chWireUsOffroad),
      ]) {
        final container = makeContainer();
        final bike = await openBike(container,
            region: region, modeId: modeId, customModes: customModes);

        // Both 3 and 7 are unlimited with a throttle: the bike really is
        // off-road, and the app has to say so rather than pull it back.
        setBikeWire(container, reported);
        await bike.updateStateDataNow();
        await settle();
        expect(selectedId(container), nativeModeId(want),
            reason: '$region $modeId on wire $reported');
        expect(bikeWire(container), want,
            reason: '$region $modeId: the app must not fight the rider');
        expect(container.read(bikeProvider(id)).needsSpeedSwitching, isFalse,
            reason: '$region $modeId: off-road never switches');
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
      bike.writeStateData(BikeState.defaultState(id)
          .copyWith(region: BikeRegion.ch)
          .withSelectedMode(nativeModeId(chWireOffroad)));
      await settle();
      final before = container.read(bikeProvider(id));

      // Ride data requests select another register on the same characteristic,
      // so a mis-sequenced read can return one of those frames. Parsed as
      // settings it is a speed byte in assist and wire byte 3 (off-road) in the
      // mode.
      store.serveRideData = true;
      setBikeWire(container, unusedWire);
      await bike.updateStateDataNow(force: true);
      await settle();

      expect(container.read(bikeProvider(id)), before,
          reason: 'a read that is not a settings packet must be dropped');
      expect(bikeWire(container), unusedWire,
          reason: 'and must never be written back to the bike');
    });
  });

  group('mode selection', () {
    test('selectMode moves the bike onto the new mode initial wire', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: nativeModeId(0),
          customModes: const [tour30, fast40]);
      expect(bikeWire(container), 0);

      bike.selectMode(tour30.id);
      await settle();
      expect(bikeWire(container), 1, reason: 'Tour 30 enters on its base');
      expect(container.read(bikeProvider(id)).needsSpeedSwitching, isTrue);

      bike.selectMode(nativeModeId(3));
      await settle();
      expect(bikeWire(container), 3);
      expect(container.read(bikeProvider(id)).needsSpeedSwitching, isFalse);
    });

    test('custom A to custom B resets to B base wire', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: tour30.id,
          customModes: const [tour30, fast40]);
      final store = container.read(fakeBikeStoreProvider);

      store.setSpeed(id, 35);
      await settle();
      expect(bikeWire(container), 4, reason: 'Tour 30 is on its cap profile');

      bike.selectMode(fast40.id);
      await settle();
      expect(bikeWire(container), 2,
          reason: 'the new mode enters on its own base, not on the wire the '
              'old one happened to be asserting');

      // And the new mode's own pair is what the speed follows from here.
      store.setSpeed(id, 41);
      await settle();
      expect(bikeWire(container), 5);
    });

    test('selectMode moves a CH bike between its seeded mode and off-road',
        () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.ch, modeId: nativeModeId(chWireOffroad));
      // CH selectable modes: [the seeded 25 km/h mode, off-road].
      expect(selectedId(container), nativeModeId(chWireOffroad));

      bike.selectMode(seededChModeId);
      await settle();
      expect(selectedId(container), seededChModeId);
      expect(bikeWire(container), chWireLow);

      bike.selectMode(nativeModeId(chWireOffroad));
      await settle();
      expect(selectedId(container), nativeModeId(chWireOffroad));
      expect(bikeWire(container), chWireOffroad);
    });

    test('upsertCustomMode editing the selected mode re-initialises the wire',
        () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
      expect(bikeWire(container), 1);

      // 45 km/h without a throttle is an exact firmware match: one wire, and
      // nothing left to switch. The wire the mode was asserting is not even in
      // the new mode's pair.
      bike.upsertCustomMode(
          tour30.copyWith(limitKmh: 45, throttle: false));
      await settle();
      expect(bikeWire(container), 2,
          reason: 'the edited mode is entered on its new base profile');
      expect(container.read(bikeProvider(id)).needsSpeedSwitching, isFalse);
      expect(container.read(bikeProvider(id)).customModes.single.limitKmh, 45);
    });

    test('renaming the selected mode leaves the bike where it is', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
      final store = container.read(fakeBikeStoreProvider);

      store.setSpeed(id, 35);
      await settle();
      expect(bikeWire(container), 4, reason: 'riding on the cap profile');
      final entered = store.rideDataRequests(id);

      bike.upsertCustomMode(tour30.copyWith(name: 'Commute'));
      await settle();
      expect(bikeWire(container), 4,
          reason: 'a rename must not lift the cap back to the base profile '
              'while the rider is over the limit');
      expect(store.rideDataRequests(id), entered,
          reason: 'and must not re-run the one-off setup, which asks for the '
              'notification permission again');
      expect(container.read(bikeProvider(id)).selectedMode.name, 'Commute');
    });

    test('an edit that keeps the profile pair keeps the wire', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
      final store = container.read(fakeBikeStoreProvider);

      store.setSpeed(id, 35);
      await settle();
      expect(bikeWire(container), 4);

      // 28 km/h with a throttle resolves to the same base/cap pair as 30, so
      // the wire the bike is on is still one this mode asserts.
      bike.upsertCustomMode(tour30.copyWith(limitKmh: 28));
      await settle();
      expect(bikeWire(container), 4);
    });

    test('custom A to B re-runs the one-off setup for B', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: tour30.id,
          customModes: const [tour30, fast40]);
      final store = container.read(fakeBikeStoreProvider);
      final entered = store.rideDataRequests(id);

      bike.selectMode(fast40.id);
      await settle();
      expect(store.rideDataRequests(id), greaterThan(entered),
          reason: 'the new mode has to ask for its own speed stream');
    });

    test('upsertCustomMode adds a mode without touching the bike', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);

      setBikeWire(container, unusedWire);
      bike.upsertCustomMode(fast40);
      await settle();
      expect(bikeWire(container), unusedWire,
          reason: 'a mode the bike is not on changes nothing on the wire');
      expect(container.read(bikeProvider(id)).customModes,
          const [tour30, fast40]);
      expect(container.read(bikesDBProvider.notifier).getBike(id)?.customModes,
          const [tour30, fast40],
          reason: 'but it is saved');
    });

    test('deleteCustomMode falls back and tears the switching mode down',
        () async {
      final container = makeContainer();
      final sub = container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(BikeState.defaultState(id)
          .copyWith(
              region: BikeRegion.us,
              customModes: const [tour30],
              modeLock: true,
              modeLockAuto: true)
          .withSelectedMode(tour30.id));
      await settle();
      expect(bikeWire(container), 1);

      bike.deleteCustomMode(tour30.id);
      await settle();
      final state = container.read(bikeProvider(id));
      expect(state.selectedMode.id, nativeModeId(0),
          reason: 'US falls back to its slowest limited native mode');
      expect(bikeWire(container), 0,
          reason: 'and the fallback wire goes to the bike');
      expect(state.customModes, isEmpty);
      expect(state.needsSpeedSwitching, isFalse);
      expect(state.modeLock, isFalse,
          reason: 'the lock the switching mode turned on goes with it');
      expect(state.modeLockAuto, isFalse);

      sub.close();
      await settle();
      expect(container.exists(bikeProvider(id)), isFalse,
          reason: 'and nothing holds the control loop alive any more');
    });

    test('a mode edit is saved with the bike out of range', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
      setBikeWire(container, unusedWire);
      // ignore: invalid_use_of_protected_member
      container.read(connectionHandlerProvider(id).notifier).state =
          SDBluetoothConnectionState.disconnected;
      await settle();

      bike.upsertCustomMode(tour30.copyWith(limitKmh: 45, throttle: false));
      await settle();
      expect(container.read(bikeProvider(id)).customModes.single.limitKmh, 45,
          reason: 'a mode the rider authored must not be dropped for being '
              'out of range — that is what the heal and the reconnect '
              're-assert are for');
      expect(
          container
              .read(bikesDBProvider.notifier)
              .getBike(id)
              ?.customModes
              .single
              .limitKmh,
          45,
          reason: 'and it is on disk, not only in memory');
      expect(bikeWire(container), unusedWire,
          reason: 'nothing can go on the wire while disconnected');
    });

    test('a mode delete is saved with the bike out of range', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
      setBikeWire(container, unusedWire);
      // ignore: invalid_use_of_protected_member
      container.read(connectionHandlerProvider(id).notifier).state =
          SDBluetoothConnectionState.disconnected;
      await settle();

      bike.deleteCustomMode(tour30.id);
      await settle();
      final saved = container.read(bikesDBProvider.notifier).getBike(id);
      expect(container.read(bikeProvider(id)).customModes, isEmpty);
      expect(saved?.customModes, isEmpty,
          reason: 'the deletion is the rider\'s, not the connection\'s');
      expect(saved?.selectedMode.id, nativeModeId(0),
          reason: 'and the selection falls back with it');
      expect(bikeWire(container), unusedWire);
    });

    test('a heal after a pair-changing edit writes a wire the mode asserts',
        () async {
      final store = _FlakyWriteStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(BikeState.defaultState(id)
          .copyWith(region: BikeRegion.us, customModes: const [tour30])
          .withSelectedMode(tour30.id));
      await settle();
      expect(store.read(id)[5], 1);

      // The transition write to the cap profile is lost, so the app asserts
      // wire 4 while the bike is still on wire 1.
      store.failWrites = 1;
      store.setSpeed(id, 35);
      await settle();
      expect(store.read(id)[5], 1, reason: 'the transition write was lost');

      // Now the mode is edited onto a different profile pair (wires 2 and 5):
      // the wire the app was asserting is one this mode can never write.
      bike.upsertCustomMode(tour30.copyWith(limitKmh: 40, throttle: false));
      await settle();
      expect(store.read(id)[5], 2,
          reason: 'the write must agree with the verdict, which normalises a '
              'wire outside the pair to the mode base profile');

      // And the poll's heal lands on the same wire.
      store.write(id, [0, 209, 0, 0, unusedWire, 0, 0, 0, 0, 0]);
      await bike.updateStateDataNow();
      await settle();
      expect(store.read(id)[5], 2);
    });

    test('a transition write composed before a mode change is dropped',
        () async {
      final store = _ReentrantReadStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(BikeState.defaultState(id)
          .copyWith(region: BikeRegion.us, customModes: const [tour30, sport45])
          .withSelectedMode(tour30.id));
      await settle();
      expect(store.read(id)[5], 1);

      // The rider picks another mode. That write holds the register queue while
      // it composes its fresh read — and exactly then the bike reports a speed
      // over Tour 30's limit, so the transition write is composed from the mode
      // the rider has just left and queues up behind the mode change.
      store.onRead = () => store.setSpeed(id, 35);
      bike.selectMode(sport45.id);
      await settle();

      expect(container.read(bikeProvider(id)).selectedMode.id, sport45.id,
          reason: 'a machine write must never put back the mode the rider '
              'left: the app owns the mode, so nothing would heal it');
      expect(store.read(id)[5], 2,
          reason: 'and must not put that mode wire back either');
      expect(container.read(bikesDBProvider.notifier).getBike(id)?.modeId,
          sport45.id,
          reason: 'least of all in bikes.json');
    });

    test('deleteCustomMode leaves an unselected mode alone', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: tour30.id,
          customModes: const [tour30, fast40]);

      setBikeWire(container, unusedWire);
      bike.deleteCustomMode(fast40.id);
      await settle();
      expect(bikeWire(container), unusedWire,
          reason: 'deleting a mode the bike is not on writes nothing');
      expect(container.read(bikeProvider(id)).customModes, const [tour30]);
      expect(selectedId(container), tour30.id);
    });

    test('deleting the last CH custom mode re-seeds it', () async {
      final container = makeContainer();
      final bike = await openBike(container, region: BikeRegion.ch);

      bike.deleteCustomMode(seededChModeId);
      await settle();
      final state = container.read(bikeProvider(id));
      // CH has no limited native mode: with the list empty its fallback would
      // resolve to a mode that is not in selectableModes at all, and the file
      // would come back off-road.
      expect(state.customModes, const [seededChMode],
          reason: 'a CH bike always keeps a limited mode to fall back to');
      expect(state.selectedMode, const CustomSelection(seededChMode));
      expect(state.selectableModes.contains(state.selectedMode), isTrue);
      expect(bikeWire(container), chWireLow);
      expect(container.read(bikesDBProvider.notifier).getBike(id)?.customModes,
          const [seededChMode],
          reason: 'and it is that way on disk too');
    });

    test('a bike restored on a mode with another base wire asserts it',
        () async {
      // Fast 40 rides wires 2 and 5 — neither of them the constant the old CH
      // dynamic mode started from.
      seedBikesFile([
        BikeState.defaultState(id)
            .copyWith(region: BikeRegion.us, customModes: const [fast40])
            .withSelectedMode(fast40.id)
      ]);
      final container = makeContainer();
      await loadBikesDB(container);
      expect(container.read(bikesDBProvider.notifier).getBike(id)?.selectedMode,
          const CustomSelection(fast40));

      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      await settle();
      // Nothing has been written yet, so the bike still sits where it was.
      setBikeWire(container, 2);

      bike.toggleLight();
      await settle();
      expect(bikeLight(container), 1);
      expect(bikeWire(container), 2,
          reason: 'the asserted wire comes from the restored mode base '
              'profile, not from a constant');
    });
  });

  test('deleting a bike tears down its control loop', () async {
    final container = makeContainer();
    // Let the initial (empty) bikes.json load finish, so the only state changes
    // left are the ones this test causes.
    await loadBikesDB(container);

    final sub = container.listen(bikeProvider(id), (previous, next) {});
    final bike = container.read(bikeProvider(id).notifier);
    // A CH bike on the seeded switching mode: its notifier is kept alive
    // without any UI.
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

    // Anything that used to drive a write: a speed sample crossing the limit,
    // and a poll.
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

  test('a light toggle above the limit keeps the cap wire byte', () async {
    final container = makeContainer();
    final bike = await openBike(container, region: BikeRegion.ch);
    final store = container.read(fakeBikeStoreProvider);

    store.setSpeed(id, 30);
    await settle();
    expect(bikeWire(container), chWireHigh);

    bike.toggleLight();
    await settle();
    expect(bikeLight(container), 1,
        reason: 'the light must actually be written');
    expect(bikeWire(container), chWireHigh,
        reason: 'toggling the light must not drop the bike back to throttle');
  });

  group('packet composition', () {
    test('a threshold crossing keeps an assist level set on the bike',
        () async {
      final container = makeContainer();
      await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);

      store.setSpeed(id, 10);
      await settle();
      expect(bikeWire(container), chWireLow);

      // The rider turns the assist up on the handlebar, after the last read the
      // app did: only a read at write time can see this.
      store.cycleAssist(id);
      store.setSpeed(id, 30);
      await settle();

      expect(bikeAssist(container), 1,
          reason: 'a machine write must not undo the rider');
      expect(bikeWire(container), chWireHigh,
          reason: 'and must still land the transition');
      expect(container.read(bikeProvider(id)).assist, 1,
          reason: 'the app state adopts what was put on the wire');
    });

    test('a threshold crossing keeps a light set on the bike', () async {
      final container = makeContainer();
      await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);

      store.setSpeed(id, 10);
      await settle();

      store.toggleLight(id);
      store.setSpeed(id, 30);
      await settle();

      expect(bikeLight(container), 1, reason: 'a machine write keeps the light');
      expect(bikeWire(container), chWireHigh);
      expect(container.read(bikeProvider(id)).light, isTrue);
    });

    test('a locked assist still wins over the bike', () async {
      final container = makeContainer();
      final bike = await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);

      bike.writeStateData(container
          .read(bikeProvider(id))
          .copyWith(assist: 2, assistLocked: true));
      await settle();
      expect(bikeAssist(container), 2);

      store.cycleAssist(id);
      store.toggleLight(id);
      store.setSpeed(id, 30);
      await settle();

      expect(bikeAssist(container), 2,
          reason: 'a lock pins the app value over bike truth');
      expect(bikeLight(container), 1,
          reason: 'a lock on one field must not stop the other coming off '
              'the bike');
      expect(bikeWire(container), chWireHigh);
    });

    test('a light toggle does not undo an assist set on the bike', () async {
      final container = makeContainer();
      final bike = await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);

      store.cycleAssist(id);
      bike.toggleLight();
      await settle();

      expect(bikeLight(container), 1, reason: 'the light is what the user set');
      expect(bikeAssist(container), 1,
          reason: 'the field the user did not touch comes off the bike');
      expect(container.read(bikeProvider(id)).assist, 1);
    });

    test('an assist change does not undo a light set on the bike', () async {
      final container = makeContainer();
      final bike = await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);

      store.toggleLight(id);
      bike.setAssist(1);
      await settle();

      expect(bikeAssist(container), 1,
          reason: 'the assist is what the user set, not what the bike holds');
      expect(bikeLight(container), 1,
          reason: 'the field the user did not touch comes off the bike');
      expect(container.read(bikeProvider(id)).light, isTrue);
    });

    test('setAssist writes nothing when the level is already set', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.ch, modeId: nativeModeId(chWireOffroad));
      expect(container.read(bikeProvider(id)).assist, 0);

      // Tapping the chip the bike is already on is not a change, and a packet
      // for it would put a poll-interval-old light byte back on the bike.
      setBikeWire(container, unusedWire);
      bike.setAssist(0);
      await settle();

      expect(bikeWire(container), unusedWire,
          reason: 'a no-op assist set must not reach the wire');
    });

    test('a compose read that is not settings falls back to the last known',
        () async {
      final store = _RideDataStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(
          BikeState.defaultState(id).copyWith(region: BikeRegion.ch));
      await settle();
      expect(bikeWire(container), chWireLow);

      // The read the transition write composes from comes back with a ride data
      // frame: assist 4, light on, wire byte 3 (off-road) if it were parsed.
      store.serveRideData = true;
      store.setSpeed(id, 30);
      await settle();

      expect(store.serveRideData, isFalse,
          reason: 'the transition write composes from a read of its own');
      // Read once: reading the store is what serves the ride data frame.
      final register = store.read(id);
      expect(register[5], chWireHigh,
          reason: 'a failed compose read must not cost the transition');
      expect(register[2], 0);
      expect(register[4], 0);
      expect(container.read(bikeProvider(id)).assist, 0,
          reason: 'no ride data byte may reach the packet or the state');
      expect(container.read(bikeProvider(id)).light, isFalse);
    });

    test('the last known value beats app state when a compose read fails',
        () async {
      final store = _RideDataStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(
          BikeState.defaultState(id).copyWith(region: BikeRegion.ch));
      await settle();

      // App state alone moves: nothing goes on the wire, so the bike — and the
      // last known register — still hold assist 0.
      bike.writeStateData(container.read(bikeProvider(id)).copyWith(assist: 3),
          saveToBike: false);
      await settle();
      expect(container.read(bikeProvider(id)).assist, 3);

      store.serveRideData = true;
      store.setSpeed(id, 30);
      await settle();

      expect(store.serveRideData, isFalse);
      final register = store.read(id);
      expect(register[2], 0,
          reason: 'the fallback is the last value read off the bike, not the '
              'app value the bike never got');
      expect(register[5], chWireHigh);
    });
  });

  test('a bike is re-asserted after a reconnect', () async {
    final container = makeContainer();
    await openBike(container,
        region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
    expect(bikeWire(container), 5);

    // The bike came back on wire byte 1.
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
        reason: 'a reconnected bike is re-asserted straight away instead of '
            'waiting for the next poll');
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

    test('leaving a switching mode turns off the lock it turned on', () async {
      final container = makeContainer();
      final bike = await autoLockedBike(container, auto: true);

      bike.selectMode(nativeModeId(chWireOffroad));
      await settle();
      final state = container.read(bikeProvider(id));
      expect(state.needsSpeedSwitching, isFalse);
      expect(state.modeLock, isFalse,
          reason: 'a switching mode cleans up its own lock');
      expect(state.modeLockAuto, isFalse);
    });

    test('a lock the rider turned on is left alone', () async {
      final container = makeContainer();
      final bike = await autoLockedBike(container, auto: false);

      bike.selectMode(nativeModeId(chWireOffroad));
      await settle();
      final state = container.read(bikeProvider(id));
      expect(state.needsSpeedSwitching, isFalse);
      expect(state.modeLock, isTrue,
          reason: 'a rider enabled lock is never auto-disabled');
    });

    test('a rider toggle takes the lock over from the switching mode',
        () async {
      final container = makeContainer();
      final bike = await autoLockedBike(container, auto: true);

      // Rider turns the lock off and on again: it is theirs now.
      bike.toggleBackgroundLock();
      await settle();
      bike.toggleBackgroundLock();
      await settle();
      expect(container.read(bikeProvider(id)).modeLock, isTrue);
      expect(container.read(bikeProvider(id)).modeLockAuto, isFalse);

      bike.selectMode(nativeModeId(chWireOffroad));
      await settle();
      expect(container.read(bikeProvider(id)).modeLock, isTrue,
          reason: 'leaving a switching mode must not undo the rider');
    });

    test('the lock survives a move from one switching mode to another',
        () async {
      final container = makeContainer();
      final bike = await autoLockedBike(container, auto: true);
      bike.upsertCustomMode(tour30);
      await settle();

      bike.selectMode(tour30.id);
      await settle();
      final state = container.read(bikeProvider(id));
      expect(state.needsSpeedSwitching, isTrue);
      expect(state.modeLock, isTrue,
          reason: 'the lock is torn down on leaving, not on changing mode');
      expect(state.modeLockAuto, isTrue);
    });
  });

  group('speedTraceLine', () {
    test('a fresh sample is one greppable line', () {
      expect(
          speedTraceLine(
              speedKmh: 23.06,
              sampleAge: const Duration(seconds: 1),
              maxAge: const Duration(seconds: 5),
              wire: 4),
          'Speed 23.06 km/h, wire 4');
    });

    test('a bike that never reported a speed traces nothing', () {
      expect(
          speedTraceLine(
              speedKmh: null,
              sampleAge: null,
              maxAge: const Duration(seconds: 5),
              wire: 4),
          isNull);
      expect(
          speedTraceLine(
              speedKmh: 12.0,
              sampleAge: null,
              maxAge: const Duration(seconds: 5),
              wire: 4),
          isNull,
          reason: 'a speed with no arrival time cannot be judged for staleness');
    });

    test('a stale sample is dropped rather than repeated', () {
      expect(
          speedTraceLine(
              speedKmh: 23.06,
              sampleAge: const Duration(seconds: 6),
              maxAge: const Duration(seconds: 5),
              wire: 4),
          isNull,
          reason: 'the bike stops streaming at a standstill, and repeating the '
              'last value would log a parked bike as still moving');
    });
  });

  group('the ride log', () {
    /// Attaches the rotating file sink for this test and returns a reader of
    /// what has reached the disk.
    Future<Future<String> Function()> attachRideLog() async {
      final directory = '${tempDir.path}/logs';
      await log.attachFileSink(directory: directory);
      // Before the tearDown that removes tempDir: the file handle has to go
      // first.
      addTearDown(log.detachFileSink);
      return () async {
        await log.flushFileSink();
        return File('$directory/${SDLogger.logFileName}').readAsStringSync();
      };
    }

    test('a poll tick traces the speed with the bike id and the wire',
        () async {
      final container = makeContainer();
      final readLog = await attachRideLog();
      final bike = await openBike(container, region: BikeRegion.ch);

      container.read(fakeBikeStoreProvider).setSpeed(id, 23.06);
      await settle();
      bike.logSpeedTrace();

      expect(await readLog(), contains('[Bike] [$id] Speed 23.06 km/h, wire '),
          reason: 'a ride analysis joins this against the [Bluetooth] lines by '
              'device id, and needs the wire to read the trace');
    });

    test('a bike that reported no speed yet traces nothing', () async {
      final container = makeContainer();
      final readLog = await attachRideLog();
      final bike = await openBike(container, region: BikeRegion.ch);

      bike.logSpeedTrace();

      expect(await readLog(), isNot(contains(' km/h, wire ')),
          reason: 'an invented speed is worse than a gap in the trace');
    });

    test('every notifier line carries the bike it belongs to', () async {
      final container = makeContainer();
      final readLog = await attachRideLog();
      final bike = await openBike(container, region: BikeRegion.ch);

      bike.selectMode(nativeModeId(chWireOffroad));
      await settle();

      expect(await readLog(), contains('[Bike] [$id] Selecting mode:'),
          reason: 'a two-bike session can only be disentangled if every line '
              'says which bike it is about');
    });
  });
}

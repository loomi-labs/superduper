import 'dart:async';
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

/// A bike that records every write, so a test can count how often the app
/// put a given wire byte on the bus.
class _CountingWriteStore extends FakeBikeStore {
  final writes = <List<int>>[];

  @override
  void write(String deviceId, List<int> data) {
    writes.add(List.of(data));
    super.write(deviceId, data);
  }
}

/// A bike that answers every read with something that is not a settings
/// packet at all — a mis-sequenced read, or a firmware frame the app does
/// not know — standing in for a read [readBikeState] must reject outright,
/// distinct from [_RideDataStore]'s specific ride-data frame.
class _GarbageReadStore extends FakeBikeStore {
  @override
  List<int> read(String deviceId) => const [9, 9, 9, 9, 9, 9, 9, 9, 9, 9];
}

/// A bike whose firmware ignores a write to one byte of the settings packet
/// and always reports the same value back, standing in for locked firmware:
/// wire, assist and light are each lockable independently, matching how a
/// real firmware can refuse one control and honour the others.
class _LockedByteStore extends FakeBikeStore {
  _LockedByteStore({this.fixedWire, this.fixedAssist, this.fixedLight});

  final int? fixedWire;
  final int? fixedAssist;
  final bool? fixedLight;

  @override
  void write(String deviceId, List<int> data) {
    if (data.length < 5 || data[0] != 0 || data[1] != 209) {
      super.write(deviceId, data);
      return;
    }
    final forced = List<int>.from(data);
    if (fixedLight != null) {
      forced[2] = fixedLight! ? 1 : 0;
    }
    if (fixedAssist != null) {
      forced[3] = fixedAssist!;
    }
    if (fixedWire != null) {
      forced[4] = fixedWire!;
    }
    super.write(deviceId, forced);
  }
}

/// A bike whose firmware only accepts a write to one of [accepted] wires; a
/// write naming any other wire is applied for light/assist but leaves the
/// wire byte exactly as it was, standing in for firmware that refuses a
/// subset of wires outright (distinct from [_LockedByteStore], which locks a
/// byte to one fixed value regardless of what is written).
class _LimitedWireStore extends FakeBikeStore {
  _LimitedWireStore(this.accepted);

  final Set<int> accepted;

  @override
  void write(String deviceId, List<int> data) {
    if (data.length < 5 ||
        data[0] != 0 ||
        data[1] != 209 ||
        accepted.contains(data[4])) {
      super.write(deviceId, data);
      return;
    }
    final kept = List<int>.from(data);
    kept[4] = read(deviceId)[5];
    super.write(deviceId, kept);
  }
}

/// Records every write like [_CountingWriteStore], and throws on the
/// [failOnWrite]-th one (1-indexed), standing in for a write that never
/// reached the bike — a disconnect or a BLE error partway through a sweep.
class _CountingFlakyStore extends FakeBikeStore {
  _CountingFlakyStore({this.failOnWrite = -1});

  final writes = <List<int>>[];
  final int failOnWrite;
  int _count = 0;

  @override
  void write(String deviceId, List<int> data) {
    _count++;
    writes.add(List.of(data));
    if (_count == failOnWrite) {
      throw Exception('BLE write failed');
    }
    super.write(deviceId, data);
  }
}

/// Combines [_CountingWriteStore] and [_ReentrantReadStore]: records every
/// write, and calls [onRead] once from inside the next read after it is set
/// — the exact seam a test needs to fire the ordinary poll's own read from
/// between two of [Bike.probeCapabilities]'s write-then-read steps, the way
/// the register queue actually interleaves them (see the regression test
/// this exists for).
class _CountingReentrantStore extends FakeBikeStore {
  final writes = <List<int>>[];
  void Function()? onRead;

  @override
  void write(String deviceId, List<int> data) {
    writes.add(List.of(data));
    super.write(deviceId, data);
  }

  @override
  List<int> read(String deviceId) {
    final callback = onRead;
    onRead = null;
    callback?.call();
    return super.read(deviceId);
  }
}

/// A bike whose settings register takes real time to apply a write, exactly
/// like the real device a log first caught this bug on: once [armed], a
/// write's effect is not visible to a read until [applyDelay] has actually
/// elapsed in real time since that write went out — a read taken any sooner
/// sees whatever was already committed before it, never the write just
/// sent. [applyDelay] is shorter than `Bike._probeSettle`, so this fake's
/// lag is caught on the very first read attempt — it exercises the settle
/// wait itself, not the retry loop a later log showed was also needed (see
/// [_OwnScheduleFirmwareStore] for that). Writes before [armed] is set land
/// immediately, the same as the base class, so a test can seed its starting
/// register without waiting out the lag itself.
class _LaggyFirmwareStore extends FakeBikeStore {
  final applyDelay = const Duration(milliseconds: 200);
  bool armed = false;
  List<int>? _pendingData;
  DateTime? _pendingSince;

  @override
  void write(String deviceId, List<int> data) {
    if (!armed) {
      super.write(deviceId, data);
      return;
    }
    _commitIfDue(deviceId);
    _pendingData = List.of(data);
    _pendingSince = DateTime.now();
  }

  @override
  List<int> read(String deviceId) {
    if (armed) {
      _commitIfDue(deviceId);
    }
    return super.read(deviceId);
  }

  /// Commits the pending write into the register, but only once [applyDelay]
  /// has actually elapsed since it went out — the one-write-behind lag a
  /// read taken any sooner has to see.
  void _commitIfDue(String deviceId) {
    final data = _pendingData;
    final since = _pendingSince;
    if (data == null || since == null) {
      return;
    }
    if (DateTime.now().difference(since) >= applyDelay) {
      super.write(deviceId, data);
      _pendingData = null;
      _pendingSince = null;
    }
  }
}

/// A bike whose settings register commits the latest pending write only on
/// its OWN fixed periodic tick, entirely independent of when that write
/// arrived — the shape a later real device log revealed, distinct from
/// [_LaggyFirmwareStore]'s constant per-write lag. Once [armed], reads and
/// writes both check whether a tick boundary has passed since the store's
/// first write; if so, whatever write is still pending gets committed, no
/// matter how recently (or long ago) it was issued.
///
/// This reproduces the log's alternating stale/correct pattern purely from
/// real wall-clock timing: with [tick] longer than one `Bike._probeSettle`
/// wait but shorter than two, a write landing just after a boundary leaves
/// the next boundary nearly a full tick away, so a single fixed-delay read
/// still sees the stale value — while a write landing just before a
/// boundary is caught by that same fixed delay. Which case a given step
/// hits depends only on where its write falls in the store's cycle, not on
/// anything the probe does — exactly the "coin flip" the real log showed.
/// Polling for up to `Bike._probeMaxAttempts` closes the gap: two attempts
/// span more real time than [tick], so a boundary is guaranteed to fall
/// inside the budget no matter where the write landed.
class _OwnScheduleFirmwareStore extends FakeBikeStore {
  final tick = const Duration(milliseconds: 400);
  bool armed = false;
  DateTime? _anchor;
  List<int>? _pending;
  int _appliedTicks = 0;

  @override
  void write(String deviceId, List<int> data) {
    if (!armed) {
      super.write(deviceId, data);
      return;
    }
    _anchor ??= DateTime.now();
    _commitDueTicks(deviceId);
    _pending = List.of(data);
  }

  @override
  List<int> read(String deviceId) {
    if (armed) {
      _commitDueTicks(deviceId);
    }
    return super.read(deviceId);
  }

  /// Commits [_pending] once the store's own tick count (counted from
  /// [_anchor], the first armed write — never from when [_pending] itself
  /// was set) has advanced past the last commit. The tick schedule runs on
  /// its own regardless of write timing, which is the whole point: it is
  /// the bike's clock, not the app's.
  void _commitDueTicks(String deviceId) {
    final anchor = _anchor;
    final pending = _pending;
    if (anchor == null || pending == null) {
      return;
    }
    final ticksElapsed =
        DateTime.now().difference(anchor).inMicroseconds ~/
            tick.inMicroseconds;
    if (ticksElapsed > _appliedTicks) {
      super.write(deviceId, pending);
      _pending = null;
      _appliedTicks = ticksElapsed;
    }
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
    // capabilities/bootSignature are cleared: [BikeState.defaultState] seeds
    // both for a fake id so the debug console and test_driver can reach the
    // controls with no wizard to drive, but every test in this file means an
    // "uncalibrated, unmeasured" bike by "fresh" — that is the behaviour
    // being tested here, not the debug console's own convenience seed.
    bike.writeStateData(BikeState.defaultState(id)
        .copyWith(
            region: region,
            customModes: customModes,
            capabilities: null,
            bootSignature: null)
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

  /// Locks the mode padlock the way a rider does: the pin cycles open, startup
  /// and locked, so a lock is two taps.
  void lockMode(Bike bike) {
    bike.cycleModePin();
    bike.cycleModePin();
  }

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

    test('a write composed before a switch still carries the new wire',
        () async {
      final container = makeContainer();
      await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
      final bike = container.read(bikeProvider(id).notifier);
      final store = container.read(fakeBikeStoreProvider);
      store.setSpeed(id, 10);
      await settle();
      expect(bikeWire(container), 1);

      // The rider changes assist on the handlebar; the poll answers with a
      // write. The speed crosses the limit while that write waits in the
      // register queue — the interleaving of the 2026-08-08 20:12:29 ride log.
      bike.writeStateData(container.read(bikeProvider(id)).copyWith(assist: 3));
      bike.debugHandleSpeedSample(35);
      await settle();

      expect(bikeWire(container), 4,
          reason: 'the queued write must not put the pre-switch wire back');
      expect(bikeAssist(container), 3,
          reason: 'the assist change itself has to land');
    });
  });

  /// A throttle mode above 32 km/h: no capped profile in the table pairs a
  /// throttle with a cap over 32, so it rides EU off-road (wire 7, unlimited)
  /// below its limit and MODE 2 (wire 5, 35 km/h) above it. The firmware holds
  /// no limit on the base, so the APP is the limiter — which is what the two
  /// fail-safes here exist for.
  group('a throttle mode above 32 km/h', () {
    const throttle40 =
        CustomMode(id: 'c40', name: 'T40', limitKmh: 40, throttle: true);

    Future<Bike> openThrottle40(ProviderContainer container) => openBike(
        container,
        region: BikeRegion.ch,
        modeId: throttle40.id,
        customModes: const [seededChMode, throttle40]);

    test('is entered on its cap, and reaches its base on a speed sample',
        () async {
      final container = makeContainer();
      await openThrottle40(container);
      final store = container.read(fakeBikeStoreProvider);
      expect(container.read(bikeProvider(id)).needsSpeedSwitching, isTrue);
      expect(bikeWire(container), 5,
          reason: 'picking the mode must not hand the rider off-road before a '
              'single speed sample has arrived');

      store.setSpeed(id, 20);
      await settle();
      expect(bikeWire(container), chWireOffroad,
          reason: 'a sample below the limit proves the app is watching');

      store.setSpeed(id, 41);
      await settle();
      expect(bikeWire(container), 5, reason: 'over the limit it caps as usual');
    });

    test('goes back to its cap when the speed stream dies', () async {
      final container = makeContainer();
      final bike = await openThrottle40(container);
      final store = container.read(fakeBikeStoreProvider);
      store.setSpeed(id, 20);
      await settle();
      expect(bikeWire(container), chWireOffroad);

      // The bike stopped streaming ride data: the app is now blind, and a
      // limiter that cannot see the speed has to give the bike back to the
      // firmware.
      bike.debugExpireSpeedStream();
      await settle();
      expect(bikeWire(container), 5,
          reason: 'a blind app must not leave the bike unlimited');
    });

    test('a dead speed stream leaves a firmware-limited mode alone', () async {
      final container = makeContainer();
      final bike = await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);
      store.setSpeed(id, 10);
      await settle();
      expect(bikeWire(container), chWireLow);

      // The seeded mode's base profile carries a 32 km/h limiter of its own, so
      // a blind app still leaves a limited bike: nothing to write.
      setBikeWire(container, unusedWire);
      bike.debugExpireSpeedStream();
      await settle();
      expect(bikeWire(container), unusedWire,
          reason: 'the watchdog must only touch a mode with no firmware limit');
    });

    test('comes back on its cap after a reconnect', () async {
      final container = makeContainer();
      await openThrottle40(container);
      container.read(fakeBikeStoreProvider).setSpeed(id, 20);
      await settle();
      expect(bikeWire(container), chWireOffroad);

      for (var next in [
        SDBluetoothConnectionState.disconnected,
        SDBluetoothConnectionState.connected,
      ]) {
        // ignore: invalid_use_of_protected_member
        container.read(connectionHandlerProvider(id).notifier).state = next;
        await settle();
      }
      // Real time, because the re-assert waits out the connect settle.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await settle();
      expect(bikeWire(container), 5,
          reason: 'no speed has arrived on this connection, so nothing says '
              'the app can see the bike');
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
        // One temp directory serves the whole loop, so the record the previous
        // pass saved is still there. Loading it before the bike is built keeps
        // this pass from adopting it.
        await loadBikesDB(container);
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
      lockMode(bike);
      await settle();
      expect(container.read(bikeProvider(id)).pinMode, PinState.locked);

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
        // See the loop above: the previous pass left a record behind, and this
        // pass must not adopt it.
        await loadBikesDB(container);
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

    test('the poll does not heal while a switch write waits in the queue',
        () async {
      final store = _CountingWriteStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      await openBike(container,
          region: BikeRegion.us, modeId: tour30.id, customModes: const [tour30]);
      final bike = container.read(bikeProvider(id).notifier);
      store.setSpeed(id, 10);
      await settle();
      expect(bikeWire(container), 1);

      // The poll read enters the register queue first; the switch decision
      // lands behind it. The read then reports wire 1 — true, but outdated.
      final poll = bike.updateStateDataNow();
      bike.debugHandleSpeedSample(35);
      await poll;
      await settle();

      expect(bikeWire(container), 4);
      final capWrites =
          store.writes.where((d) => d.first == 0 && d[4] == 4).length;
      expect(capWrites, 1,
          reason: 'the queued switch write already asserts wire 4; a heal '
              'would put the same packet on the bus twice');
    });
  });

  group('the power cycle verdict', () {
    /// The whole register, the way the bike itself reports it after a power
    /// cycle. [setBikeWire] cannot stand in for this: it zeroes the light and
    /// the assist bytes, which would make every case differ in all three
    /// values and prove nothing about the wire.
    void setBikeRegister(ProviderContainer container,
            {required bool light, required int assist, required int wire}) =>
        container
            .read(fakeBikeStoreProvider)
            .write(id, [0, 209, light ? 1 : 0, assist, wire, 0, 0, 0, 0, 0]);

    /// Drops the connection and brings it back. A fake bike is otherwise
    /// always connected, so the states are set directly.
    Future<void> cycleConnection(ProviderContainer container) async {
      for (final next in [
        SDBluetoothConnectionState.disconnected,
        SDBluetoothConnectionState.connected,
      ]) {
        // ignore: invalid_use_of_protected_member
        container.read(connectionHandlerProvider(id).notifier).state = next;
        await settle();
      }
    }

    /// Arms the padlocks the way the rider does: a value given here is pinned
    /// on startup, a null one leaves that padlock open.
    Future<void> armStartupPins(ProviderContainer container, Bike bike,
        {String? modeId, bool? light, int? assist}) async {
      bike.writeStateData(
          container.read(bikeProvider(id)).copyWith(
              pinMode: modeId == null ? PinState.open : PinState.startup,
              startupModeId: modeId,
              pinLight: light == null ? PinState.open : PinState.startup,
              startupLight: light,
              pinAssist: assist == null ? PinState.open : PinState.startup,
              startupAssist: assist),
          saveToBike: false);
      await settle();
    }

    /// A US bike on its mildest native mode, with one read behind it — so the
    /// app knows what this bike last reported.
    Future<Bike> readBike(ProviderContainer container) async {
      final bike = await openBike(container,
          region: BikeRegion.us, modeId: nativeModeId(0), customModes: const []);
      await bike.updateStateDataNow();
      await settle();
      return bike;
    }

    test('a dropout applies nothing', () async {
      final container = makeContainer();
      final bike = await readBike(container);
      await armStartupPins(container, bike,
          modeId: nativeModeId(3), light: true, assist: 4);

      // The bike kept every value it reported, so it never lost power.
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), nativeModeId(0),
          reason: 'a signal dropout must not start a new ride');
      expect(bikeWire(container), 0);
      expect(bikeLight(container), 0);
      expect(bikeAssist(container), 0);
    });

    test('a power cycle applies the pins', () async {
      final container = makeContainer();
      final bike = await readBike(container);
      await armStartupPins(container, bike,
          modeId: nativeModeId(3), light: false, assist: 4);

      // The bike came back reporting none of the values it reported before:
      // it lost its settings, so it was switched off and on again.
      setBikeRegister(container, light: true, assist: 2, wire: 1);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), nativeModeId(3),
          reason: 'the ride starts on the pinned mode');
      expect(bikeWire(container), 3, reason: 'and the mode reaches the bike');
      expect(bikeLight(container), 0, reason: 'the light is pinned off');
      expect(bikeAssist(container), 4);
    });

    test('an unconfirmed write is not a power cycle', () async {
      final container = makeContainer();
      final bike = await readBike(container);
      await armStartupPins(container, bike,
          modeId: nativeModeId(3), light: true, assist: 4);

      // The write is lost to the disconnect: the app intends assist 3, the
      // bike never confirmed it. The 2026-08-07 ride log has nine of these in
      // one ride, and comparing against intent would call every one of them a
      // power cycle.
      bike.writeStateData(
          container.read(bikeProvider(id)).copyWith(assist: 3),
          saveToBike: false);
      await settle();
      expect(container.read(bikeProvider(id)).assist, 3);
      expect(bikeAssist(container), 0,
          reason: 'the harness has to hold app intent apart from bike truth, '
              'or this test proves nothing');

      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), nativeModeId(0),
          reason: 'the bike reports what it always reported');
      expect(bikeLight(container), 0);
      expect(bikeAssist(container), isNot(4),
          reason: 'app intent must never answer the power cycle question');
    });

    test('a switching mode cap wire is not a power cycle', () async {
      final container = makeContainer();
      // The seeded CH mode: base wire [chWireLow], cap wire [chWireHigh].
      final bike = await openBike(container, region: BikeRegion.ch);
      await bike.updateStateDataNow();
      await settle();
      await armStartupPins(container, bike,
          modeId: nativeModeId(chWireOffroad), light: true, assist: 4);

      // The bike is on the other half of the mode's own profile pair, which is
      // no memory loss at all.
      setBikeRegister(container, light: false, assist: 0, wire: chWireHigh);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), seededChModeId,
          reason: 'both wires of the pair mean the bike kept its mode');
      expect(bikeLight(container), 0);
      expect(bikeAssist(container), 0);
    });

    test('no record means the pins are applied', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us, modeId: nativeModeId(0), customModes: const []);
      expect(container.read(bikeProvider(id)).lastSeen, isNull,
          reason: 'nothing has been read off this bike yet');
      await armStartupPins(container, bike,
          modeId: nativeModeId(3), light: true, assist: 4);

      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), nativeModeId(3),
          reason: 'a bike the app never read has no state it can claim to be '
              'preserving');
      expect(bikeWire(container), 3);
      expect(bikeLight(container), 1);
      expect(bikeAssist(container), 4);
    });

    test('an open padlock applies nothing on a power cycle', () async {
      final container = makeContainer();
      final bike = await readBike(container);
      // The pinned values are there, and every padlock is open.
      bike.writeStateData(
          container.read(bikeProvider(id)).copyWith(
              startupModeId: nativeModeId(3),
              startupLight: false,
              startupAssist: 4),
          saveToBike: false);
      await settle();

      setBikeRegister(container, light: true, assist: 2, wire: 1);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), nativeModeId(1),
          reason: 'an open padlock follows the bike');
      expect(bikeLight(container), 1, reason: 'the pinned value is not read');
      expect(bikeAssist(container), 2);
    });

    test('a handlebar change mid ride is not a power cycle', () async {
      final container = makeContainer();
      final bike = await readBike(container);
      await armStartupPins(container, bike,
          modeId: nativeModeId(3), light: true, assist: 4);

      // The rider turns the assist up on the bike itself, with no outage at
      // all. The question is asked once per outage: asking it again here would
      // read the rider as a power cycle and write the pins over their change.
      container.read(fakeBikeStoreProvider).cycleAssist(id);
      await bike.updateStateDataNow();
      await settle();

      expect(bikeAssist(container), 1,
          reason: 'the app follows the rider between outages');
      expect(selectedId(container), nativeModeId(0));
      expect(bikeLight(container), 0);
    });

    test('a locked padlock keeps forcing its value through a power cycle',
        () async {
      final container = makeContainer();
      final bike = await readBike(container);
      bike.toggleLight();
      await settle();
      await bike.updateStateDataNow();
      await settle();
      expect(bikeLight(container), 1);
      // Locked, with a startup value beside it that a locked padlock must
      // ignore.
      bike.writeStateData(
          container
              .read(bikeProvider(id))
              .copyWith(pinLight: PinState.locked, startupLight: false),
          saveToBike: false);
      await settle();

      setBikeRegister(container, light: false, assist: 2, wire: 0);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(bikeLight(container), 1,
          reason: 'a locked padlock holds its value as it always did');
    });

    /// Gives the bike the signature the setup wizard leaves behind on the
    /// 2026-08-11 hardware: the wire byte resets to [bootWire] on both boots,
    /// and the assist byte comes back exactly as the probe's own parting
    /// value, so it is unusable. Built through [classifyCapabilityBoot]
    /// rather than a direct [BootSignature], so this stays a faithful stand-in
    /// for what the real two-boot wizard would save.
    Future<void> calibrate(Bike bike, ProviderContainer container,
        {required int preOffWire, required int bootWire}) async {
      final signature = classifyCapabilityBoot(
          bootA: (light: false, assist: 2, wire: bootWire),
          parting: (light: false, assist: 2, wire: preOffWire),
          bootB: (light: false, assist: 2, wire: bootWire),
          measuredAt: DateTime(2026, 8, 11));
      bike.writeStateData(
          container.read(bikeProvider(id)).copyWith(bootSignature: signature),
          saveToBike: false);
      await settle();
    }

    test('a boot to the measured wire applies the pins inside the mode pair',
        () async {
      final container = makeContainer();
      // The seeded CH mode rides [chWireLow] below 25 km/h and [chWireHigh]
      // above it — and [chWireHigh] is the wire this bike boots on. The old
      // verdict forgave the boot wire because the mode asserts it, so five real
      // boots on 2026-08-11 applied no pin at all.
      final bike = await openBike(container, region: BikeRegion.ch);
      await bike.updateStateDataNow();
      await settle();
      expect(container.read(bikeProvider(id)).lastSeen?.wire, chWireLow,
          reason: 'the bike rides the base of its own pair');
      await calibrate(bike, container, preOffWire: chWireLow, bootWire: chWireHigh);
      await armStartupPins(container, bike,
          modeId: nativeModeId(chWireOffroad), assist: 4);

      setBikeRegister(container, light: false, assist: 0, wire: chWireHigh);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), nativeModeId(chWireOffroad),
          reason: 'the bike came up on the wire it was measured to boot on');
      expect(bikeWire(container), chWireOffroad);
      expect(bikeAssist(container), 4);
    });

    test('an uncalibrated bike keeps the forgiving verdict', () async {
      final container = makeContainer();
      final bike = await openBike(container, region: BikeRegion.ch);
      await bike.updateStateDataNow();
      await settle();
      expect(container.read(bikeProvider(id)).bootSignature, isNull,
          reason: 'the rider never ran the guide, as every migrated bike');
      await armStartupPins(container, bike,
          modeId: nativeModeId(chWireOffroad), assist: 4);

      // The same boot as the test above, with nothing measured to compare it
      // against: the app has to stay on the old verdict, which reads both
      // wires of the pair as the mode the bike kept.
      setBikeRegister(container, light: false, assist: 0, wire: chWireHigh);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), seededChModeId,
          reason: 'an uncalibrated bike must behave exactly as before');
      expect(bikeAssist(container), isNot(4));
    });

    test('a dropout on the boot wire applies nothing', () async {
      final container = makeContainer();
      final bike = await openBike(container, region: BikeRegion.ch);
      final store = container.read(fakeBikeStoreProvider);
      // Over the limit, so the mode caps itself on [chWireHigh] — the wire this
      // bike also boots on. The accepted blind spot: the bike sat on its boot
      // wire before the outage, so a boot and a dropout report the same bytes.
      store.setSpeed(id, 30);
      await settle();
      expect(bikeWire(container), chWireHigh);
      await bike.updateStateDataNow();
      await settle();
      expect(container.read(bikeProvider(id)).lastSeen?.wire, chWireHigh);
      await calibrate(bike, container, preOffWire: chWireLow, bootWire: chWireHigh);
      await armStartupPins(container, bike,
          modeId: nativeModeId(chWireOffroad), assist: 4);

      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), seededChModeId,
          reason: 'nothing changed, so nothing proves the bike lost power');
      expect(bikeAssist(container), isNot(4));
    });

    test('a boot off the off-road wire is detected', () async {
      final container = makeContainer();
      // An unlimited native mode, far from the boot wire: the measured rule has
      // to hold for every selection, not only for the custom mode whose pair
      // contains the boot wire.
      final bike = await openBike(container,
          region: BikeRegion.ch,
          modeId: nativeModeId(chWireOffroad),
          customModes: const [seededChMode]);
      await bike.updateStateDataNow();
      await settle();
      expect(container.read(bikeProvider(id)).lastSeen?.wire, chWireOffroad);
      await calibrate(bike, container, preOffWire: chWireLow, bootWire: chWireHigh);
      await armStartupPins(container, bike,
          modeId: seededChModeId, assist: 4);

      setBikeRegister(container, light: false, assist: 0, wire: chWireHigh);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), seededChModeId,
          reason: 'the ride starts on the pinned mode');
      expect(bikeAssist(container), 4);
    });

    /// [Bike._matchesBootSignature] gained a light comparison alongside its
    /// existing wire/assist ones — see [classifyCapabilityBoot], the only
    /// classifier that ever populates [BootSignature.bootLight]. Mirrors the
    /// wire/assist tests above, on the byte those never covered.
    test('a boot to the measured light applies the pins, wire and assist '
        'unusable', () async {
      final container = makeContainer();
      final bike = await readBike(container);
      await armStartupPins(container, bike,
          modeId: nativeModeId(3), light: false, assist: 4);
      bike.writeStateData(
          container.read(bikeProvider(id)).copyWith(
              bootSignature: BootSignature(
                  measuredAt: DateTime(2026, 8, 11),
                  bootLight: true,
                  preOffWire: 0,
                  preOffAssist: 0)),
          saveToBike: false);
      await settle();

      // The wire and the assist come back exactly as they were before the
      // outage — nothing there could ever prove a power cycle. Only the
      // light differs, and only the light is in the signature.
      setBikeRegister(container, light: true, assist: 0, wire: 0);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), nativeModeId(3),
          reason: 'the light byte alone proved the power cycle');
      expect(bikeLight(container), 0, reason: 'the light is pinned off');
      expect(bikeAssist(container), 4);
    });

    test('a bike already on its boot light applies nothing', () async {
      final container = makeContainer();
      final bike = await readBike(container);
      await armStartupPins(container, bike,
          modeId: nativeModeId(3), light: false, assist: 4);
      // The bike already reported this light value before the outage, so a
      // boot and a dropout report the same byte — no evidence, same
      // conservative rule the wire byte follows.
      bike.writeStateData(
          container.read(bikeProvider(id)).copyWith(
              bootSignature: BootSignature(
                  measuredAt: DateTime(2026, 8, 11),
                  bootLight: false,
                  preOffWire: 0,
                  preOffAssist: 0)),
          saveToBike: false);
      await settle();

      setBikeRegister(container, light: false, assist: 0, wire: 0);
      await cycleConnection(container);
      await bike.updateStateDataNow();
      await settle();

      expect(selectedId(container), nativeModeId(0),
          reason: 'nothing changed, so nothing proves the bike lost power');
      expect(bikeAssist(container), isNot(4));
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
          .copyWith(region: BikeRegion.us, customModes: const [tour30])
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

  group('a bike opened before bikes.json has loaded', () {
    const otherId = 'fa:ke:99:88:77:66';

    /// The names the loaded bike list holds. This is the list every save
    /// persists, so what it keeps, the file keeps too — see db_test for the
    /// file itself. Read here rather than from bikes.json, because a save left
    /// over from an earlier test in this file lands in the same temp directory.
    List<String> namesInDB(ProviderContainer container) =>
        [for (final bike in container.read(bikesDBProvider)) bike.name];

    /// Puts a named record for [id] and one for another bike on disk.
    void seedTwoBikes() {
      seedBikesFile([
        BikeState.defaultState(id).copyWith(name: 'Stored'),
        BikeState.defaultState(otherId).copyWith(name: 'Other'),
      ]);
    }

    // No loadBikesDB in this group: the bike is opened while the file read is
    // still in flight, which is what a cold start does.
    test('adopts its stored record, and the other bike survives', () async {
      seedTwoBikes();
      final container = makeContainer();

      container.listen(bikeProvider(id), (previous, next) {});
      container.read(bikeProvider(id).notifier);
      expect(container.read(bikeProvider(id)).name, isNot('Stored'),
          reason: 'the record has not landed yet');

      await container.read(bikesDBProvider.notifier).ready;
      await settle();

      expect(container.read(bikeProvider(id)).name, 'Stored',
          reason: 'the bike adopts its record once the file lands');
      expect(namesInDB(container), containsAll(['Stored', 'Other']),
          reason: 'and neither record is lost');
    });

    test('an early write does not persist the placeholder over the record',
        () async {
      seedTwoBikes();
      final container = makeContainer();

      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      // An app-only write, the way a rider taps a padlock as the page opens:
      // it needs no connection, so it persists at once.
      bike.cycleLightPin();
      await settle();

      await container.read(bikesDBProvider.notifier).ready;
      await settle();

      expect(namesInDB(container), containsAll(['Stored', 'Other']),
          reason: 'a write before the load must not overwrite the record, '
              'least of all the other bike');
      expect(container.read(bikeProvider(id)).name, 'Stored');
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

  test(
      'readBikeState and probeCapabilities no-op after deletion instead of '
      'throwing on a torn-down notifier', () async {
    final container = makeContainer();
    await loadBikesDB(container);

    final sub = container.listen(bikeProvider(id), (previous, next) {});
    final bike = container.read(bikeProvider(id).notifier);
    bike.writeStateData(
        BikeState.defaultState(id).copyWith(region: BikeRegion.ch));
    await settle();
    final saved = container.read(bikeProvider(id));

    bike.deleteStateData(saved);
    await settle();
    // The setup wizard can span the deletion happening from another screen;
    // closing every listener is what actually tears the notifier's ref down.
    sub.close();
    await settle();

    expect(await bike.readBikeState(), isNull,
        reason: 'a deleted bike must answer gracefully, not throw on a '
            'torn-down notifier');
    expect(
        await bike.probeCapabilities(
            const LastSeen(assist: 0, light: false, wire: 0)),
        isNull);
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
          .copyWith(assist: 2, pinAssist: PinState.locked));
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

    test('an assist tap right after a light toggle keeps the new light',
        () async {
      // The bike's settings register applies a write on its own internal
      // cycle, up to about a second after the BLE ack — see
      // _OwnScheduleFirmwareStore and the device log it comes from. The assist
      // write below composes its light byte from a read taken inside that
      // window, so that read still shows the light the toggle just replaced,
      // and writing it back reverts the rider's own previous tap.
      final store = _OwnScheduleFirmwareStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container, region: BikeRegion.ch);
      // Only the two taps below ride the store's own schedule: the setup write
      // has to land at once, or the light the toggle flips is not known.
      store.armed = true;

      bike.toggleLight();
      await settle();
      bike.setAssist(1);
      await settle();
      // Long enough for the store's own tick to commit the last write.
      await Future<void>.delayed(store.tick * 2);

      expect(bikeAssist(container), 1, reason: 'the tap the rider just made');
      expect(bikeLight(container), 1,
          reason: 'the light the rider set one tap earlier has to survive: '
              'the assist write must not compose it from a read the register '
              'has not applied the toggle into yet');
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

  group('the padlock cycle', () {
    test('arming a startup pin captures the value selected now', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: nativeModeId(2),
          customModes: const []);
      bike.setAssist(3);
      await settle();
      final light = container.read(bikeProvider(id)).light;

      bike.cycleModePin();
      bike.cycleLightPin();
      bike.cycleAssistPin();
      await settle();

      final state = container.read(bikeProvider(id));
      expect(state.pinMode, PinState.startup);
      expect(state.pinLight, PinState.startup);
      expect(state.pinAssist, PinState.startup);
      // The capture is what makes a picker unnecessary: the rider selects the
      // value first, then arms the pin on it.
      expect(state.startupModeId, nativeModeId(2));
      expect(state.startupAssist, 3);
      expect(state.startupLight, light);
    });

    test('two more taps lock the pin and then open it', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: nativeModeId(2),
          customModes: const []);

      bike.cycleModePin();
      await settle();
      expect(container.read(bikeProvider(id)).pinMode, PinState.startup);

      bike.cycleModePin();
      await settle();
      expect(container.read(bikeProvider(id)).pinMode, PinState.locked);

      bike.cycleModePin();
      await settle();
      expect(container.read(bikeProvider(id)).pinMode, PinState.open);
    });

    test('re-arming moves the pin to the mode selected now', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: nativeModeId(2),
          customModes: const []);
      bike.cycleModePin();
      await settle();
      expect(container.read(bikeProvider(id)).startupModeId, nativeModeId(2));

      // Two steps, on purpose: select the value, then arm the pin again.
      bike.selectMode(nativeModeId(1));
      await settle();
      for (var tap = 0; tap < 3; tap++) {
        bike.cycleModePin();
        await settle();
      }

      final state = container.read(bikeProvider(id));
      expect(state.pinMode, PinState.startup);
      expect(state.startupModeId, nativeModeId(1));
    });

    test('re-aiming a startup pin puts nothing on the wire', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.us,
          modeId: nativeModeId(2),
          customModes: const []);
      bike.setAssist(3);
      await settle();
      bike.cycleModePin();
      bike.cycleAssistPin();
      bike.cycleLightPin();
      await settle();
      final wire = bikeWire(container);
      final light = container.read(bikeProvider(id)).light;

      // The rider aims each pin somewhere else than the value being ridden.
      bike.setStartupMode(nativeModeId(1));
      bike.setStartupAssist(0);
      bike.setStartupLight(!light);
      await settle();

      final state = container.read(bikeProvider(id));
      expect(state.startupModeId, nativeModeId(1));
      expect(state.startupAssist, 0);
      expect(state.startupLight, !light);
      // A start selection is app state: the bike keeps riding what it rides.
      expect(state.selectedMode.id, nativeModeId(2));
      expect(state.assist, 3);
      expect(state.light, light);
      expect(bikeWire(container), wire);
      expect(bikeAssist(container), 3);
      expect(bikeLight(container), light ? 1 : 0);
    });
  });

  group('background enforcement', () {
    /// A bike in one of the four combinations of the two conditions that need
    /// the app to keep working with no UI on screen.
    BikeState combo({required bool switching, required bool locked}) =>
        BikeState.defaultState(id)
            .copyWith(
                region: BikeRegion.us,
                customModes: const [tour30, sport45],
                pinMode: locked ? PinState.locked : PinState.open)
            .withSelectedMode(switching ? tour30.id : sport45.id);

    test('the background service follows the switching mode and the pins', () {
      expect(needsBackgroundEnforcement(combo(switching: false, locked: false)),
          isFalse,
          reason: 'nothing to enforce, so nothing has to keep running');
      expect(needsBackgroundEnforcement(combo(switching: true, locked: false)),
          isTrue,
          reason: 'a switching mode limits the speed in the rider pocket');
      expect(needsBackgroundEnforcement(combo(switching: false, locked: true)),
          isTrue,
          reason: 'a locked value has to hold in the rider pocket too');
      expect(needsBackgroundEnforcement(combo(switching: true, locked: true)),
          isTrue);
    });

    test('every padlock can ask for the background service', () {
      final open = combo(switching: false, locked: false);
      for (final locked in [
        open.copyWith(pinMode: PinState.locked),
        open.copyWith(pinLight: PinState.locked),
        open.copyWith(pinAssist: PinState.locked),
      ]) {
        expect(needsBackgroundEnforcement(locked), isTrue,
            reason: 'each of the three padlocks holds a value');
      }
    });

    test('a startup pin alone leaves the background service off', () {
      final open = combo(switching: false, locked: false);
      for (final pinned in [
        open.copyWith(pinMode: PinState.startup),
        open.copyWith(pinLight: PinState.startup),
        open.copyWith(pinAssist: PinState.startup),
      ]) {
        expect(needsBackgroundEnforcement(pinned), isFalse,
            reason: 'a startup pin acts on one moment, so a permanent '
                'notification for it is not earned');
      }
    });

    test('a locked pin keeps the control loop alive in the background',
        () async {
      final container = makeContainer();
      final sub = container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(BikeState.defaultState(id)
          .copyWith(region: BikeRegion.us, customModes: const [sport45])
          .withSelectedMode(sport45.id));
      await settle();
      lockMode(bike);
      await settle();

      // The page is popped. The rider asked the app to hold this mode, so the
      // loop that holds it must not go with the page.
      sub.close();
      await settle();
      expect(container.exists(bikeProvider(id)), isTrue,
          reason: 'a locked value must still be held with no UI on screen');
    });

    test('the last open padlock releases the background control loop',
        () async {
      final container = makeContainer();
      final sub = container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(BikeState.defaultState(id)
          .copyWith(region: BikeRegion.us, customModes: const [sport45])
          .withSelectedMode(sport45.id));
      await settle();
      lockMode(bike);
      await settle();
      sub.close();
      await settle();
      expect(container.exists(bikeProvider(id)), isTrue);

      // One more tap on a locked padlock opens it again.
      bike.cycleModePin();
      await settle();
      expect(container.exists(bikeProvider(id)), isFalse,
          reason: 'with nothing pinned there is nothing left to enforce');
    });

    test('a refused notification shows the padlock as degraded', () {
      expect(
          pinDegraded(PinState.locked,
              hasService: true, notificationsBlocked: true),
          isTrue,
          reason: 'without the notification the lock cannot hold in a pocket, '
              'and the page must not pretend that it does');
      expect(
          pinDegraded(PinState.locked,
              hasService: true, notificationsBlocked: false),
          isFalse);
      expect(
          pinDegraded(PinState.open,
              hasService: true, notificationsBlocked: true),
          isFalse,
          reason: 'an open padlock holds nothing, so nothing is degraded');
      expect(
          pinDegraded(PinState.startup,
              hasService: true, notificationsBlocked: true),
          isFalse);
      expect(
          pinDegraded(PinState.locked,
              hasService: false, notificationsBlocked: true),
          isFalse,
          reason: 'a platform with no service at all would mark every padlock '
              'with a warning nobody can act on');
    });

    test('the background status line says what is kept active', () {
      final switching = combo(switching: true, locked: false);
      final locked = combo(switching: false, locked: true);
      final idle = combo(switching: false, locked: false);

      expect(
          backgroundStatusFor(idle,
              hasService: true, notificationsBlocked: false),
          BackgroundStatus.none);
      expect(backgroundStatusText(BackgroundStatus.none, idle, hasService: true),
          isNull, reason: 'with nothing to enforce the page says nothing');

      final active = backgroundStatusFor(switching,
          hasService: true, notificationsBlocked: false);
      expect(active, BackgroundStatus.active);
      expect(backgroundStatusText(active, switching, hasService: true),
          'Keeping ${switching.selectedMode.name} active while your phone is '
          'locked. Uses some battery.',
          reason: 'a service the rider did not ask for has to say why it runs');
      expect(backgroundStatusText(active, locked, hasService: true),
          contains('your locks'));

      final blocked =
          backgroundStatusFor(locked, hasService: true, notificationsBlocked: true);
      expect(blocked, BackgroundStatus.degraded);
      expect(backgroundStatusText(blocked, locked, hasService: true),
          contains('Notifications are off'));
    });

    test('a platform with no background service says so', () {
      final locked = combo(switching: false, locked: true);
      final status = backgroundStatusFor(locked,
          hasService: false, notificationsBlocked: false);
      expect(status, BackgroundStatus.degraded);
      expect(backgroundStatusText(status, locked, hasService: false),
          'Locks and speed limiting only work while the app is open.');
    });

    test('a locked pin holds the loop after a switching mode is left',
        () async {
      final container = makeContainer();
      final sub = container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(BikeState.defaultState(id)
          .copyWith(region: BikeRegion.us, customModes: const [tour30, sport45])
          .withSelectedMode(tour30.id));
      await settle();
      lockMode(bike);
      await settle();

      bike.selectMode(sport45.id);
      await settle();
      sub.close();
      await settle();
      expect(container.exists(bikeProvider(id)), isTrue,
          reason: 'the padlock is the rider own, so leaving a switching mode '
              'must not take the enforcement with it');
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

    test('a write does not silence the trace timer', () async {
      final container = makeContainer();
      final bike = await openBike(container, region: BikeRegion.ch);
      final before = bike.debugTraceTimer;
      expect(before, isNotNull);
      expect(before!.isActive, isTrue);

      // Writes reset the poll timer through the debounce. The trace must not
      // sit on that timer: during a switching storm it would never fire, and
      // the ride log would lose its trace exactly when limiting is busiest.
      bike.toggleLight();
      await settle();

      expect(identical(bike.debugTraceTimer, before), isTrue,
          reason: 'the trace timer must run steady through writes');
    });
  });

  group('the calibration window', () {
    /// Drops the link and brings it back, then waits out the connect settle the
    /// re-assert holds. Real time, exactly as the reconnect tests above: still
    /// short of the 2 s debounce and the 5 s poll, so every write a test sees
    /// after this is the reconnect's own.
    Future<void> reconnect(ProviderContainer container) async {
      for (var next in [
        SDBluetoothConnectionState.disconnected,
        SDBluetoothConnectionState.connected,
      ]) {
        // ignore: invalid_use_of_protected_member
        container.read(connectionHandlerProvider(id).notifier).state = next;
        await settle();
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await settle();
    }

    /// A bike on native mode 5 (EU off-road), which the re-assert puts back on
    /// wire 5 whenever the bike comes up on something else.
    Future<(Bike, _CountingWriteStore, ProviderContainer)> openCounted() async {
      final store = _CountingWriteStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu,
          modeId: nativeModeId(5),
          customModes: const []);
      return (bike, store, container);
    }

    test('a reconnect writes nothing while calibrating', () async {
      final (bike, store, container) = await openCounted();
      bike.setCalibrating(true);
      // The bike came back on another wire — what the re-assert exists to
      // correct, and exactly the evidence the calibration has to read.
      setBikeWire(container, 1);
      store.writes.clear();

      await reconnect(container);

      expect(bike.debugCalibrating, isTrue);
      expect(store.writes, isEmpty,
          reason: 'a settings write inside the recording window overwrites the '
              'bytes the calibration is there to measure');
      expect(bikeWire(container), 1,
          reason: 'the bike keeps what it booted with');
    });

    test('a user tap writes nothing while calibrating', () async {
      final (bike, store, container) = await openCounted();
      bike.setCalibrating(true);
      store.writes.clear();

      bike.setAssist(3);
      bike.toggleLight();
      bike.selectMode(nativeModeId(1));
      await settle();

      expect(store.writes, isEmpty,
          reason: 'every write path is suppressed, the rider\'s included');
      expect(container.read(bikeProvider(id)).assist, 0,
          reason: 'a suppressed write is dropped, not queued for later');
    });

    test('the released guard restores the re-assert', () async {
      final (bike, store, container) = await openCounted();
      bike.setCalibrating(true);
      bike.setCalibrating(false);
      setBikeWire(container, 1);
      store.writes.clear();

      await reconnect(container);

      expect(bike.debugCalibrating, isFalse);
      expect(store.writes.where((w) => w[0] == 0 && w[1] == 209), isNotEmpty,
          reason: 'the window is over, so the app enforces its mode again');
      expect(bikeWire(container), 5);
    });
  });

  group('classifyCapabilityBoot', () {
    final at = DateTime(2026, 8, 11);

    ({bool light, int assist, int wire}) triple(
            {bool light = false, int assist = 0, int wire = 0}) =>
        (light: light, assist: assist, wire: wire);

    test('a byte that resets to a fixed value enters the signature', () {
      final signature = classifyCapabilityBoot(
          bootA: triple(wire: 4, assist: 0, light: false),
          parting: triple(wire: 2, assist: 3, light: true),
          bootB: triple(wire: 4, assist: 0, light: false),
          measuredAt: at);
      expect(signature.bootWire, 4);
      expect(signature.bootAssist, 0);
      expect(signature.bootLight, isFalse);
      expect(signature.preOffWire, 4,
          reason: 'preOffWire names boot A, the first boot');
      expect(signature.preOffAssist, 0);
    });

    test('a byte that keeps the probe value persists, so it stays null', () {
      final signature = classifyCapabilityBoot(
          bootA: triple(wire: 4, assist: 0, light: false),
          parting: triple(wire: 2, assist: 3, light: true),
          bootB: triple(wire: 2, assist: 3, light: true),
          measuredAt: at);
      expect(signature.bootWire, isNull);
      expect(signature.bootAssist, isNull);
      expect(signature.bootLight, isNull);
    });

    test('all three points equal is ambiguous, so it stays null', () {
      final signature = classifyCapabilityBoot(
          bootA: triple(wire: 4, assist: 0, light: false),
          parting: triple(wire: 4, assist: 0, light: false),
          bootB: triple(wire: 4, assist: 0, light: false),
          measuredAt: at);
      expect(signature.bootWire, isNull);
      expect(signature.bootAssist, isNull);
      expect(signature.bootLight, isNull);
    });

    test('the two boots disagreeing is unusable too', () {
      final signature = classifyCapabilityBoot(
          bootA: triple(wire: 4, assist: 0, light: false),
          parting: triple(wire: 2, assist: 3, light: true),
          bootB: triple(wire: 5, assist: 1, light: true),
          measuredAt: at);
      expect(signature.bootWire, isNull);
      expect(signature.bootAssist, isNull);
      expect(signature.bootLight, isNull);
    });
  });

  group('saveCapabilities', () {
    const bootA = LastSeen(assist: 0, light: false, wire: 0);
    const parting = LastSeen(assist: 3, light: true, wire: 2);
    const bootB = LastSeen(assist: 0, light: false, wire: 0);

    final euCapabilities = BikeCapabilities(
        measuredAt: DateTime(2026, 8, 13),
        acceptedWires: const [4, 5, 6, 7],
        acceptedAssist: const [0, 1, 2, 3, 4],
        lightWritable: true);

    test(
        'a detected region change remaps the mode exactly like a manual '
        'region change would', () async {
      final container = makeContainer();
      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      // A legacy bike: no region measured yet, riding US ECO (native:0).
      bike.writeStateData(
          BikeState.defaultState(id)
              .copyWith(
                  region: null,
                  customModes: const [],
                  capabilities: null,
                  bootSignature: null)
              .withSelectedMode(nativeModeId(0)),
          saveToBike: false);
      await settle();

      bike.saveCapabilities(
          capabilities: euCapabilities,
          bootA: bootA,
          parting: parting,
          bootB: bootB);
      await settle();

      final saved = container.read(bikeProvider(id));
      expect(saved.region, BikeRegion.eu);
      // The same outcome remapModeForRegion's own tests lock in for a manual
      // region change: US ECO (bank index 0) moves to the same index of the
      // EU bank, EPAC 25 (native:4) — not the fallbackMode a raw
      // copyWith(region:) would silently land on because native:0 is not in
      // the EU bank's selectableModes.
      expect(saved.selectedMode.id, nativeModeId(4));
    });

    test('a detected region equal to the current one moves nothing',
        () async {
      final container = makeContainer();
      container.listen(bikeProvider(id), (previous, next) {});
      final bike = container.read(bikeProvider(id).notifier);
      bike.writeStateData(
          BikeState.defaultState(id)
              .copyWith(
                  region: BikeRegion.eu,
                  customModes: const [],
                  capabilities: null,
                  bootSignature: null)
              .withSelectedMode(nativeModeId(5)),
          saveToBike: false);
      await settle();

      bike.saveCapabilities(
          capabilities: euCapabilities,
          bootA: bootA,
          parting: parting,
          bootB: bootB);
      await settle();

      final saved = container.read(bikeProvider(id));
      expect(saved.region, BikeRegion.eu);
      expect(saved.selectedMode.id, nativeModeId(5),
          reason: 'the region did not change, so the selection must not '
              'move — a regression guard against remapping on every save');
    });
  });

  group('readBikeState', () {
    test('returns a correct LastSeen from a good packet', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      container.read(fakeBikeStoreProvider).write(id, [0, 209, 1, 3, 6, 0, 0, 0, 0, 0]);

      final seen = await bike.readBikeState();

      expect(seen, isNotNull);
      expect(seen!.light, isTrue);
      expect(seen.assist, 3);
      expect(seen.wire, 6);
    });

    test('returns null while disconnected', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // ignore: invalid_use_of_protected_member
      container.read(connectionHandlerProvider(id).notifier).state =
          SDBluetoothConnectionState.disconnected;

      expect(await bike.readBikeState(), isNull);
    });

    test('returns null from a foreign ride-data packet', () async {
      final store = _RideDataStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      store.serveRideData = true;

      expect(await bike.readBikeState(), isNull);
    });

    test('returns null from a bad read', () async {
      final store = _GarbageReadStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);

      expect(await bike.readBikeState(), isNull);
    });
  });

  group('probeCapabilities', () {
    const bootA = LastSeen(assist: 0, light: false, wire: 5);

    test('a bike that accepts everything reports full capabilities',
        () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // The sweep now runs over several real seconds (Bike._probeSettle waits
      // between every write and its readback), long enough for the bike's own
      // real 2 s update debounce to fire mid-sweep otherwise — exactly what
      // the wizard's calibration window exists to suppress in production.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(bootA);

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, List.generate(8, (i) => i));
      expect(caps.acceptedAssist, [0, 1, 2, 3, 4]);
      expect(caps.lightWritable, isTrue);
      expect(caps.modeWritable, isTrue);
      expect(caps.assistWritable, isTrue);
      expect(caps.detectedRegion, isNull,
          reason: 'both banks accepted at once names no region cleanly — '
              'see models_test.dart for the clean-set cases');
    });

    test('a bike locked onto one wire reports it as the only accepted wire',
        () async {
      final store = _LockedByteStore(fixedWire: 5);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above: the sweep now runs long
      // enough in real time for the bike's own update debounce to fire
      // mid-sweep without this.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(bootA);

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, [5]);
      expect(caps.modeWritable, isFalse,
          reason: 'nothing else was ever accepted to pick instead');
    });

    test(
        'a bike locked onto one assist level reports it as the only '
        'accepted level', () async {
      final store = _LockedByteStore(fixedAssist: 2);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps =
          await bike.probeCapabilities(const LastSeen(assist: 2, light: false, wire: 5));

      expect(caps, isNotNull);
      expect(caps!.acceptedAssist, [2]);
      expect(caps.assistWritable, isFalse);
    });

    test('a bike locked onto the light reports it as not writable',
        () async {
      final store = _LockedByteStore(fixedLight: false);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(bootA);

      expect(caps, isNotNull);
      expect(caps!.lightWritable, isFalse);
    });

    test('the success path never leaves the bus on wire 3 or 7', () async {
      final store = _CountingFlakyStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(bootA);

      expect(caps, isNotNull);
      final lastWire = store.writes.last[4];
      expect(lastWire, isNot(3));
      expect(lastWire, isNot(7));
    });

    test('a mid-sweep failure still leaves the bus off wire 3 and 7',
        () async {
      // Throws on the third write, mid wire sweep (wire 2 of 0-7).
      final store = _CountingFlakyStore(failOnWrite: 3);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      await expectLater(bike.probeCapabilities(bootA), throwsException);

      final lastWire = store.writes.last[4];
      expect(lastWire, isNot(3));
      expect(lastWire, isNot(7));
      expect(lastWire, bootA.wire,
          reason: 'the finally block parks on the boot wire it started from');
    });

    test('succeeds while a calibration window is open', () async {
      // The setup wizard holds the window open across the whole probe (see
      // setup_page.dart's _run): refusing here would just force the caller
      // to close it at the one moment protection matters most, which is the
      // bug this contract change fixes. probeCapabilities's own writes go
      // straight through ConnectionHandler.write, below _calibrating's
      // suppression, so the window buys the probe nothing either way — it
      // protects the rest of the app from the probe, not the other way
      // round.
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(bootA);

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, List.generate(8, (i) => i));
    });

    test(
        'an interleaved poll cannot write a startup pin mid-probe on a bike '
        'with an existing boot signature', () async {
      // Reproduces the bug the old open/close dance around probeCapabilities
      // caused on a "set up this bike again" run: the ordinary poll firing
      // between two of the probe's own write-then-read steps could see the
      // probe's own transient value, mistake it for the second power cycle,
      // and write a startup pin over the sweep's own writes. Holding the
      // window open throughout (the fix) must let the probe still run
      // cleanly, and must stop the poll's write from ever reaching the bike.
      final store = _CountingReentrantStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);

      // The app's last read of this bike, before the probe: wire 5 — the
      // same wire the selected mode already asserts, so this read settles
      // with no heal write of its own, and nothing like the boot wire the
      // signature below is about to name.
      store.write(id, [0, 209, 0, 2, 5, 0, 0, 0, 0, 0]);
      await bike.updateStateDataNow();
      await settle();
      expect(container.read(bikeProvider(id)).lastSeen,
          const LastSeen(assist: 2, light: false, wire: 5));

      // A boot signature left by an earlier setup run: this bike resets to
      // wire 6 on power-on. The probe's own wire sweep tries wire 6 first —
      // it starts one past the boot wire it is given (5) — with bootA's own
      // assist/light held, unchanged: the exact transient the old bug let the
      // poll misread as a real second power cycle.
      final signature = classifyCapabilityBoot(
          bootA: (light: false, assist: 2, wire: 6),
          parting: (light: false, assist: 2, wire: 5),
          bootB: (light: false, assist: 2, wire: 6),
          measuredAt: DateTime(2026, 8, 11));
      bike.writeStateData(
          container.read(bikeProvider(id)).copyWith(
              bootSignature: signature,
              pinMode: PinState.startup,
              startupModeId: nativeModeId(3)),
          saveToBike: false);
      await settle();

      // Matches the fixed wizard: the window stays open through the whole
      // probe, never closed around this call.
      bike.setCalibrating(true);

      // Everything above this line is setup noise (the seeding writes, the
      // read that resolved them) — cleared so the count below is only the
      // probe's own writes, plus whatever the interleaved poll adds.
      store.writes.clear();

      // Fires once, from inside the very first step's own readback — right
      // where the register queue actually interleaves a queued action
      // between two of the probe's steps (see _CountingReentrantStore).
      store.onRead = () {
        unawaited(bike.updateStateDataNow());
      };

      final caps = await bike.probeCapabilities(
          const LastSeen(assist: 2, light: false, wire: 5));
      await settle();

      expect(caps, isNotNull,
          reason: 'the probe must still run to completion under the open '
              'window');
      expect(caps!.acceptedWires, List.generate(8, (i) => i),
          reason: "an interleaved poll read must not corrupt the sweep's "
              'own readback');
      expect(caps.acceptedAssist, [0, 1, 2, 3, 4]);
      expect(caps.lightWritable, isTrue);
      expect(store.writes.length, 16,
          reason: 'the interleaved poll must add no write of its own: with '
              "the window still open, writeStateData drops it — 8 wire + 1 "
              'safe-wire settle + 5 assist + 1 parting assist + 1 light is '
              "the sweep's own total for a bike that accepts everything, so "
              'any extra write means the poll leaked one onto the bike');
      expect(selectedId(container), nativeModeId(5),
          reason: 'the startup pin must not have fired mid-probe: the bike '
              'is still on the mode it started the probe with');
    });

    test(
        "an interleaved poll's read must not corrupt lastSeen with a "
        'transient mid-sweep value', () async {
      // Same interleaving harness as the startup-pin regression above: a
      // read fired from inside one of the probe's own write-then-read steps,
      // the way the register queue actually interleaves an ordinary poll
      // between two of them.
      final store = _ReentrantReadStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);

      // A real boot read, exactly what the wizard's own readBikeState
      // establishes — the baseline the fix has to preserve.
      store.write(id, [0, 209, 0, 2, 5, 0, 0, 0, 0, 0]);
      await bike.updateStateDataNow();
      await settle();
      final baseline = container.read(bikeProvider(id)).lastSeen;
      expect(baseline, const LastSeen(assist: 2, light: false, wire: 5));

      bike.setCalibrating(true);
      // Fires once, from inside the probe's very first readback: lands on
      // whatever transient value the sweep has written by the time the
      // register queue actually runs it, between two of the probe's own
      // steps.
      store.onRead = () {
        unawaited(bike.updateStateDataNow());
      };

      await bike.probeCapabilities(
          const LastSeen(assist: 2, light: false, wire: 5));
      await settle();
      bike.setCalibrating(false);
      await settle();

      expect(container.read(bikeProvider(id)).lastSeen, baseline,
          reason: "a poll's read mid-sweep must not overwrite the real boot "
              'baseline with a transient value the probe itself wrote — that '
              'baseline is what the NEXT real disconnect/reconnect is '
              'measured against');
    });

    test('refuses while the bike is moving', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      container.read(fakeBikeStoreProvider).setSpeed(id, 20);
      await settle();

      expect(await bike.probeCapabilities(bootA), isNull);
    });

    test('refuses while disconnected', () async {
      final container = makeContainer();
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // ignore: invalid_use_of_protected_member
      container.read(connectionHandlerProvider(id).notifier).state =
          SDBluetoothConnectionState.disconnected;

      expect(await bike.probeCapabilities(bootA), isNull);
    });

    test('a mid-sweep disconnect aborts the sweep instead of scoring every '
        'remaining value as rejected', () async {
      // BluetoothRepository swallows a failed read (it returns null) and a
      // failed write, so once the link is down every remaining probe reads
      // back "not what I wrote" — indistinguishable from a firmware that
      // refuses the value. A sweep that kept going would hand the wizard
      // capabilities built from a dropped link, and the wizard saves those as
      // ground truth.
      final store = _ReentrantReadStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);
      // The link drops from inside the sweep's very first readback.
      store.onRead = () {
        // ignore: invalid_use_of_protected_member
        container.read(connectionHandlerProvider(id).notifier).state =
            SDBluetoothConnectionState.disconnected;
      };

      final caps = await bike.probeCapabilities(bootA);

      expect(caps, isNull,
          reason: 'a probe that could not finish must report that it could '
              'not run, which the wizard already treats as a failure');
      expect(container.read(bikeProvider(id)).capabilities, isNull,
          reason: 'nothing measured across a dropped link may be saved');
    });

    test(
        'an exception during the assist phase restores the full boot triple, '
        'not just the wire', () async {
      // failOnWrite is 1-indexed over every write the sweep makes: 8 wire +
      // 1 safe-wire settle lands write 10 on the assist loop's first write.
      final store = _CountingFlakyStore(failOnWrite: 10);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      await expectLater(bike.probeCapabilities(bootA), throwsException);

      expect(bikeWire(container), bootA.wire,
          reason: 'the old wire-only safety net already covered this');
      expect(bikeAssist(container), bootA.assist,
          reason: 'the assist level the sweep left behind must be restored '
              'too, not just the wire');
      expect(bikeLight(container), bootA.light ? 1 : 0);
    });

    test(
        'an exception during the light phase restores the full boot triple, '
        'not just the wire', () async {
      // 8 wire + 1 safe-wire settle + 5 assist + 1 parting assist lands write
      // 16 on the light test itself, the sweep's very last step. The parting
      // assist write is always made now: the assist loop probes bootA.assist
      // last, so the value the sweep ends on always coincides with the boot
      // value.
      final store = _CountingFlakyStore(failOnWrite: 16);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      await expectLater(bike.probeCapabilities(bootA), throwsException);

      expect(bikeWire(container), bootA.wire);
      expect(bikeAssist(container), bootA.assist);
      expect(bikeLight(container), bootA.light ? 1 : 0,
          reason: 'the light the sweep flipped for its own test must be '
              'restored too, not just the wire');
    });

    test(
        'the safe wire prefers a second accepted wire over the boot wire, so '
        'the second boot can learn something', () async {
      final store = _LimitedWireStore(const {0, 1});
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(
          const LastSeen(assist: 0, light: false, wire: 0));

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, [0, 1]);
      expect(bikeWire(container), 1,
          reason: 'wire 0 is the most limited accepted wire, but it is also '
              'the boot wire — parking there would compare a byte against '
              "itself, which classifyCapabilityBoot can only read as "
              "'ambiguous'. Wire 1 is the only other accepted wire.");
    });

    test(
        'the safe wire tie-break takes the next-most-limited wire, not the '
        'lowest one', () async {
      final store = _LimitedWireStore(const {2, 4, 5});
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // The register has to start on the boot wire the probe is told about:
      // this store keeps the wire it already holds when a write names a wire
      // it refuses, so a register left on wire 0 would make the sweep's own
      // wire-0 step read back as accepted.
      setBikeWire(container, 4);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(
          const LastSeen(assist: 0, light: false, wire: 4));

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, [2, 4, 5]);
      expect(bikeWire(container), 5,
          reason: 'wire 4 (25 km/h) is the most limited accepted wire, but it '
              'is also the boot wire, so the sweep has to park somewhere '
              'else. Wire 5 caps at 35 km/h and wire 2 at 45, so wire 5 is '
              'the safer of the two for a bike the rider switches on next');
    });

    test(
        'the safe wire stays on the boot wire when there is no other '
        'accepted wire to prefer', () async {
      final store = _LimitedWireStore(const {0});
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(
          const LastSeen(assist: 0, light: false, wire: 0));

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, [0]);
      expect(bikeWire(container), 0,
          reason: 'no safer alternative exists, so parking on the boot wire '
              '(and the resulting ambiguous classification) is the honest '
              'answer, not a bug to work around — the fix must never pick '
              'an unlimited wire just to differ from it');
    });

    test(
        'waits out a register that lags one write behind, instead of '
        'reading every step one write early', () async {
      // The very first real device log caught this byte-for-byte: every
      // single write-then-read step of the sweep came back showing the
      // PREVIOUS write's value, because the bike's settings register needs
      // real time to apply a write. This store's own commit delay is
      // shorter than Bike._probeSettle on purpose, so this proves the
      // settle wait between write and first read attempt is what makes the
      // difference here, not test timing luck. See
      // '_OwnScheduleFirmwareStore' below for the follow-up bug a SECOND
      // log revealed, which needs the retry loop rather than just the wait.
      final store = _LaggyFirmwareStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // Only the probe's own writes are laggy: the setup above must land
      // normally, or bootA would not describe the register it actually
      // seeded.
      store.armed = true;
      // See the first probeCapabilities test above: a several-second sweep
      // needs the calibration window held open, matching how the wizard
      // actually runs this in production.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(bootA);

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, List.generate(8, (i) => i),
          reason: 'a bike that accepts every wire must be reported that way '
              'once the probe waits out the register lag — the real bug '
              'read this back as accepting nothing at all');
      expect(caps.acceptedAssist, [0, 1, 2, 3, 4]);
      expect(caps.lightWritable, isTrue);
    });

    test(
        'polls out a register that updates on its own schedule, not just a '
        'fixed lag behind the write', () async {
      // The regression test for the SECOND real device log, taken after the
      // single-fixed-delay fix above had already shipped: sweeping wires
      // 0-7 with that fix in place, write-to-read gaps of 439 ms and 437
      // ms — essentially identical — came back stale and correct
      // respectively, alternating almost perfectly across all 8 wires. That
      // ruled out "wait longer" as a fix: the bike's register updates on
      // its own internal cycle, and _OwnScheduleFirmwareStore reproduces
      // exactly that shape (see its own doc comment). If the probe still
      // trusted a single read after one fixed wait, this bike would report
      // some wires/assist levels missing depending on where each step's
      // write happened to land in the store's cycle; polling must catch
      // every one of them regardless.
      final store = _OwnScheduleFirmwareStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // Only the probe's own writes ride the store's own schedule: the setup
      // above must land normally, or bootA would not describe the register
      // it actually seeded.
      store.armed = true;
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(bootA);

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, List.generate(8, (i) => i),
          reason: 'every wire is genuinely accepted, just on the store\'s '
              'own cadence — a probe that gambled on one fixed-delay read '
              'per step would miss some of them, exactly like the real '
              'device log');
      expect(caps.acceptedAssist, [0, 1, 2, 3, 4]);
      expect(caps.lightWritable, isTrue);
    });

    test('probes the boot wire and the boot assist last of all', () async {
      final store = _CountingFlakyStore();
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);
      // Only the sweep's own writes are counted below, not the setup write.
      store.writes.clear();

      final caps = await bike.probeCapabilities(
          const LastSeen(assist: 0, light: false, wire: 0));

      expect(caps, isNotNull);
      expect(
          store.writes
              .take(firmwareProfiles.length)
              .map((write) => write[4])
              .toList(),
          [1, 2, 3, 4, 5, 6, 7, 0],
          reason: 'a write of the value the bike already holds proves nothing: '
              'the readback shows that value whether the firmware took the '
              'write or refused it. Probed last, the boot wire is the one wire '
              'the bike has provably been moved away from first');
      expect(
          store.writes
              .skip(firmwareProfiles.length + 1)
              .take(5)
              .map((write) => write[3])
              .toList(),
          [1, 2, 3, 4, 0],
          reason: 'the assist loop has the same vacuous first step, and skips '
              'it the same way — the safe-wire park write sits between the two '
              'loops');
      expect(caps!.acceptedWires, [0, 1, 2, 3, 4, 5, 6, 7],
          reason: 'the result stays sorted whatever order it was probed in: '
              'it goes into bikes.json and into detectedRegion set '
              'comparisons');
      expect(caps.acceptedAssist, [0, 1, 2, 3, 4]);
    });

    test('a bike locked onto its own boot wire claims no other wire',
        () async {
      // The one case a per-wire probe cannot tell apart: a firmware that
      // refuses every write, on a bike that booted on the very wire being
      // written, reads back exactly what a firmware that took the write reads
      // back. What has to stay honest is everything around it — no OTHER wire
      // may be reported as accepted, and the mode picker stays hidden.
      final store = _LockedByteStore(fixedWire: 0);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(
          const LastSeen(assist: 0, light: false, wire: 0));

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, [0]);
      expect(caps.modeWritable, isFalse,
          reason: 'one wire is no choice at all, and this bike never proved '
              'even that one');
    });

    test('a bike locked onto its own boot assist claims no other level',
        () async {
      final store = _LockedByteStore(fixedAssist: 0);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike.probeCapabilities(
          const LastSeen(assist: 0, light: false, wire: 5));

      expect(caps, isNotNull);
      expect(caps!.acceptedAssist, [0]);
      expect(caps.assistWritable, isFalse);
    });

    test(
        'gives up on a value the firmware genuinely never accepts, without '
        'hanging', () async {
      // Distinct from both fakes above: _LockedByteStore's fixedWire never
      // changes no matter how long the probe waits or how many times it
      // reads, standing in for a real, permanent rejection rather than lag.
      // Only _probeWriteRead's own bounded attempt budget can end that
      // loop — asserted here via a wrapping timeout, so a regression that
      // turned the retry into an unconditional one would fail this test by
      // hanging, not just by a wrong result.
      final store = _LockedByteStore(fixedWire: 5);
      final container = ProviderContainer(overrides: [
        fakeBikeStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(container.dispose);
      final bike = await openBike(container,
          region: BikeRegion.eu, modeId: nativeModeId(5), customModes: const []);
      // See the first probeCapabilities test above.
      bike.setCalibrating(true);

      final caps = await bike
          .probeCapabilities(bootA)
          .timeout(const Duration(seconds: 20));

      expect(caps, isNotNull);
      expect(caps!.acceptedWires, [5],
          reason: 'every other wire genuinely never accepts, so the probe '
              'must give up on each after its bounded attempt budget rather '
              'than loop forever');
    });
  });
}

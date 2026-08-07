import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/models.dart';
import 'package:superduper/repository.dart';

const fakeId = 'fa:ke:01:02:03:04';

void main() {
  test('isFakeBike', () {
    expect(isFakeBike(fakeId), true);
    expect(isFakeBike('fa:ke:'), true);
    expect(isFakeBike('aa:bb:cc:dd:ee:ff'), false);
    expect(isFakeBike(''), false);
  });

  test('default register is the default state', () {
    final store = FakeBikeStore();
    expect(store.read(fakeId), [3, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    // Light off, assist 0 and a region already set: the read-back leaves a
    // fresh bike exactly as it is.
    expect(BikeState.defaultState(fakeId).updateFromData(store.read(fakeId)),
        BikeState.defaultState(fakeId));
  });

  test('write echoes into the read register', () {
    final store = FakeBikeStore();
    // [0, 209, light, assist, mode, 0...]
    store.write(fakeId, [0, 209, 1, 3, 2, 0, 0, 0, 0, 0]);
    expect(store.read(fakeId), [3, 0, 3, 0, 1, 2, 0, 0, 0, 0]);
  });

  test('write keeps the raw EU mode untouched', () {
    final store = FakeBikeStore();
    store.write(fakeId, [0, 209, 0, 0, 6, 0, 0, 0, 0, 0]);
    expect(store.read(fakeId)[5], 6);
  });

  test('non state writes are ignored', () {
    final store = FakeBikeStore();
    store.write(fakeId, [3, 0]);
    store.write(fakeId, [0, 210, 1, 1, 1]);
    store.write(fakeId, []);
    expect(store.read(fakeId), [3, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  });

  test('registers are per device', () {
    final store = FakeBikeStore();
    store.write(fakeId, [0, 209, 1, 4, 3, 0, 0, 0, 0, 0]);
    expect(store.read('fa:ke:aa:bb:cc:dd'), [3, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  });

  test('BikeState round trips through the store (US)', () {
    final store = FakeBikeStore();
    final bike = BikeState.defaultState(fakeId)
        .copyWith(region: BikeRegion.us, light: true, assist: 4)
        .withSelectedMode(nativeModeId(2));
    final wire = initialWireFor(bike.selectedMode);
    store.write(fakeId, bike.toWriteData(wire: wire));
    expect(store.read(fakeId)[5], 2);
    expect(bike.updateFromData(store.read(fakeId)), bike,
        reason: 'the rider-owned fields come back unchanged, and the read-back '
            'no longer touches the selection');
  });

  test('BikeState round trips through the store (EU)', () {
    final store = FakeBikeStore();
    final bike = BikeState.defaultState(fakeId)
        .copyWith(region: BikeRegion.eu, light: false, assist: 2)
        .withSelectedMode(nativeModeId(7));
    final wire = initialWireFor(bike.selectedMode);
    store.write(fakeId, bike.toWriteData(wire: wire));
    // The wire byte is absolute now: an EU mode is addressed by 4-7 directly.
    expect(store.read(fakeId)[5], 7);
    expect(bike.updateFromData(store.read(fakeId)), bike);
  });

  test('toggleLight flips the light bit', () {
    final store = FakeBikeStore();
    store.toggleLight(fakeId);
    expect(store.read(fakeId)[4], 1);
    store.toggleLight(fakeId);
    expect(store.read(fakeId)[4], 0);
  });

  test('cycleAssist wraps 4 to 0', () {
    final store = FakeBikeStore();
    for (var expected in [1, 2, 3, 4, 0]) {
      store.cycleAssist(fakeId);
      expect(store.read(fakeId)[2], expected);
    }
  });

  test('cycleMode wraps 3 to 0 (US)', () {
    final store = FakeBikeStore();
    for (var expected in [1, 2, 3, 0]) {
      store.cycleMode(fakeId);
      expect(store.read(fakeId)[5], expected);
    }
  });

  test('cycleMode wraps 7 to 4 (EU)', () {
    final store = FakeBikeStore();
    store.write(fakeId, [0, 209, 0, 0, 4, 0, 0, 0, 0, 0]);
    for (var expected in [5, 6, 7, 4]) {
      store.cycleMode(fakeId);
      expect(store.read(fakeId)[5], expected);
    }
  });

  test('speed defaults to zero and setSpeed updates it', () {
    final store = FakeBikeStore();
    expect(store.speedKmh(fakeId), 0);
    store.setSpeed(fakeId, 23.5);
    expect(store.speedKmh(fakeId), 23.5);
  });

  test('speedStream emits on every setSpeed', () async {
    final store = FakeBikeStore();
    expect(store.speedStream(fakeId).isBroadcast, isTrue);
    final first = <double>[];
    final second = <double>[];
    final subs = [
      store.speedStream(fakeId).listen(first.add),
      store.speedStream(fakeId).listen(second.add),
    ];
    store.setSpeed(fakeId, 5.5);
    store.setSpeed(fakeId, 0);
    await Future<void>.delayed(Duration.zero);
    expect(first, [5.5, 0]);
    expect(second, [5.5, 0]);
    for (var sub in subs) {
      await sub.cancel();
    }
  });

  test('speeds are per device', () async {
    final store = FakeBikeStore();
    const otherId = 'fa:ke:aa:bb:cc:dd';
    final seen = <double>[];
    final sub = store.speedStream(otherId).listen(seen.add);
    store.setSpeed(fakeId, 9);
    await Future<void>.delayed(Duration.zero);
    expect(store.speedKmh(otherId), 0);
    expect(seen, isEmpty);
    await sub.cancel();
  });

  test('ConnectionHandler streams the fake bike speed', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = connectionHandlerProvider(fakeId);
    container.listen(provider, (_, _) {}, fireImmediately: true);
    final handler = container.read(provider.notifier);

    final speeds = <double>[];
    final sub = handler.speedStream.listen(speeds.add);
    addTearDown(sub.cancel);

    // Fake bikes have no ride data to request, but the call must be safe.
    await handler.requestRideData();

    final store = container.read(fakeBikeStoreProvider);
    store.setSpeed(fakeId, 12.5);
    store.setSpeed(fakeId, 24.0);
    await Future<void>.delayed(Duration.zero);
    expect(speeds, [12.5, 24.0]);
  });

  test('bikeSpeed provider exposes the speed stream', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sub = container.listen(bikeSpeedProvider(fakeId), (_, _) {},
        fireImmediately: true);
    expect(sub.read(), const AsyncValue<double>.loading());

    container.read(fakeBikeStoreProvider).setSpeed(fakeId, 30.0);
    expect(await container.read(bikeSpeedProvider(fakeId).future), 30.0);
    expect(sub.read().value, 30.0);
  });

  test('ConnectionHandler fakes a connection and echoes writes', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = connectionHandlerProvider(fakeId);
    // Keep the auto-dispose provider alive for the duration of the test.
    container.listen(provider, (_, _) {}, fireImmediately: true);

    expect(container.read(provider), SDBluetoothConnectionState.connected);

    final handler = container.read(provider.notifier);
    expect(await handler.read(), [3, 0, 0, 0, 0, 0, 0, 0, 0, 0]);

    await handler.write([0, 209, 1, 2, 3, 0, 0, 0, 0, 0]);
    expect(await handler.read(), [3, 0, 2, 0, 1, 3, 0, 0, 0, 0]);
  });
}

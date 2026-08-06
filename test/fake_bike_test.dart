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
    expect(
        BikeState.defaultState(fakeId).updateFromData(store.read(fakeId)),
        BikeState.defaultState(fakeId).copyWith(region: BikeRegion.us));
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
        .copyWith(region: BikeRegion.us, light: true, assist: 4, mode: 3);
    store.write(fakeId, bike.toWriteData());
    expect(bike.updateFromData(store.read(fakeId)), bike);
  });

  test('BikeState round trips through the store (EU)', () {
    final store = FakeBikeStore();
    final bike = BikeState.defaultState(fakeId)
        .copyWith(region: BikeRegion.eu, light: false, assist: 2, mode: 3);
    store.write(fakeId, bike.toWriteData());
    // Raw mode is offset by +4 on the wire, stripped on read.
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

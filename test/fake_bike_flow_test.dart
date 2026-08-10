import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/db.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/repository.dart';

/// End-to-end control-loop test of the fake bike flow, mirroring what a user
/// does in the app: create a fake bike from the debug page, open it, use the
/// controls, and have the "rider" press buttons on the bike itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_flow_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('fake bike: save, connect, toggle, rider input, lock enforcement',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const id = 'fa:ke:aa:bb:cc:dd';

    // Debug page opens the settings form, Save persists the bike.
    var dbNotifications = 0;
    container.listen(bikesDBProvider, (previous, next) => dbNotifications++);
    final bikeSub = container.listen(bikeProvider(id), (previous, next) {});
    final bike = container.read(bikeProvider(id).notifier);
    bike.writeStateData(
        BikeState.defaultState(id).copyWith(region: BikeRegion.us),
        saveToBike: false);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(bikesDBProvider), hasLength(1),
        reason: 'Save must persist the bike');
    expect(dbNotifications, greaterThan(0),
        reason: 'the bike lists must rebuild after Save');

    // The fake bike reports connected without any hardware.
    expect(container.read(connectionHandlerProvider(id)),
        SDBluetoothConnectionState.connected);

    // BikePage light toggle: sticks locally and echoes back from the "bike".
    bike.toggleLight();
    await Future<void>.delayed(Duration.zero);
    expect(bikeSub.read().light, isTrue);
    await bike.updateStateDataNow(force: true);
    expect(bikeSub.read().light, isTrue,
        reason: 'the bike must echo the written light state');

    // The poll's own write-back is fire-and-forget, so let it land before the
    // rider touches the bike: otherwise it arrives after the rider input and
    // overwrites it, which is a race in this test, not in the app.
    await Future<void>.delayed(Duration.zero);

    // Rider bumps assist on the bike itself; the next poll picks it up.
    // writeStateData inside the poll is fire-and-forget, so yield once for
    // the new state to land.
    container.read(fakeBikeStoreProvider).cycleAssist(id);
    await bike.updateStateDataNow();
    await Future<void>.delayed(Duration.zero);
    expect(bikeSub.read().assist, 1,
        reason: 'unlocked settings follow the bike');

    // Lock the light in the app, rider turns it off on the bike: the next
    // poll must write the locked value back instead of following.
    // Two taps: the pin cycles open, startup and locked.
    bike.cycleLightPin();
    bike.cycleLightPin();
    await Future<void>.delayed(Duration.zero);
    container.read(fakeBikeStoreProvider).toggleLight(id);
    await bike.updateStateDataNow();
    await Future<void>.delayed(Duration.zero);
    expect(bikeSub.read().light, isTrue,
        reason: 'locked settings must not follow the bike');
    expect(container.read(fakeBikeStoreProvider).read(id)[4], 1,
        reason: 'the locked value must be written back to the bike');

    // Let the fire-and-forget file IO settle before tearDown removes the dir.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}

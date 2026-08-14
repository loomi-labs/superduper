import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/db.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/select_page.dart';
import 'package:superduper/widgets.dart';

/// A repository that never touches the real radio: [BikeSelectWidget] kicks
/// off a scan from `initState`, and these tests drive `scanResultsProvider`
/// by hand instead of waiting on a real one.
class _NoOpBluetoothRepository extends BluetoothRepository {
  _NoOpBluetoothRepository(super.ref);

  @override
  Future<void> scan() async {}

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> disconnect() async {}
}

/// [bikesDBProvider] seeded with a fixed list and no file behind it: the
/// select page's own file load is a real `Future`, which does not resolve
/// inside a widget test's fake clock the way [seededBikesFile] tests
/// elsewhere handle with a real millisecond delay. Read-only for these tests.
class _SeededBikesDB extends BikesDB {
  _SeededBikesDB(this._seed, {this.loaded = true});

  final List<BikeState> _seed;

  /// Whether the seed stands for a landed bikes.json. False stands for the
  /// window before the file lands, when every saved bike still reads as unknown.
  final bool loaded;

  @override
  List<BikeState> build() {
    if (loaded) {
      debugMarkLoaded();
    }
    return _seed;
  }
}

/// The "My Bikes" row status pill: connected, in range but not connected, or
/// (a saved bike the scan has not seen) no pill at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const connectedId = 'aa:bb:cc:dd:ee:01';
  const inRangeId = 'aa:bb:cc:dd:ee:02';
  const unseenId = 'aa:bb:cc:dd:ee:03';

  ScanResult scanResultFor(String id) => ScanResult(
        device: BluetoothDevice.fromId(id),
        advertisementData: AdvertisementData(
          advName: '',
          txPowerLevel: null,
          appearance: null,
          connectable: true,
          manufacturerData: const {},
          serviceData: const {},
          serviceUuids: const [],
        ),
        rssi: -60,
        timeStamp: DateTime.now(),
      );

  Future<void> pumpSelectPage(WidgetTester tester, List<BikeState> bikes,
      {bool loaded = true}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bikesDBProvider
              .overrideWith(() => _SeededBikesDB(bikes, loaded: loaded)),
          bluetoothRepositoryProvider.overrideWith(
            (ref) => _NoOpBluetoothRepository(ref),
          ),
          isScanningStatusProvider.overrideWith((ref) => Stream.value(false)),
          adapterStateProvider.overrideWith(
            (ref) => Stream.value(BluetoothAdapterState.on),
          ),
          scanResultsProvider.overrideWith(
            (ref) => Stream.value([scanResultFor(inRangeId)]),
          ),
          connectedDevicesProvider.overrideWith(
            (ref) => Stream.value([BluetoothDevice.fromId(connectedId)]),
          ),
        ],
        child: const MaterialApp(home: BikeSelectWidget()),
      ),
    );
    // Lets the scan/connected AsyncValues resolve from their loading state.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a connected saved bike shows the connected pill',
      (tester) async {
    await pumpSelectPage(tester, [
      BikeState.defaultState(connectedId).copyWith(name: 'Fast Otter'),
    ]);

    expect(find.text('Fast Otter'), findsOneWidget);
    expect(find.byType(StatusPill), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('In range'), findsNothing);
  });

  testWidgets(
      'a saved bike the scan sees but nothing has connected shows the '
      'in-range pill', (tester) async {
    await pumpSelectPage(tester, [
      BikeState.defaultState(inRangeId).copyWith(name: 'Slow Badger'),
    ]);

    expect(find.text('Slow Badger'), findsOneWidget);
    expect(find.text('In range'), findsOneWidget);
    expect(find.text('Connected'), findsNothing);
  });

  testWidgets('a saved bike seen by neither shows no pill', (tester) async {
    await pumpSelectPage(tester, [
      BikeState.defaultState(unseenId).copyWith(name: 'Old Mole'),
    ]);

    expect(find.text('Old Mole'), findsOneWidget);
    expect(find.byType(StatusPill), findsNothing);
    expect(find.text('Connected'), findsNothing);
    expect(find.text('In range'), findsNothing);
  });

  testWidgets('a found bike stays hidden until bikes.json has loaded',
      (tester) async {
    await pumpSelectPage(tester, const [], loaded: false);

    expect(find.text(inRangeId), findsNothing,
        reason: 'before the file lands a saved bike reads as unknown, and the '
            'page would offer it as a fresh one');
    expect(find.text('No bikes found nearby'), findsOneWidget);
  });

  testWidgets('a found bike shows once bikes.json has loaded', (tester) async {
    await pumpSelectPage(tester, const []);

    expect(find.text(inRangeId), findsOneWidget);
  });
}

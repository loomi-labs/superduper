import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/db.dart';
import 'package:superduper/repository.dart';

/// Auto-reconnect: the pure decision and the wiring that feeds it.
///
/// COVERAGE LIMIT: the three gates themselves (disconnect event, 10 s backstop,
/// initial connect at build) sit in the real-device branch of
/// [ConnectionHandler.build], which needs a [BluetoothDevice] and its platform
/// channels. A fake bike short-circuits to `connected` before any of them. So
/// what is tested here is the decision function and the fields it reads; the
/// gates are kept honest by all three call sites going through the single
/// `_shouldAttemptConnect` getter, which is `shouldAttemptConnect` and nothing
/// else. The transport behaviour itself is a hardware check.
///
/// The adapter half has the same limit and one more: an adapter event has no
/// fake input path at all, because the subscription is on `FlutterBluePlus`
/// itself and is deliberately never made for a fake bike. So what is tested is
/// the decision function plus the composition it reads.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'fa:ke:aa:bb:cc:dd';

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_reconnect_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  /// Puts bikes into bikes.json before anything reads it, so a bike can arrive
  /// the way an app restart delivers it: after the handler was already built.
  void seedBikesFile(List<BikeState> bikes) {
    File('${tempDir.path}/bikes.json').writeAsStringSync(jsonEncode(bikes));
  }

  /// A CH bike on off-road: a static selection, so nothing overrides the
  /// setting under test.
  BikeState staticBike({required bool autoReconnect}) =>
      BikeState.defaultState(id)
          .copyWith(autoReconnect: autoReconnect)
          .withSelectedMode(nativeModeId(chWireOffroad));

  /// A CH bike on the seeded 25 km/h mode, which switches profiles by speed.
  BikeState switchingBike({required bool autoReconnect}) =>
      BikeState.defaultState(id).copyWith(autoReconnect: autoReconnect);

  /// Builds the handler and keeps it alive for the whole test: it is
  /// autoDispose, and a rebuild between two assertions would re-seed the
  /// fields and make the listener assertions vacuous.
  ConnectionHandler openHandler(ProviderContainer container) {
    container.listen(connectionHandlerProvider(id), (previous, next) {});
    return container.read(connectionHandlerProvider(id).notifier);
  }

  group('shouldAutoReconnect', () {
    test('follows the setting for a static mode', () {
      expect(
          shouldAutoReconnect(
              autoReconnect: true, needsSpeedSwitching: false), isTrue);
      expect(
          shouldAutoReconnect(
              autoReconnect: false, needsSpeedSwitching: false), isFalse,
          reason: 'the whole point of the setting: stay away from the bike');
    });

    test('a speed-switching mode reconnects whatever the setting says', () {
      expect(
          shouldAutoReconnect(
              autoReconnect: true, needsSpeedSwitching: true), isTrue);
      expect(
          shouldAutoReconnect(
              autoReconnect: false, needsSpeedSwitching: true), isTrue,
          reason: 'the app is the speed limiter; it has to be able to recover');
    });
  });

  group('shouldAttemptConnect', () {
    test('an adapter that is off blocks every automatic connect', () {
      expect(
          shouldAttemptConnect(
              reconnectAllowed: true,
              adapterState: BluetoothAdapterState.off), isFalse,
          reason: 'retrying against a radio that is off is the log spam this '
              'gate exists to stop');
    });

    test('an unreported adapter is treated as usable', () {
      expect(
          shouldAttemptConnect(
              reconnectAllowed: true,
              adapterState: BluetoothAdapterState.unknown), isTrue,
          reason: 'a handler can be built before the first adapter event, and '
              'a silent platform must not lock the app out of its bike');
    });

    test('nothing but a fully on adapter is attempted', () {
      for (final adapterState in [
        BluetoothAdapterState.turningOn,
        BluetoothAdapterState.turningOff,
        BluetoothAdapterState.unauthorized,
        BluetoothAdapterState.unavailable,
      ]) {
        expect(
            shouldAttemptConnect(
                reconnectAllowed: true, adapterState: adapterState), isFalse,
            reason: '$adapterState fails a connect exactly like off does');
      }
      expect(
          shouldAttemptConnect(
              reconnectAllowed: true, adapterState: BluetoothAdapterState.on),
          isTrue);
    });

    test('the rider setting still wins over a working adapter', () {
      expect(
          shouldAttemptConnect(
              reconnectAllowed: false,
              adapterState: BluetoothAdapterState.on), isFalse,
          reason: 'a usable radio is no reason to go near a bike the rider '
              'asked the app to stay away from');
    });
  });

  group('rungFor', () {
    test('walks the ladder in order', () {
      expect(
          [for (var attempt = 0; attempt < 5; attempt++) rungFor(attempt)],
          const [
            Duration(seconds: 2),
            Duration(seconds: 2),
            Duration(seconds: 5),
            Duration(seconds: 5),
            Duration(seconds: 10),
          ],
          reason: 'the first attempts come fast, because a switching mode '
              'limits nothing while it is disconnected');
    });

    test('stays on the last rung for ever', () {
      for (final attempt in [5, 6, 20, 1000]) {
        expect(rungFor(attempt), const Duration(seconds: 10),
            reason: 'the ladder never gives up while auto-reconnect is on, so '
                'attempt $attempt still has to have a rung');
      }
    });

    test('a reset puts the ladder back on its first rung', () {
      expect(rungFor(0), const Duration(seconds: 2),
          reason: 'every successful connect resets the count to 0');
    });

    test('a count below zero reads as a reset', () {
      expect(rungFor(-1), const Duration(seconds: 2),
          reason: 'no caller can count down, but the ladder must not throw');
    });
  });

  group('handler wiring', () {
    test('a bike saved before the handler is built seeds it', () {
      final container = makeContainer();
      container
          .read(bikesDBProvider.notifier)
          .saveBike(staticBike(autoReconnect: false));

      final handler = openHandler(container);

      expect(handler.debugAutoReconnect, isFalse);
      expect(handler.debugNeedsSpeedSwitching, isFalse);
      expect(handler.debugReconnectAllowed, isFalse);
    });

    test('an unknown bike reconnects like it always did', () {
      final container = makeContainer();
      final handler = openHandler(container);

      expect(handler.debugAutoReconnect, isTrue);
      expect(handler.debugReconnectAllowed, isTrue);
    });

    test('saving the bike updates a handler that is already running', () {
      final container = makeContainer();
      final db = container.read(bikesDBProvider.notifier);
      db.saveBike(staticBike(autoReconnect: true));

      final handler = openHandler(container);
      expect(handler.debugReconnectAllowed, isTrue);

      db.saveBike(staticBike(autoReconnect: false));
      expect(handler.debugReconnectAllowed, isFalse,
          reason: 'turning the setting off has to reach a live handler');

      db.saveBike(staticBike(autoReconnect: true));
      expect(handler.debugReconnectAllowed, isTrue,
          reason: 'and turning it back on has to reach it as well');
    });

    test('the bikes.json load corrects the permissive seed', () async {
      seedBikesFile([staticBike(autoReconnect: false)]);
      final container = makeContainer();

      final handler = openHandler(container);
      expect(handler.debugAutoReconnect, isTrue,
          reason: 'the file has not landed yet, so the seed is the default');

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(handler.debugAutoReconnect, isFalse,
          reason: 'the listener has to correct the seed once the file lands');
      expect(handler.debugReconnectAllowed, isFalse);
    });

    test('a speed-switching mode overrides the setting on a live handler', () {
      final container = makeContainer();
      final db = container.read(bikesDBProvider.notifier);
      db.saveBike(switchingBike(autoReconnect: false));

      final handler = openHandler(container);
      expect(handler.debugAutoReconnect, isFalse);
      expect(handler.debugNeedsSpeedSwitching, isTrue);
      expect(handler.debugReconnectAllowed, isTrue,
          reason: 'the limiter has to be able to come back');

      // Off-road is static, so the setting takes full effect from here on.
      db.saveBike(staticBike(autoReconnect: false));
      expect(handler.debugReconnectAllowed, isFalse);
    });

    test('the adapter gate is composed on top of the rider setting', () {
      final container = makeContainer();
      final handler = openHandler(container);
      expect(handler.debugShouldAttemptConnect, isTrue,
          reason: 'a fresh handler has seen no adapter event yet, and that is '
              'not a reason to stay away from the bike');

      container
          .read(bikesDBProvider.notifier)
          .saveBike(staticBike(autoReconnect: false));
      expect(handler.debugReconnectAllowed, isFalse);
      expect(handler.debugShouldAttemptConnect, isFalse,
          reason: 'the gate the three automatic paths read has to carry the '
              'setting too, not only the radio state');
    });

    test('deleting the bike does not leave the handler gated', () async {
      final container = makeContainer();
      final db = container.read(bikesDBProvider.notifier);
      final bike = staticBike(autoReconnect: false);
      db.saveBike(bike);

      final handler = openHandler(container);
      expect(handler.debugReconnectAllowed, isFalse);

      db.deleteBike(bike);
      expect(handler.debugReconnectAllowed, isTrue,
          reason: 'a bike with no record is treated as an unknown one');

      // Let the fire-and-forget file IO settle before tearDown removes the dir.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });

  group('the Connect button', () {
    /// Pumps the button on its own, with the scan reporting [scanning].
    Future<(ProviderContainer, _RecordingRepository)> pumpButton(
        WidgetTester tester,
        {required bool scanning}) async {
      late ProviderContainer container;
      late _RecordingRepository repository;
      container = ProviderContainer(overrides: [
        isScanningStatusProvider.overrideWith((ref) => Stream.value(scanning)),
        bluetoothRepositoryProvider.overrideWith((ref) {
          repository = _RecordingRepository(ref,
              () => container.read(connectionHandlerProvider(id)));
          return repository;
        }),
      ]);
      addTearDown(container.dispose);
      // Built before the widget asks for it, so the recorder exists for the
      // assertions even if the button never reaches for the repository. A
      // `listen` rather than a `read`: a read closes its subscription again and
      // leaves an autoDispose timer pending past the end of the test.
      container.listen(bluetoothRepositoryProvider, (previous, next) {});
      container.listen(connectionHandlerProvider(id), (previous, next) {});
      container.read(connectionHandlerProvider(id).notifier).state =
          SDBluetoothConnectionState.disconnected;

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: EnhancedConnectionWidget(bike: BikeState.defaultState(id)),
          ),
        ),
      ));
      // Twice: the scan stream delivers its first value on a microtask.
      await tester.pump();
      await tester.pump();
      return (container, repository);
    }

    testWidgets('works while the startup scan is still running', (tester) async {
      // The sheet's own caption promises it: "The Connect button always works."
      // With auto-reconnect off, the select page's 100 s scan is exactly the
      // window a rider who just power-cycled the bike reaches for it in.
      final (container, repository) = await pumpButton(tester, scanning: true);

      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Connecting...'), findsNothing);
      expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNotNull,
          reason: 'a disabled button for up to 100 s is not "always works"');

      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(repository.stateAtStop, SDBluetoothConnectionState.disconnected,
          reason: 'the scan is stopped before the connect, not after it');
      expect(container.read(connectionHandlerProvider(id)),
          SDBluetoothConnectionState.connected);
    });

    testWidgets('leaves the scan alone when there is none', (tester) async {
      final (container, repository) = await pumpButton(tester, scanning: false);

      await tester.tap(find.text('Connect'));
      await tester.pump();

      expect(repository.stops, 0, reason: 'nothing to stop');
      expect(container.read(connectionHandlerProvider(id)),
          SDBluetoothConnectionState.connected);
    });
  });
}

/// A repository that records the scan stops the Connect button asks for, and
/// the connection state at the moment each one ran — a button that connected
/// first would report `connected` there.
class _RecordingRepository extends BluetoothRepository {
  _RecordingRepository(super.ref, this._stateNow);
  final SDBluetoothConnectionState Function() _stateNow;

  int stops = 0;
  SDBluetoothConnectionState? stateAtStop;

  @override
  Future<void> stopScan() async {
    stops++;
    stateAtStop = _stateNow();
  }

  /// The base class registers this on dispose, where it reaches for the
  /// platform's connected devices.
  @override
  Future<void> disconnect() async {}
}

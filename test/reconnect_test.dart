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
/// the decision function plus the composition it reads, through a debug entry
/// into the same handler method the subscription calls.
///
/// The ladder has the same limit again: a fake bike is connected from the first
/// moment, so the retry tick never makes an attempt and the reset a successful
/// connect does (in `_prepareConnection`, behind service discovery) is out of
/// reach. Tested here is the accounting of one attempt, which the tick and the
/// debug entry share, and every re-arm path that a handler with no radio can
/// take.
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

  group('mayAttemptReconnect', () {
    test('follows the setting for a static mode', () {
      expect(
          mayAttemptReconnect(
              autoReconnect: true,
              needsSpeedSwitching: false,
              ladderSpent: false),
          isTrue);
      expect(
          mayAttemptReconnect(
              autoReconnect: false,
              needsSpeedSwitching: false,
              ladderSpent: false),
          isFalse,
          reason: 'the whole point of the setting: stay away from the bike');
    });

    test('a speed-switching mode gets one run of the ladder', () {
      expect(
          mayAttemptReconnect(
              autoReconnect: false,
              needsSpeedSwitching: true,
              ladderSpent: false),
          isTrue,
          reason: 'the app is the speed limiter, so it gets a chance to come '
              'back even with the setting off');
      expect(
          mayAttemptReconnect(
              autoReconnect: false,
              needsSpeedSwitching: true,
              ladderSpent: true),
          isFalse,
          reason: 'and then it stops: endless attempts against a bike that is '
              'off are what the setting exists to prevent');
    });

    test('the setting outlives a spent ladder', () {
      expect(
          mayAttemptReconnect(
              autoReconnect: true,
              needsSpeedSwitching: true,
              ladderSpent: true),
          isTrue,
          reason: 'with the setting on the app never gives up');
      expect(
          mayAttemptReconnect(
              autoReconnect: true,
              needsSpeedSwitching: false,
              ladderSpent: true),
          isTrue);
    });
  });

  group('reconnectsForEver', () {
    test('only the rider setting grants attempts without an end', () {
      expect(reconnectsForEver(autoReconnect: true), isTrue);
      expect(reconnectsForEver(autoReconnect: false), isFalse,
          reason: 'a mode that switches by speed forces a run of the ladder, '
              'not a run without an end');
    });
  });

  group('reconnectLadderSpent', () {
    test('a forced ladder is spent after the last rung', () {
      for (final attempt in [1, 2, 3, 4]) {
        expect(reconnectLadderSpent(attempt: attempt, forEver: false), isFalse,
            reason: 'attempt $attempt still has a rung of its own');
      }
      expect(reconnectLadderSpent(attempt: 5, forEver: false), isTrue,
          reason: 'the ladder has five rungs — 2, 2, 5, 5, 10 s — and the '
              'attempt after the 10 s rung is the last one');
      expect(reconnectLadderSpent(attempt: 6, forEver: false), isTrue,
          reason: 'and it stays spent');
    });

    test('the last rung of a forced run is the 10 s one', () {
      expect(rungFor(4), const Duration(seconds: 10),
          reason: 'the wait before the fifth attempt, which is the last');
      expect(reconnectLadderSpent(attempt: 4, forEver: false), isFalse);
      expect(reconnectLadderSpent(attempt: 5, forEver: false), isTrue);
    });

    test('a ladder that may run for ever is never spent', () {
      for (final attempt in [5, 6, 20, 1000]) {
        expect(reconnectLadderSpent(attempt: attempt, forEver: true), isFalse,
            reason: 'with auto-reconnect on, attempt $attempt still has to '
                'have a rung');
      }
    });

    test('a ladder that made no attempt yet is not spent', () {
      expect(reconnectLadderSpent(attempt: 0, forEver: false), isFalse,
          reason: 'a re-arm puts the count back to 0, and the run starts '
              'again from there');
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

    test('an unknown bike does not reconnect on its own', () {
      final container = makeContainer();
      final handler = openHandler(container);

      expect(handler.debugAutoReconnect, isFalse);
      expect(handler.debugReconnectAllowed, isFalse);
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

    test('the bikes.json load corrects the conservative seed', () async {
      seedBikesFile([staticBike(autoReconnect: true)]);
      final container = makeContainer();

      final handler = openHandler(container);
      expect(handler.debugAutoReconnect, isFalse,
          reason: 'the file has not landed yet, so the seed is the default');

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(handler.debugAutoReconnect, isTrue,
          reason: 'the listener has to correct the seed once the file lands');
      expect(handler.debugReconnectAllowed, isTrue);
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
      final db = container.read(bikesDBProvider.notifier);
      db.saveBike(staticBike(autoReconnect: true));

      final handler = openHandler(container);
      expect(handler.debugShouldAttemptConnect, isTrue,
          reason: 'this handler has seen no adapter event yet, and that is '
              'not a reason to stay away from a bike the rider asked for');

      db.saveBike(staticBike(autoReconnect: false));
      expect(handler.debugReconnectAllowed, isFalse);
      expect(handler.debugShouldAttemptConnect, isFalse,
          reason: 'the gate the three automatic paths read has to carry the '
              'setting too, not only the radio state');
    });

    test('deleting the bike returns the handler to the default', () async {
      final container = makeContainer();
      final db = container.read(bikesDBProvider.notifier);
      final bike = staticBike(autoReconnect: true);
      db.saveBike(bike);

      final handler = openHandler(container);
      expect(handler.debugReconnectAllowed, isTrue);

      db.deleteBike(bike);
      expect(handler.debugReconnectAllowed, isFalse,
          reason: 'a bike with no record is treated as an unknown one');

      // Let the fire-and-forget file IO settle before tearDown removes the dir.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });

  group('the ladder gives up, and what re-arms it', () {
    /// Runs the accounting of one whole forced ladder — the five attempts the
    /// timer makes on its rungs. A fake bike is always connected, so the tick
    /// itself never runs; this drives the same accounting the tick does.
    void runTheLadder(ConnectionHandler handler) {
      for (var attempt = 0; attempt < 5; attempt++) {
        handler.debugNoteAttempt();
      }
    }

    /// A handler on a switching bike with the setting off: the only case that
    /// has a forced ladder to spend.
    ConnectionHandler forcedHandler(ProviderContainer container) {
      container
          .read(bikesDBProvider.notifier)
          .saveBike(switchingBike(autoReconnect: false));
      return openHandler(container);
    }

    test('a forced ladder stops the handler after its last rung', () {
      final container = makeContainer();
      final handler = forcedHandler(container);
      expect(handler.debugReconnectAllowed, isTrue);

      for (var attempt = 0; attempt < 4; attempt++) {
        handler.debugNoteAttempt();
        expect(handler.debugLadderSpent, isFalse);
        expect(handler.debugReconnectAllowed, isTrue,
            reason: 'the run is not over after ${attempt + 1} attempts');
      }

      handler.debugNoteAttempt();
      expect(handler.debugLadderSpent, isTrue);
      expect(handler.debugReconnectAllowed, isFalse,
          reason: 'the fifth attempt is the one after the 10 s rung, and the '
              'forced run gets no more');
      expect(handler.debugShouldAttemptConnect, isFalse,
          reason: 'the gate every automatic path reads has to carry it too');
    });

    test('the setting on keeps the handler attempting for ever', () {
      final container = makeContainer();
      container
          .read(bikesDBProvider.notifier)
          .saveBike(switchingBike(autoReconnect: true));
      final handler = openHandler(container);

      for (var attempt = 0; attempt < 20; attempt++) {
        handler.debugNoteAttempt();
      }

      expect(handler.debugLadderSpent, isFalse);
      expect(handler.debugReconnectAllowed, isTrue,
          reason: 'the rider asked the app to keep the bike, so it keeps '
              'trying for as long as the radio is on');
    });

    test('a static bike with the setting off makes no attempt at all', () {
      final container = makeContainer();
      container
          .read(bikesDBProvider.notifier)
          .saveBike(staticBike(autoReconnect: false));
      final handler = openHandler(container);

      expect(handler.debugReconnectAllowed, isFalse);
      expect(handler.debugLadderSpent, isFalse,
          reason: 'there is no ladder to spend: nothing forces a run');
      expect(handler.debugReconnectAttempt, 0);
    });

    testWidgets('a bike page that opens re-arms a ladder that gave up',
        (tester) async {
      // Not the handler being built: a bike that needs enforcement keeps its
      // notifier alive with no UI, so the handler of a page that is popped and
      // opened again is the same one, with the same spent ladder. The page has
      // to ask for the connect itself.
      final container = ProviderContainer();
      final handler = forcedHandler(container);
      runTheLadder(handler);
      expect(handler.debugLadderSpent, isTrue);
      // What a spent ladder leaves behind: a bike nothing is trying for.
      // ignore: invalid_use_of_protected_member
      handler.state = SDBluetoothConnectionState.disconnected;

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BikePage(bikeID: id)),
      ));
      // Past the settle of the re-assert every reconnect runs, so the page's
      // own follow-up work leaves no timer of its own behind.
      await tester.pump(const Duration(seconds: 2));

      expect(handler.debugLadderSpent, isFalse);
      expect(handler.debugReconnectAttempt, 0);
      expect(handler.debugReconnectAllowed, isTrue);
      expect(container.read(connectionHandlerProvider(id)),
          SDBluetoothConnectionState.connected,
          reason: 'the page open asks for the bike, not only for the rungs');
      container.dispose();
    });

    test('the Connect button re-arms a ladder that gave up', () async {
      final container = makeContainer();
      final handler = forcedHandler(container);
      runTheLadder(handler);
      expect(handler.debugLadderSpent, isTrue);

      // The exact call the button makes (EnhancedConnectionWidget).
      await handler.connect();

      expect(handler.debugLadderSpent, isFalse);
      expect(handler.debugReconnectAttempt, 0);
      expect(handler.debugReconnectAllowed, isTrue,
          reason: 'a rider who asks for the bike asks for the ladder as well');
    });

    test('the app coming back to the foreground re-arms it', () {
      final container = makeContainer();
      final handler = forcedHandler(container);
      runTheLadder(handler);

      handler.debugAppResumed();

      expect(handler.debugLadderSpent, isFalse);
      expect(handler.debugReconnectAttempt, 0);
      expect(handler.debugReconnectAllowed, isTrue,
          reason: 'the rider is looking at the app again, so the app looks '
              'for the bike again');
    });

    test('the radio coming back on re-arms it', () {
      final container = makeContainer();
      final handler = forcedHandler(container);
      runTheLadder(handler);

      handler.debugAdapterState(BluetoothAdapterState.off);
      expect(handler.debugLadderSpent, isTrue,
          reason: 'a radio that goes off is no reason to try again');

      handler.debugAdapterState(BluetoothAdapterState.on);

      expect(handler.debugLadderSpent, isFalse);
      expect(handler.debugReconnectAttempt, 0);
      expect(handler.debugReconnectAllowed, isTrue);
    });

    test('an attempt after a re-arm starts the run again', () {
      final container = makeContainer();
      final handler = forcedHandler(container);
      runTheLadder(handler);
      handler.debugAppResumed();

      for (var attempt = 0; attempt < 4; attempt++) {
        handler.debugNoteAttempt();
        expect(handler.debugLadderSpent, isFalse,
            reason: 'the second run gets the same five rungs as the first');
      }
      handler.debugNoteAttempt();
      expect(handler.debugLadderSpent, isTrue,
          reason: 'and it gives up again at the end of them');
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
      // The Connect button is the rider's manual way in, so it always works.
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

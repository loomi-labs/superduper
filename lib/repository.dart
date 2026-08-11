import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:superduper/db.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/models.dart';
import 'package:superduper/services.dart';
import 'package:superduper/utils/logger.dart'; // Import the logger

part 'repository.g.dart';

enum SDBluetoothConnectionState {
  disconnected,
  connected,
  connecting,
  disconnecting,
}

/// Whether the app may connect to a bike on its own — on the disconnect event,
/// from the retry timer, and when a handler is first built.
///
/// Turning auto-reconnect off is how a rider gets the bike back to its own
/// defaults: power-cycle it and this app stays away instead of writing its
/// settings back. A mode that switches profiles by speed cannot honour that —
/// it is only a limiter while the app can reach the bike, so it keeps
/// reconnecting either way. The manual Connect button never consults this.
bool shouldAutoReconnect({
  required bool autoReconnect,
  required bool needsSpeedSwitching,
}) =>
    autoReconnect || needsSpeedSwitching;

/// Whether an automatic connect can do anything at all right now: the rider's
/// setting and the state of the radio are two separate questions, and both have
/// to say yes.
///
/// [BluetoothAdapterState.unknown] is permissive: a handler can be built before
/// the first adapter event arrives, and a platform that never reports one must
/// not lock the app out of its own bike. [BluetoothAdapterState.turningOn] is
/// not: a connect there fails exactly like one with the adapter off, and the
/// `on` that follows within moments retries immediately anyway.
bool shouldAttemptConnect({
  required bool reconnectAllowed,
  required BluetoothAdapterState adapterState,
}) =>
    reconnectAllowed &&
    (adapterState == BluetoothAdapterState.on ||
        adapterState == BluetoothAdapterState.unknown);

/// How long the retry ladder waits before each attempt, by the number of
/// attempts already made since the last successful connect.
///
/// The first rungs are short because a mode that switches profiles by speed
/// limits nothing at all while the bike is out of reach, so the app has to get
/// back fast. The rungs then grow, because a bike that is really away — off, or
/// out of range — must not be asked every two seconds for the rest of the day.
const _reconnectRungs = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 5),
  _reconnectCap,
];

/// The last rung, which the ladder then keeps for ever: there is no give-up
/// state while auto-reconnect is on. Also the idle cadence, see [_nextDelay].
const _reconnectCap = Duration(seconds: 10);

/// The rung for [attempt], counted from 0 for the first attempt after a reset.
/// Past the end of the ladder every attempt gets the last rung.
Duration rungFor(int attempt) =>
    _reconnectRungs[attempt.clamp(0, _reconnectRungs.length - 1)];

BikeState? _findBike(List<BikeState> bikes, String deviceId) {
  for (final bike in bikes) {
    if (bike.id == deviceId) return bike;
  }
  return null;
}

@riverpod
Stream<BluetoothAdapterState> adapterState(Ref ref) =>
    FlutterBluePlus.adapterState;

@riverpod
Stream<bool> isScanningStatus(Ref ref) => FlutterBluePlus.isScanning;

@riverpod
Stream<List<ScanResult>> scanResults(Ref ref) =>
    FlutterBluePlus.scanResults.map((results) {
      results.sort(
        (a, b) => a.device.remoteId.toString().compareTo(
          b.device.remoteId.toString(),
        ),
      );
      return results;
    });

@riverpod
Stream<List<BluetoothDevice>> connectedDevices(Ref ref) =>
    Stream<List<BluetoothDevice>>.periodic(
      const Duration(seconds: 1),
      (x) => FlutterBluePlus.connectedDevices,
    );

@riverpod
class ConnectionHandler extends _$ConnectionHandler {
  // Ride data request: select the ride data register, then ask the bike to
  // stream it. Speed arrives as notifications on the register notifier.
  static const _rideDataId = [2, 3];
  static const _rideDataRequest = [2, 3, 0, 0, 0, 0, 0, 0, 0, 0];

  /// Settings write: the official app selects the settings register by writing
  /// the settings command byte to registerId before every write (see the
  /// reverse engineering report, "Write Settings"). Skipping it only worked as
  /// long as nothing else ever selected another register.
  static const _settingsId = [209];

  /// Timeout of the one attempt that follows a drop. Short on purpose: every
  /// successful reconnect in the 2026-08-07 ride log took 0.4 s to 2.6 s, so a
  /// bike that does not answer in three seconds is away, and the ladder should
  /// have the next attempt rather than this one waiting.
  static const _probeTimeout = Duration(seconds: 3);

  /// Timeout of every other attempt, the ladder's included. The tick waits for
  /// its attempt to finish before it arms the next rung, so the real gap
  /// between two attempts is the rung plus this. Well under the cap keeps that
  /// sum near the rung; the 35 s default made it the 35 s instead.
  static const _retryTimeout = Duration(seconds: 5);

  Timer? _reconnectTimer;

  /// Attempts made since the last successful connect, the ladder's position.
  int _reconnectAttempt = 0;
  late BluetoothDevice _device;
  StreamSubscription<BluetoothConnectionState>? _deviceSub;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;

  /// State of the phone's radio, as last reported. Seeded permissively, see
  /// [shouldAttemptConnect].
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;
  final StreamController<double> _speedController =
      StreamController<double>.broadcast();

  /// Guards [connect] against overlapping connection attempts.
  bool _connecting = false;

  /// Whether the radio link was really up before the last disconnect event.
  ///
  /// A failed attempt ends in a disconnect event as well, and answering that
  /// one with the immediate attempt of [_onDeviceConnectionState] would loop
  /// every three seconds and step over the ladder completely.
  bool _linkWasUp = false;

  /// Serializes the post-connect work of [_becomeReady]: `_readyAgain` records
  /// a (re)connect that arrived while a pass was still running, so it is re-run
  /// afterwards instead of dropped.
  bool _becomingReady = false;
  bool _readyAgain = false;

  /// Mirrors of this bike's record, kept current by [_trackReconnectSetting].
  /// Seeded permissively: an unknown bike reconnects like it always did.
  bool _autoReconnect = true;
  bool _needsSpeedSwitching = false;

  /// Whether the automatic connect paths may run right now.
  bool get _reconnectAllowed => shouldAutoReconnect(
      autoReconnect: _autoReconnect,
      needsSpeedSwitching: _needsSpeedSwitching);

  @visibleForTesting
  bool get debugAutoReconnect => _autoReconnect;

  @visibleForTesting
  bool get debugNeedsSpeedSwitching => _needsSpeedSwitching;

  /// The single question every automatic connect path asks.
  bool get _shouldAttemptConnect => shouldAttemptConnect(
      reconnectAllowed: _reconnectAllowed, adapterState: _adapterState);

  @visibleForTesting
  bool get debugReconnectAllowed => _reconnectAllowed;

  @visibleForTesting
  bool get debugShouldAttemptConnect => _shouldAttemptConnect;

  /// Speed reported by the bike, in km/h. Broadcast: the control loop and the
  /// UI can both listen.
  Stream<double> get speedStream {
    if (isFakeBike(deviceId)) {
      return ref.read(fakeBikeStoreProvider).speedStream(deviceId);
    }
    return _speedController.stream;
  }

  @override
  SDBluetoothConnectionState build(String deviceId) {
    ref.onDispose(_dispose);
    // Before the fake-bike return, so the wiring is exercised on fakes too.
    _trackReconnectSetting(deviceId);
    if (isFakeBike(deviceId)) {
      // No real device: never touch _device, never start timers.
      log.d(SDLogger.bluetooth, 'Fake bike $deviceId is always connected');
      return SDBluetoothConnectionState.connected;
    }
    _device = BluetoothDevice.fromId(deviceId);
    _deviceSub = _device.connectionState.listen(_onDeviceConnectionState);
    // A raw subscription, deliberately not ref.watch(adapterStateProvider): a
    // watch would rebuild this notifier on every radio transition, and a rebuild
    // runs ref.onDispose — closing the field-initialised _speedController for
    // good (the same trap _trackReconnectSetting documents). A riverpod
    // StreamProvider is no use either, because it pauses as soon as nothing
    // actively listens to it, and this handler has to keep working with no UI
    // mounted at all.
    _adapterState = FlutterBluePlus.adapterStateNow;
    _adapterSub = FlutterBluePlus.adapterState.listen(_onAdapterState);
    // Retries anything that is not fully ready, not just disconnects, so a
    // failed readiness pass cannot strand the bike. It carries the whole retry
    // ladder: the attempt on the drop itself comes from
    // _onDeviceConnectionState, and every attempt after that comes from here.
    //
    // The timer keeps running while auto-reconnect is off and the tick does
    // nothing: turning the setting back on then resumes within 10 s, with no
    // re-arming to get wrong. The tick idles the same way while the adapter is
    // off — there is nothing to retry against a radio that is not there — and
    // _onAdapterState makes the resume immediate rather than up to 10 s late.
    //
    // Armed with the cap and not with _nextDelay(): `state` cannot be read
    // before build returns. The first tick is 10 s away, as it always was.
    _armReconnectTimer(_reconnectCap);
    if (!_reconnectAllowed) {
      // Reported as disconnected rather than connecting: the Connect button
      // only enables on a disconnected bike, and this bike is now waiting for
      // exactly that button. _deviceSub still picks up a link that is already
      // up, so an already-connected bike is not pushed away either.
      log.i(SDLogger.bluetooth,
          'Auto-reconnect off for $deviceId, waiting for a manual connect');
      return SDBluetoothConnectionState.disconnected;
    }
    if (!_shouldAttemptConnect) {
      // Same reasoning, other reason: the setting says yes but the radio cannot
      // carry a connection yet. _onAdapterState connects as soon as it can.
      log.i(SDLogger.bluetooth,
          'Bluetooth is $_adapterState, waiting for it to come on ($deviceId)');
      return SDBluetoothConnectionState.disconnected;
    }
    connect();
    return SDBluetoothConnectionState.connecting;
  }

  /// Seeds and then tracks the two record fields the reconnect gates read.
  ///
  /// Deliberately `ref.listen`, never `ref.watch`: a watch would rebuild this
  /// notifier on every save, and a rebuild runs `ref.onDispose` — closing the
  /// field-initialised [_speedController] for good, so every later speed sample
  /// would be dropped and a switching mode would go blind. [bikesDBProvider] is
  /// keepAlive with no dependencies of its own, so listening cannot cycle back.
  ///
  /// Accepted race: a handler built before bikes.json finished loading sees an
  /// empty list and seeds `true`; the listener corrects it as soon as the file
  /// lands. In practice the select page has loaded the DB long before a bike
  /// can be opened.
  void _trackReconnectSetting(String deviceId) {
    _applyBikeRecord(ref.read(bikesDBProvider.notifier).getBike(deviceId));
    ref.listen(bikesDBProvider, (previous, next) {
      _applyBikeRecord(_findBike(next, deviceId));
    });
  }

  void _applyBikeRecord(BikeState? bike) {
    _autoReconnect = bike?.autoReconnect ?? true;
    _needsSpeedSwitching = bike?.needsSpeedSwitching ?? false;
  }

  void _onDeviceConnectionState(BluetoothConnectionState dstate) {
    log.d(SDLogger.bluetooth,
        'Connection state: $dstate (${_device.remoteId})');
    if (!ref.mounted) return;
    if (dstate == BluetoothConnectionState.connected) {
      _linkWasUp = true;
      // Not "connected" for our purposes yet: services and notifications have
      // to be set up first, otherwise writes are silently dropped.
      _becomeReady();
    } else if (dstate == BluetoothConnectionState.disconnected) {
      // Tearing down and reporting the drop is unconditional; only the
      // reconnect itself is the rider's choice.
      _cancelNotifications();
      state = SDBluetoothConnectionState.disconnected;
      final wasUp = _linkWasUp;
      _linkWasUp = false;
      // One attempt straight away, with the short probe timeout: a bike that
      // is still there answers it inside three seconds. Only for a link that
      // was really up — the same event follows a failed attempt, and the
      // ladder owns everything after the first failure.
      if (wasUp && _shouldAttemptConnect) connect(timeout: _probeTimeout);
      // A timer left over from the connected bike can be a full 10 s away, and
      // the ladder has to have its first rung 2 s from the drop.
      _armReconnectTimer(_nextDelay());
    }
  }

  /// Turning the radio off produces a disconnect for every bike, and every
  /// reconnect that follows is doomed until it comes back — the second source
  /// of the retry spam a ride log is otherwise full of.
  void _onAdapterState(BluetoothAdapterState adapterState) {
    if (!ref.mounted) return;
    // The stream replays its current value to every new listener, so the first
    // event usually says nothing new.
    if (adapterState == _adapterState) return;
    _adapterState = adapterState;
    log.i(SDLogger.bluetooth,
        'Bluetooth adapter $adapterState (${_device.remoteId})');
    if (_shouldAttemptConnect &&
        state != SDBluetoothConnectionState.connected) {
      // Brings the bike back the moment the radio is usable again instead of up
      // to 10 s later; an attempt the timer starts at the same time is absorbed
      // by the _connecting guard.
      connect();
    }
  }

  /// The wait before the next tick. A bike that is connected, or one the gates
  /// keep the app away from, has nothing to retry, so it waits the cap: a 2 s
  /// wakeup that can never do anything only costs battery.
  Duration _nextDelay() =>
      state == SDBluetoothConnectionState.connected || !_shouldAttemptConnect
          ? _reconnectCap
          : rungFor(_reconnectAttempt);

  void _armReconnectTimer(Duration delay) {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, _onReconnectTick);
  }

  /// One rung of the ladder. Self-rescheduling rather than periodic, so each
  /// wait can differ, and re-armed only after the attempt has finished: a rung
  /// is the gap between two attempts and can never overlap the one before it.
  Future<void> _onReconnectTick() async {
    if (!ref.mounted) return;
    if (state != SDBluetoothConnectionState.connected &&
        _shouldAttemptConnect &&
        // An attempt is still running. It would be dropped by the guard in
        // connect(), and a dropped attempt must not cost a rung.
        !_connecting) {
      // Counted before the attempt: a successful one resets the count itself,
      // and counting afterwards would undo that reset.
      _reconnectAttempt++;
      await connect(timeout: _retryTimeout);
      if (!ref.mounted) return;
    }
    _armReconnectTimer(_nextDelay());
  }

  void _dispose() {
    log.d(SDLogger.bluetooth, "DISPOSE ConnectionHandler");
    _deviceSub?.cancel();
    _adapterSub?.cancel();
    _reconnectTimer?.cancel();
    _cancelNotifications();
    _speedController.close();
  }

  /// Connects, waiting at most [timeout] for the bike to answer.
  ///
  /// The default serves the attempts a rider is waiting on — the Connect
  /// button, the first connect of a bike page, the one after the radio comes
  /// back. The drop probe asks for less ([_probeTimeout]) because the ladder
  /// takes over from it within two seconds.
  Future<void> connect({Duration timeout = _retryTimeout}) async {
    if (isFakeBike(deviceId)) {
      state = SDBluetoothConnectionState.connected;
      return;
    }
    if (_connecting) {
      log.d(SDLogger.bluetooth, 'Already connecting to ${_device.remoteId}');
      return;
    }
    _connecting = true;
    try {
      log.d(SDLogger.bluetooth, "Connecting to ${_device.remoteId}");
      if (_device.isConnected) {
        await _becomeReady();
        return;
      }

      state = SDBluetoothConnectionState.connecting;
      await _device.connect(mtu: null, license: License.free, timeout: timeout);
      if (!ref.mounted) return;
      // Bounded as well: connect() returns without waiting when the platform
      // reports that its request changed nothing, and this wait then has
      // nothing to complete it. Unbounded, it holds _connecting for ever and
      // every later attempt is dropped at the guard. The timeout goes on the
      // stream and not on the future, because that one also drops the
      // subscription instead of leaving one behind per failed attempt.
      await _device.connectionState
          .where((val) => val == BluetoothConnectionState.connected)
          .timeout(timeout)
          .first;
      if (!ref.mounted) return;
      log.i(SDLogger.bluetooth, 'Connected to ${_device.remoteId.str}');
      await _becomeReady();
    } catch (e) {
      log.e(SDLogger.bluetooth, 'Error connecting to ${_device.remoteId}', e);
      if (!ref.mounted) return;
      state = SDBluetoothConnectionState.disconnected;
    } finally {
      _connecting = false;
    }
  }

  /// Runs the readiness pass for every (re)connect. A connect event arriving
  /// while a pass is still running must not be dropped: the running pass may
  /// belong to a connection that is already gone, so the pass is re-run once
  /// for the newer connection instead.
  Future<void> _becomeReady() async {
    if (_becomingReady) {
      _readyAgain = true;
      return;
    }
    _becomingReady = true;
    try {
      do {
        _readyAgain = false;
        await _prepareConnection();
      } while (_readyAgain && ref.mounted);
    } finally {
      _becomingReady = false;
      _readyAgain = false;
    }
  }

  /// Everything between a raw BLE connection and a usable one: MTU, service
  /// discovery and the speed notifications. Only when all of it succeeds is the
  /// bike reported as [SDBluetoothConnectionState.connected], so callers never
  /// write into an undiscovered service, and a bike without a working
  /// notification channel stays in a state the retry path picks up.
  Future<void> _prepareConnection() async {
    try {
      if (Platform.isAndroid) {
        await _device.requestMtu(512);
        if (!ref.mounted) return;
      }
      await _device.discoverServices();
      if (!ref.mounted) return;
      await _subscribeNotifications();
      if (!ref.mounted) return;
      state = SDBluetoothConnectionState.connected;
      // Reset here and not on the raw connected event: a link that comes up and
      // drops again during discovery has not given the app a usable bike, and
      // it has to keep backing off.
      _reconnectAttempt = 0;
      await requestRideData();
    } catch (e) {
      log.e(SDLogger.bluetooth, 'Error preparing ${_device.remoteId}', e);
      if (!ref.mounted) return;
      state = SDBluetoothConnectionState.disconnected;
    }
  }

  Future<void> _subscribeNotifications() async {
    _cancelNotifications();
    if (_device.servicesList.isEmpty) {
      // Nothing was discovered at all: servicesList is cleared on disconnect,
      // so the link almost certainly dropped around discovery. Failing keeps
      // the bike out of the connected state, so the retry path re-arms it
      // instead of leaving a connection whose writes are dropped too.
      throw Exception('No services discovered on ${_device.remoteId}');
    }
    var char = _registerNotifier();
    if (char == null) {
      // Discovery worked, this bike simply has no register notifier: older
      // firmware. Everything except the speed stream works, so connect anyway —
      // refusing would strand a bike that was fine before speed existed. The
      // CH dynamic mode cannot switch on such hardware; its watchdog keeps
      // re-requesting ride data harmlessly.
      log.w(
        SDLogger.bluetooth,
        'No register notifier characteristic on ${_device.remoteId}, '
        'continuing without speed',
      );
      return;
    }
    await char.setNotifyValue(true);
    _notifySub = char.onValueReceived.listen(_onNotification);
    log.d(
      SDLogger.bluetooth,
      'Subscribed to notifications of ${_device.remoteId}',
    );
  }

  void _cancelNotifications() {
    _notifySub?.cancel();
    _notifySub = null;
  }

  BluetoothCharacteristic? _registerNotifier() {
    for (var service in _device.servicesList) {
      if (service.uuid != UUID_METRICS_SERVICE) continue;
      for (var char in service.characteristics) {
        if (char.uuid == UUID_CHARACTERISTIC_REGISTER_NOTIFIER) return char;
      }
    }
    return null;
  }

  /// A tap on the raw notification frames, or null in normal operation.
  ///
  /// The bike sends more frame types than the speed one, and everything that is
  /// not speed is dropped below without a trace. The boot calibration has to see
  /// those raw bytes: a cleaner power-on tell than the settings register may
  /// live in them, and only a real ride can show whether one is there.
  void Function(List<int> data)? onRawNotification;

  void _onNotification(List<int> data) {
    // Before the parse and before every drop, so the tap sees exactly what the
    // bike sent. What is dropped, and when, is unchanged.
    onRawNotification?.call(data);
    var speed = parseSpeedNotification(data);
    if (speed == null) return;
    if (_speedController.isClosed) return;
    _speedController.add(speed);
  }

  /// Asks the bike to start streaming ride data (speed among it). Has to be
  /// re-sent after every reconnect.
  Future<void> requestRideData() async {
    if (isFakeBike(deviceId)) {
      // A fake bike streams straight off the debug slider, so there is nothing
      // to ask for — but recording the request keeps the fake honest about
      // what the app did.
      ref.read(fakeBikeStoreProvider).noteRideDataRequest(deviceId);
      return;
    }
    var bt = ref.read(bluetoothRepositoryProvider);
    await bt.write(
      _device,
      data: _rideDataId,
      serviceId: UUID_METRICS_SERVICE,
      characteristicId: UUID_CHARACTERISTIC_REGISTER_ID,
    );
    await bt.write(
      _device,
      data: _rideDataRequest,
      serviceId: UUID_METRICS_SERVICE,
      characteristicId: UUID_CHARACTERISTIC_REGISTER,
    );
    log.d(SDLogger.bluetooth, 'Requested ride data from ${_device.remoteId}');
  }

  /// Writes a settings packet, selecting the settings register first.
  Future<void> write(List<int> data) async {
    if (isFakeBike(deviceId)) {
      ref.read(fakeBikeStoreProvider).write(deviceId, data);
      return;
    }
    var bt = ref.read(bluetoothRepositoryProvider);
    await bt.write(
      _device,
      data: _settingsId,
      serviceId: UUID_METRICS_SERVICE,
      characteristicId: UUID_CHARACTERISTIC_REGISTER_ID,
    );
    await bt.write(
      _device,
      data: data,
      serviceId: UUID_METRICS_SERVICE,
      characteristicId: UUID_CHARACTERISTIC_REGISTER,
    );
  }

  /// Reads a register: the settings register by default, or the one
  /// [registerId] selects — the boot calibration probes the odometer and the
  /// battery through the same path.
  Future<List<int>?> read({List<int>? registerId}) async {
    if (isFakeBike(deviceId)) {
      // A fake bike holds one register only, so it answers every id with it.
      return ref.read(fakeBikeStoreProvider).read(deviceId);
    }
    var bt = ref.read(bluetoothRepositoryProvider);
    await bt.write(
      _device,
      data: registerId ?? bt.currentStateId,
      serviceId: UUID_METRICS_SERVICE,
      characteristicId: UUID_CHARACTERISTIC_REGISTER_ID,
    );
    return await bt.read(
      _device,
      serviceId: UUID_METRICS_SERVICE,
      characteristicId: UUID_CHARACTERISTIC_REGISTER,
    );
  }
}

/// Speed of a single bike in km/h, so consumers can `ref.listen` to it.
@riverpod
Stream<double> bikeSpeed(Ref ref, String deviceId) =>
    ref.watch(connectionHandlerProvider(deviceId).notifier).speedStream;

@riverpod
BluetoothRepository bluetoothRepository(Ref ref) => BluetoothRepository(ref);

class BluetoothRepository {
  final currentStateId = [3, 0];
  Ref ref;

  BluetoothRepository(this.ref) {
    ref.onDispose(() {
      disconnect();
    });
  }

  Future<void> scan() async {
    log.i(SDLogger.bluetooth, 'Starting Bluetooth scan');
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        log.e(SDLogger.bluetooth, 'Error turning on bluetooth', e);
      }
    }
    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 100),
        withKeywords: [
          'SUPER${70 + 3}', // SUPER73
          'S${70 + 3} FTEX', // Additional keyword
        ],
      );
      log.d(SDLogger.bluetooth, 'Scan initiated with timeout: 100s');
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      log.d(SDLogger.bluetooth, 'Scan completed');
    } catch (e) {
      log.e(SDLogger.bluetooth, 'Error starting scan', e);
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      log.d(SDLogger.bluetooth, 'Scan stopped manually');
    } catch (e) {
      log.e(SDLogger.bluetooth, 'Error stopping scan', e);
    }
  }

  Future<void> disconnect() async {
    try {
      for (var device in FlutterBluePlus.connectedDevices) {
        await device.disconnect();
        log.i(SDLogger.bluetooth, 'Disconnected from ${device.remoteId.str}');
      }
    } catch (e) {
      log.e(SDLogger.bluetooth, 'Error disconnecting', e);
    }
  }

  Future<void> write(
    BluetoothDevice device, {
    required List<int> data,
    Guid? serviceId,
    Guid? characteristicId,
  }) async {
    serviceId ??= UUID_METRICS_SERVICE;
    characteristicId ??= UUID_CHARACTERISTIC_REGISTER;
    try {
      var servicesList = device.servicesList;
      if (servicesList.isEmpty) {
        log.w(
          SDLogger.bluetooth,
          'No services discovered for ${device.remoteId}, attempting discovery',
        );
        return;
      }

      // Find service with orElse to prevent exceptions
      var service = servicesList.firstWhere(
        (element) => element.uuid == serviceId,
        orElse: () => throw Exception('Service $serviceId not found'),
      );

      // Find characteristic with orElse to prevent exceptions
      var char = service.characteristics.firstWhere(
        (element) => element.uuid == characteristicId,
        orElse: () =>
            throw Exception('Characteristic $characteristicId not found'),
      );

      await char.write(data);
      log.d(SDLogger.bluetooth, 'Wrote data to ${device.remoteId.str}: $data');
    } catch (e) {
      log.e(SDLogger.bluetooth, 'Error writing to ${device.remoteId}', e);
    }
  }

  Future<List<int>?> read(
    BluetoothDevice device, {
    Guid? serviceId,
    Guid? characteristicId,
  }) async {
    serviceId ??= UUID_METRICS_SERVICE;
    characteristicId ??= UUID_CHARACTERISTIC_REGISTER;
    log.d(SDLogger.bluetooth, 'Reading from ${device.remoteId}');
    try {
      var servicesList = device.servicesList;
      if (servicesList.isEmpty) {
        log.w(
          SDLogger.bluetooth,
          'No services discovered for ${device.remoteId}, attempting discovery',
        );
        return null;
      }
      var service = servicesList.firstWhere(
        (element) => element.uuid == serviceId,
      );
      var char = service.characteristics.firstWhere(
        (element) => element.uuid == characteristicId,
      );
      final result = await char.read();
      log.d(
        SDLogger.bluetooth,
        'Read data from ${device.remoteId.str}: $result',
      );
      return result;
    } catch (e) {
      log.e(SDLogger.bluetooth, 'Error reading from ${device.remoteId}', e);
    }
    return null;
  }
}

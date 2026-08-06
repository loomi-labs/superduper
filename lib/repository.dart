import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:superduper/fake_bike.dart';
import 'package:superduper/services.dart';
import 'package:superduper/utils/logger.dart'; // Import the logger

part 'repository.g.dart';

enum SDBluetoothConnectionState {
  disconnected,
  connected,
  connecting,
  disconnecting,
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

  Timer? _reconnectTimer;
  late BluetoothDevice _device;
  StreamSubscription<BluetoothConnectionState>? _deviceSub;
  StreamSubscription<List<int>>? _notifySub;
  final StreamController<double> _speedController =
      StreamController<double>.broadcast();

  /// Guards [connect] against overlapping connection attempts.
  bool _connecting = false;

  /// Serializes the post-connect work of [_becomeReady]: `_readyAgain` records
  /// a (re)connect that arrived while a pass was still running, so it is re-run
  /// afterwards instead of dropped.
  bool _becomingReady = false;
  bool _readyAgain = false;

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
    if (isFakeBike(deviceId)) {
      // No real device: never touch _device, never start timers.
      log.d(SDLogger.bluetooth, 'Fake bike $deviceId is always connected');
      return SDBluetoothConnectionState.connected;
    }
    _device = BluetoothDevice.fromId(deviceId);
    _deviceSub = _device.connectionState.listen(_onDeviceConnectionState);
    // Backstop only: disconnects reconnect immediately, see
    // _onDeviceConnectionState. Retries anything that is not fully ready, not
    // just disconnects, so a failed readiness pass cannot strand the bike.
    _reconnectTimer = Timer.periodic(const Duration(seconds: 10), (t) {
      if (state != SDBluetoothConnectionState.connected) {
        connect();
      }
    });
    connect();
    return SDBluetoothConnectionState.connecting;
  }

  void _onDeviceConnectionState(BluetoothConnectionState dstate) {
    log.d(SDLogger.bluetooth, 'Connection state: $dstate');
    if (!ref.mounted) return;
    if (dstate == BluetoothConnectionState.connected) {
      // Not "connected" for our purposes yet: services and notifications have
      // to be set up first, otherwise writes are silently dropped.
      _becomeReady();
    } else if (dstate == BluetoothConnectionState.disconnected) {
      _cancelNotifications();
      state = SDBluetoothConnectionState.disconnected;
      connect();
    }
  }

  void _dispose() {
    log.d(SDLogger.bluetooth, "DISPOSE ConnectionHandler");
    _deviceSub?.cancel();
    _reconnectTimer?.cancel();
    _cancelNotifications();
    _speedController.close();
  }

  Future<void> connect() async {
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
      await _device.connect(mtu: null, license: License.free);
      if (!ref.mounted) return;
      await _device.connectionState
          .where((val) => val == BluetoothConnectionState.connected)
          .first;
      if (!ref.mounted) return;
      log.i(SDLogger.bluetooth, 'Connected to ${_device.remoteId.str}');
      await _becomeReady();
    } catch (e) {
      log.e(SDLogger.bluetooth, 'Error connecting', e);
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

  void _onNotification(List<int> data) {
    var speed = parseSpeedNotification(data);
    if (speed == null) return;
    if (_speedController.isClosed) return;
    _speedController.add(speed);
  }

  /// Asks the bike to start streaming ride data (speed among it). Has to be
  /// re-sent after every reconnect.
  Future<void> requestRideData() async {
    if (isFakeBike(deviceId)) return;
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

  Future<List<int>?> read() async {
    if (isFakeBike(deviceId)) {
      return ref.read(fakeBikeStoreProvider).read(deviceId);
    }
    var bt = ref.read(bluetoothRepositoryProvider);
    await bt.write(
      _device,
      data: bt.currentStateId,
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

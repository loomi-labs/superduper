enum BikeAdapterState { unknown, on, off, unavailable, unauthorized }

enum BikeConnectionState { disconnected, connecting, connected }

final class DiscoveredBike {
  const new({
    required this.deviceId,
    required this.name,
    required this.rssi,
    this.moduleSerial,
  });

  final String deviceId;
  final String name;
  final int rssi;
  final String? moduleSerial;
}

sealed class BikeTransportFailure implements Exception {
  const new(this.operation, this.message);

  final String operation;
  final String message;

  @override
  String toString() => '$operation: $message';
}

final class BikeAdapterUnavailable extends BikeTransportFailure {
  const new(String message, {this.canRetry = true})
    : super('Bluetooth', message);

  final bool canRetry;
}

final class BikeConnectionFailure extends BikeTransportFailure {
  /// [cause] is the platform error. It goes to the debug log only.
  const new(super.operation, super.message, {this.cause});

  final Object? cause;
}

final class BikeGattNotSupported extends BikeTransportFailure {
  const new(String message) : super('Service discovery', message);
}

abstract interface class BikeTransport {
  Stream<BikeAdapterState> get adapterStates;
  Stream<List<DiscoveredBike>> get scanResults;
  Stream<bool> get scanning;

  Future<void> startScan({Duration timeout = const Duration(seconds: 15)});
  Future<void> stopScan();
  BikeConnection openConnection(String deviceId);
  Future<void> dispose();
}

abstract interface class BikeConnection {
  String get deviceId;
  Stream<BikeConnectionState> get states;

  Future<void> connect();

  /// True when the platform can connect later, when the bike advertises.
  bool get supportsBackgroundConnect;

  /// Asks the platform to connect when the bike advertises. It returns when
  /// the platform accepted the request. [states] reports the connect. A
  /// running request ends first. [disconnect] ends the request.
  Future<void> connectInBackground();
  Future<void> discoverRequiredGatt();
  bool hasCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
  });
  Future<List<int>> readCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
  });
  Future<void> writeCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
    required List<int> value,
  });
  Stream<List<int>> characteristicNotifications({
    required String serviceUuid,
    required String characteristicUuid,
  });
  Future<void> setCharacteristicNotifications({
    required String serviceUuid,
    required String characteristicUuid,
    required bool enabled,
  });
  Future<void> disconnect();
  Future<void> dispose();
}

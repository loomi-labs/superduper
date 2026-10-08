import 'dart:async';
import 'dart:convert';

import 'package:signals/signals.dart';
import 'package:superduper/src/ble/bike_protocol.dart';
import 'package:superduper/src/ble/bike_transport.dart';
import 'package:superduper/src/ble/off_time_meter.dart';
import 'package:superduper/src/diagnostics/debug_log.dart';
import 'package:superduper/src/domain/bike.dart';

sealed class BikeSessionFailure implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => message;
}

final class BikeSessionTransportFailure extends BikeSessionFailure {
  const new(this.cause) : super('Bike communication failed: $cause');

  final Object cause;
}

final class BikeBluetoothUnavailable extends BikeSessionFailure {
  const new(super.message, {required this.canRetry});

  final bool canRetry;
}

final class BikeCommandTimedOut extends BikeSessionFailure {
  const new(String operation) : super('$operation timed out.');
}

final class BikeSessionDisposedFailure extends BikeSessionFailure {
  const new() : super('The bike session is disposed.');
}

final class BikeSessionNotReady extends BikeSessionFailure {
  const new() : super('The bike is not ready for controls.');
}

final class BikeAuthenticationFailed extends BikeSessionFailure {
  const new(String detail) : super('Bike authentication failed. $detail');
}

final class BikeProtocolNotSupported extends BikeSessionFailure {
  const new(String detail)
    : super('The bike protocol is not supported. $detail');
}

sealed class BikeSessionState {
  const new();
}

final class SessionIdle extends BikeSessionState {
  const new();
}

final class SessionConnecting extends BikeSessionState {
  const new();
}

final class SessionDiscovering extends BikeSessionState {
  const new();
}

final class SessionConnected extends BikeSessionState {
  const new();
}

final class SessionAuthenticating extends BikeSessionState {
  const new();
}

final class SessionSynchronizing extends BikeSessionState {
  const new({required this.attempt});

  final int attempt;
}

final class SessionReady extends BikeSessionState {
  const new({required this.configuration});

  final BikeConfiguration configuration;
}

final class SessionReconnecting extends BikeSessionState {
  const new({
    required this.attempt,
    required this.retryAfter,
    required this.failure,
  });

  final int attempt;
  final Duration retryAfter;
  final BikeSessionFailure failure;
}

final class SessionDisconnected extends BikeSessionState {
  const new({required this.manuallyPaused});

  final bool manuallyPaused;
}

final class SessionFailed extends BikeSessionState {
  const new({required this.failure, required this.canRetry});

  final BikeSessionFailure failure;
  final bool canRetry;
}

final class SessionDisposed extends BikeSessionState {
  const new();
}

typedef VersionsRead = Future<void> Function(BikeVersionInfo versions);
typedef OdometerRead = Future<void> Function(int meters);
typedef ManualConnectionPauseChanged = Future<void> Function(bool paused);

final class BikeSession {
  new({
    required this.connection,
    required BikeControlPatch setOnConnect,
    required BikeProtocolVersion protocol,
    List<int> authenticationKey = BikeProtocol.defaultAuthenticationKey,
    VersionsRead? onVersionsRead,
    OdometerRead? onOdometerRead,
    ManualConnectionPauseChanged? onManualConnectionPauseChanged,
    this.readDiagnosticsOnConnect = true,
    Duration commandTimeout = const Duration(seconds: 15),
    Duration? pollInterval,
    List<Duration> reconnectDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
    BikeProtocolDefinition? connectedProtocol,
    this._streetLegalOnQuickRestart = false,
    this._streetLegalStockMode = 0,
    this._counterSampleTimeout = const Duration(seconds: 3),
    DateTime Function()? clock,
    DebugLog debugLog = const NoopDebugLog(),
  }) : _protocolVersion = protocol,
       _clock = clock ?? DateTime.now,
       // The public named parameter keeps the log private.
       // ignore: prefer_initializing_formals
       _debugLog = debugLog,
       _authenticationKey = List<int>.unmodifiable(authenticationKey),
       _nextConnectionIntent = setOnConnect,
       _connectionIntent = setOnConnect,
       // The public named parameter keeps the callback implementation private.
       // ignore: prefer_initializing_formals
       _onVersionsRead = onVersionsRead,
       // The public named parameter keeps the callback implementation private.
       // ignore: prefer_initializing_formals
       _onOdometerRead = onOdometerRead,
       // The public named parameter keeps the callback implementation private.
       // ignore: prefer_initializing_formals
       _onManualConnectionPauseChanged = onManualConnectionPauseChanged,
       // The public named parameter keeps command policy private.
       // ignore: prefer_initializing_formals
       _commandTimeout = commandTimeout,
       // The public named parameter keeps connection policy private.
       // ignore: prefer_initializing_formals
       _pollInterval = pollInterval,
       _reconnectDelays = List.unmodifiable(reconnectDelays) {
    _protocol =
        connectedProtocol ??
        BikeProtocol.connected(
          version: protocol,
          connection: connection,
          timed: _timed,
        );
    if (reconnectDelays.any((delay) => delay.isNegative)) {
      throw ArgumentError.value(
        reconnectDelays,
        'reconnectDelays',
        'Must not contain negative durations.',
      );
    }
    BikeControlValues.validateMode(_streetLegalStockMode, protocol);
    BikeProtocol.authenticationResponse(
      challenge: List<int>.filled(20, 0),
      key: _authenticationKey,
    );
    _connectionSubscription = connection.states.listen(_onConnectionState);
    _logStateChanges();
  }

  final BikeConnection connection;
  final VersionsRead? _onVersionsRead;
  final OdometerRead? _onOdometerRead;
  final ManualConnectionPauseChanged? _onManualConnectionPauseChanged;
  final bool readDiagnosticsOnConnect;
  final Duration _commandTimeout;
  final Duration? _pollInterval;
  final List<Duration> _reconnectDelays;
  final BikeProtocolVersion _protocolVersion;
  final List<int> _authenticationKey;
  late final BikeProtocolDefinition _protocol;
  final _SerialCommandQueue _commands = _SerialCommandQueue();
  final Signal<BikeSessionState> _state = signal(
    const SessionIdle(),
    options: const SignalOptions(name: 'bikeSession.state'),
  );
  final Signal<BikeConfiguration?> _observed = signal(
    null,
    options: const SignalOptions(name: 'bikeSession.observed'),
  );
  final Signal<double?> _speedKmh = signal(
    null,
    options: const SignalOptions(name: 'bikeSession.speedKmh'),
  );
  final Signal<bool> _streetLegalLocked = signal(
    false,
    options: const SignalOptions(name: 'bikeSession.streetLegalLocked'),
  );
  bool _streetLegalOnQuickRestart;
  int _streetLegalStockMode;
  final Duration _counterSampleTimeout;
  late final OffTimeMeter _offTimeMeter = OffTimeMeter(
    clock: _clock,
    log: (message) => _log('meter', message),
  );
  final DebugLog _debugLog;
  StreamSubscription<List<int>>? _auxiliarySubscription;
  Completer<void>? _counterSampleWaiter;
  var _counterSampleLogged = false;
  int? _lastSessionMarker;
  // Counts the mode choices that ended the lock.
  var _lockEpoch = 0;
  Duration? _dropoutOnTime;

  ReadonlySignal<bool> get streetLegalLocked => _streetLegalLocked.readonly();

  /// The control-history marker of the last connect. Null when the
  /// preference was off.
  int? get lastSessionMarker => _lastSessionMarker;

  /// The bike on time across the last dropout (marker 1), from the counter.
  /// Null without counter samples.
  Duration? get dropoutOnTime => _dropoutOnTime;

  DateTime? _lastSpeedAt;
  ReadonlySignal<double?> get speedKmh => _speedKmh.readonly();
  DateTime? get lastSpeedAt => _lastSpeedAt;
  final Signal<BikeConfiguration?> _pending = signal(
    null,
    options: const SignalOptions(name: 'bikeSession.pending'),
  );
  final Signal<BikeVersionInfo?> _versions = signal(
    null,
    options: const SignalOptions(name: 'bikeSession.versions'),
  );
  final Signal<int?> _odometerMeters = signal(
    null,
    options: const SignalOptions(name: 'bikeSession.odometerMeters'),
  );

  late final StreamSubscription<BikeConnectionState> _connectionSubscription;
  StreamSubscription<List<int>>? _telemetrySubscription;
  BikeControlPatch _nextConnectionIntent;
  BikeControlPatch _connectionIntent;
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  var _generation = 0;
  var _reconnectAttempt = 0;
  var _disposed = false;
  var _manualReconnectPaused = false;
  var _foregroundPaused = false;
  var _disconnectRequested = false;
  var _expectedDisconnect = false;
  var _hasObservedConnection = false;
  final DateTime Function() _clock;
  Future<void>? _connectFuture;
  Future<void>? _connectRequestFuture;
  int? _connectFutureGeneration;
  int? _platformConnectGeneration;
  Future<BikeConfiguration>? _configurationChangeFuture;
  int? _configurationChangeGeneration;
  BikeControlPatch? _pendingControls;

  String get deviceId => connection.deviceId;

  /// The connection generation. The debug log lines carry it.
  int get generation => _generation;
  ReadonlySignal<BikeSessionState> get state => _state.readonly();
  ReadonlySignal<BikeConfiguration?> get observed => _observed.readonly();
  ReadonlySignal<BikeConfiguration?> get pending => _pending.readonly();
  ReadonlySignal<BikeVersionInfo?> get versions => _versions.readonly();
  ReadonlySignal<int?> get odometerMeters => _odometerMeters.readonly();
  BikeProtocolVersion get protocolVersion => _protocolVersion;
  bool get canChangeConfiguration {
    if (_disposed ||
        _disconnectRequested ||
        !_hasObservedConnection ||
        _observed.peek() == null) {
      return false;
    }
    return switch (_state.peek()) {
      SessionReady() || SessionSynchronizing() => true,
      _ => false,
    };
  }

  Future<void> connect() {
    _ensureNotDisposed();
    final request = _connectRequestFuture;
    if (request != null) {
      _log('link', 'connect skipped: a connect request runs');
      return request;
    }
    final pending = _connectFuture;
    if (_connectFutureGeneration == _generation && pending != null) {
      _log('link', 'connect skipped: a connect of this generation runs');
      return pending;
    }
    final currentState = _state.peek();
    if (!_disconnectRequested &&
        _hasObservedConnection &&
        (currentState is SessionReady ||
            currentState is SessionSynchronizing)) {
      _log('link', 'connect skipped: the link is up');
      return Future.value();
    }
    _log('link', 'connect requested');
    late final Future<void> next;
    next = _connectAfterManualPause().whenComplete(() {
      if (identical(_connectRequestFuture, next)) {
        _connectRequestFuture = null;
      }
    });
    _connectRequestFuture = next;
    return next;
  }

  Future<void> _connectAfterManualPause() async {
    await _onManualConnectionPauseChanged?.call(false);
    _ensureNotDisposed();
    final pending = _connectFuture;
    if (_connectFutureGeneration == _generation && pending != null) {
      _log('link', 'connect joins a running connect');
      await pending;
      return;
    }
    final currentState = _state.peek();
    if (!_disconnectRequested &&
        _hasObservedConnection &&
        (currentState is SessionReady ||
            currentState is SessionSynchronizing)) {
      _log('link', 'connect dropped: the link came up while waiting');
      return;
    }
    _invalidateConfigurationState();
    _manualReconnectPaused = false;
    _foregroundPaused = false;
    _disconnectRequested = false;
    _nextGeneration('connect');
    _reconnectAttempt = 0;
    _reconnectTimer?.cancel();
    await _startConnect();
  }

  Future<void> retry() => connect();

  Future<void> synchronize() {
    _ensureNotDisposed();
    return _commands.add(() async {
      try {
        await _synchronizeNow();
      } on Object catch (error) {
        final failure = _asFailure(error);
        if (failure is BikeSessionDisposedFailure) {
          throw failure;
        }
        _log('config', 'synchronize failed: ${_describeFailure(failure)}');
        if (_isConnectionFailure(failure)) {
          _clearPendingConfiguration();
          _scheduleReconnect(failure);
        } else {
          _clearPendingConfiguration();
          _state.value = SessionFailed(failure: failure, canRetry: true);
        }
        throw failure;
      }
    });
  }

  Future<void> requestRideData() {
    _ensureNotDisposed();
    final generation = _generation;
    return _commands.add(() async {
      if (!_isCurrent(generation) || !_hasObservedConnection) {
        return;
      }
      await _protocol.requestRideData();
    });
  }

  Future<BikeConfiguration> setLight(bool value) {
    return setControls(BikeControlPatch(light: value));
  }

  Future<BikeConfiguration> setMode(int value) {
    BikeControlValues.validateMode(value, _protocolVersion);
    return setControls(BikeControlPatch(mode: value));
  }

  Future<BikeConfiguration> setAssist(int value) {
    BikeControlValues.validateAssist(value);
    return setControls(BikeControlPatch(assist: value));
  }

  Future<BikeConfiguration> setControls(BikeControlPatch controls) {
    return _changeConfiguration(controls);
  }

  void updateSetOnConnect(BikeControlPatch settings) {
    _nextConnectionIntent = settings;
  }

  void updateStreetLegalOnQuickRestart(bool enabled, {required int stockMode}) {
    if (_disposed) {
      return;
    }
    BikeControlValues.validateMode(stockMode, _protocolVersion);
    final wasEnabled = _streetLegalOnQuickRestart;
    _streetLegalOnQuickRestart = enabled;
    _streetLegalStockMode = stockMode;
    _log(
      'lock',
      'preference updated: enabled=$wasEnabled -> $enabled stockWire='
          '$stockMode',
    );
    if (!enabled) {
      _streetLegalLocked.value = false;
      _offTimeMeter.clear('preference turned off');
      unawaited(_disableAuxiliaryCounter());
      if (wasEnabled && _hasObservedConnection) {
        // The bike stops its notifications, one each second.
        final generation = _generation;
        unawaited(
          _commands
              .add(() async {
                if (_isCurrent(generation) && _hasObservedConnection) {
                  await _stopAuxiliaryCounterOnBike();
                }
              })
              .catchError((Object error) {
                _log('meter', 'stopping the counter failed: $error');
              }),
        );
      }
      return;
    }
    if (!wasEnabled) {
      // Samples and losses from the time of the off preference are no basis
      // for an off time.
      _offTimeMeter.clear('preference turned on');
    }
    if (!wasEnabled && _hasObservedConnection) {
      // The counter starts at once, so the next restart has a sample.
      final generation = _generation;
      unawaited(
        _commands
            .add(() async {
              if (_isCurrent(generation) && _hasObservedConnection) {
                await _enableAuxiliaryCounter();
              }
            })
            .catchError((Object error) {
              _log('meter', 'starting the counter failed: $error');
            }),
      );
    }
  }

  /// The rider chose a mode: the lock ends, and the next write carries
  /// marker 1.
  void endStreetLegalLock() {
    if (!_disposed) {
      _lockEpoch++;
      _log(
        'lock',
        'rider chose a mode: epoch=$_lockEpoch locked='
            '${_streetLegalLocked.peek()} -> false',
      );
      _streetLegalLocked.value = false;
    }
  }

  /// Puts back a lock that a failed mode choice ended too early.
  void restoreStreetLegalLock(bool locked) {
    if (!_disposed) {
      _log(
        'lock',
        'restore lock after a failed mode choice: '
            '${_streetLegalLocked.peek()} -> $locked',
      );
      _streetLegalLocked.value = locked;
    }
  }

  /// The parked fallback: writes the stock mode with marker 2. The lock
  /// starts only when the bike accepted the write.
  Future<void> startStreetLegalLock() {
    _ensureNotDisposed();
    if (!canChangeConfiguration) {
      _log('lock', 'start lock refused: the session cannot change controls');
      throw const BikeSessionNotReady();
    }
    final generation = _generation;
    final epoch = _lockEpoch;
    _log('lock', 'start lock requested, epoch=$epoch');
    return _commands.add(() async {
      if (!_isCurrent(generation) || !_hasObservedConnection) {
        throw const BikeSessionDisposedFailure();
      }
      final current = _observed.peek();
      if (current == null) {
        throw const BikeSessionNotReady();
      }
      final target = current.copyWith(mode: _streetLegalStockMode);
      _pollTimer?.cancel();
      _state.value = const SessionSynchronizing(attempt: 1);
      _log(
        'lock',
        'write stock wire $_streetLegalStockMode marker '
            '${BikeGatt.sessionLockedMarker} (observed '
            '${_describeConfig(current)})',
      );
      try {
        await _protocol.writeConfiguration(
          target,
          marker: BikeGatt.sessionLockedMarker,
        );
        if (!_isCurrent(generation) || !_hasObservedConnection) {
          throw const BikeSessionDisposedFailure();
        }
      } on Object catch (error) {
        final failure = _asFailure(error);
        _log('lock', 'stock write failed: ${_describeFailure(failure)}');
        if (_isConnectionFailure(failure)) {
          _scheduleReconnect(failure);
        } else if (failure is! BikeSessionDisposedFailure) {
          _state.value = SessionFailed(failure: failure, canRetry: true);
        }
        throw failure;
      }
      _publishObserved(target);
      // A mode choice after this call ended the lock: it stays off.
      if (epoch == _lockEpoch) {
        _log('lock', 'stock write accepted -> lock ON');
        _streetLegalLocked.value = true;
      } else {
        _log(
          'lock',
          'stock write accepted, but a mode choice moved the epoch '
              '($epoch -> $_lockEpoch) -> lock stays OFF',
        );
      }
      _markReady(target);
    });
  }

  Future<void> disconnect() async {
    _ensureNotDisposed();
    final wasManuallyPaused = _manualReconnectPaused;
    _log('link', 'disconnect requested, wasPaused=$wasManuallyPaused');
    _manualReconnectPaused = true;
    _foregroundPaused = false;
    final disconnect = _enqueueDisconnect(
      manuallyPaused: true,
      abortPendingConnect: true,
    );
    try {
      if (!wasManuallyPaused) {
        await _onManualConnectionPauseChanged?.call(true);
      }
    } finally {
      await disconnect;
    }
  }

  Future<void> pauseForBackground() async {
    if (_disposed || _manualReconnectPaused || _foregroundPaused) {
      _log(
        'link',
        'pause skipped: disposed=$_disposed manual=$_manualReconnectPaused '
            'paused=$_foregroundPaused',
      );
      return;
    }
    _log('link', 'pause for background');
    _foregroundPaused = true;
    await _enqueueDisconnect(manuallyPaused: false, abortPendingConnect: true);
  }

  Future<void> resumeFromBackground() async {
    if (_disposed || _manualReconnectPaused || !_foregroundPaused) {
      _log(
        'link',
        'resume skipped: disposed=$_disposed manual=$_manualReconnectPaused '
            'paused=$_foregroundPaused',
      );
      return;
    }
    _log('link', 'resume from background');
    _foregroundPaused = false;
    _disconnectRequested = false;
    _nextGeneration('resume from background');
    _reconnectTimer?.cancel();
    await _startConnect();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _disconnectRequested = true;
    _nextGeneration('dispose');
    _expectedDisconnect = true;
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _commands.dispose();
    _invalidateConfigurationState();
    try {
      await connection.disconnect();
    } on Object catch (error) {
      // Disconnect is best-effort during teardown.
      _log('link', 'dispose: disconnect failed: $error');
    }
    try {
      await _commands.done;
    } on Object catch (error) {
      // Pending callers receive their own command error.
      _log('link', 'dispose: pending command ended with $error');
    }
    try {
      await _disableNotifications(updatePeripheral: false);
    } on Object catch (error) {
      // A torn-down stream may already be closed.
      _log('link', 'dispose: disabling notifications failed: $error');
    }
    try {
      await _connectionSubscription.cancel();
    } on Object catch (error) {
      // Subscription cancellation must not prevent the remaining cleanup.
      _log('link', 'dispose: cancelling the link listener failed: $error');
    }
    try {
      await connection.dispose();
    } on Object catch (error) {
      // The session is locally disposed even if platform teardown fails.
      _log('link', 'dispose: platform dispose failed: $error');
    }
    _state.value = const SessionDisposed();
    _state.dispose();
    _observed.dispose();
    _pending.dispose();
    _versions.dispose();
    _odometerMeters.dispose();
    _speedKmh.dispose();
    _streetLegalLocked.dispose();
  }

  Future<void> _startConnect() {
    final existing = _connectFuture;
    if (_connectFutureGeneration == _generation && existing != null) {
      return existing;
    }
    final generation = _generation;
    final pending = _enqueueConnect();
    _connectFuture = pending;
    _connectFutureGeneration = generation;
    unawaited(
      pending.then<void>(
        (_) {
          if (identical(_connectFuture, pending)) {
            _connectFuture = null;
            _connectFutureGeneration = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_connectFuture, pending)) {
            _connectFuture = null;
            _connectFutureGeneration = null;
          }
        },
      ),
    );
    return pending;
  }

  Future<void> _enqueueConnect() {
    final generation = _generation;
    return _commands.add(() async {
      if (!_isCurrent(generation)) {
        _log('link', 'connect dropped: generation $generation is stale');
        return;
      }
      _expectedDisconnect = false;
      _connectionIntent = _nextConnectionIntent;
      _pollTimer?.cancel();
      _invalidateConfigurationState();
      await _disableNotifications(updatePeripheral: false);
      _versions.value = null;
      _odometerMeters.value = null;
      _state.value = const SessionConnecting();
      try {
        _platformConnectGeneration = generation;
        try {
          await _timed(connection.connect(), 'Connecting');
        } finally {
          if (_platformConnectGeneration == generation) {
            _platformConnectGeneration = null;
          }
        }
        if (!_isCurrent(generation)) {
          _log('link', 'connect stopped after the platform connect: stale');
          return;
        }
        _state.value = const SessionDiscovering();
        await _timed(connection.discoverRequiredGatt(), 'Service discovery');
        if (!_isCurrent(generation)) {
          _log('link', 'connect stopped after discovery: stale');
          return;
        }
        _state.value = const SessionAuthenticating();
        await _authenticate();
        if (!_isCurrent(generation)) {
          _log('link', 'connect stopped after authentication: stale');
          return;
        }
        await _enableNotifications();
        if (!_isCurrent(generation)) {
          _log('link', 'connect stopped after notifications: stale');
          return;
        }
        await _enableAuxiliaryCounter();
        if (!_isCurrent(generation)) {
          _log('link', 'connect stopped after the counter: stale');
          return;
        }
        _state.value = const SessionConnected();
        await _synchronizeNow(initialConnection: true);
        _reconnectAttempt = 0;
        if (readDiagnosticsOnConnect &&
            _isCurrent(generation) &&
            _hasObservedConnection) {
          await _refreshOdometer();
          await _refreshVersions();
        }
        if (_isCurrent(generation) && _hasObservedConnection) {
          try {
            await _protocol.requestRideData();
          } on Object catch (error) {
            // Ride data is optional. A bike that refuses the request still
            // connects, without speed.
            _log('speed', 'ride data request failed: $error');
          }
        }
      } on Object catch (error) {
        if (!_isCurrent(generation)) {
          _log('link', 'connect failed in a stale generation: $error');
          return;
        }
        final failure = _asFailure(error);
        _log('link', 'connect failed: ${_describeFailure(failure)}');
        if (failure case BikeBluetoothUnavailable(canRetry: false)) {
          _clearPendingConfiguration();
          _state.value = SessionFailed(failure: failure, canRetry: false);
        } else if (failure is _ProtocolSessionFailure ||
            failure is BikeAuthenticationFailed ||
            failure is BikeProtocolNotSupported) {
          _clearPendingConfiguration();
          _state.value = SessionFailed(failure: failure, canRetry: true);
        } else {
          _clearPendingConfiguration();
          _scheduleReconnect(failure);
        }
      }
    });
  }

  Future<void> _refreshVersions() async {
    const revisions = [
      BikeGatt.hardwareRevision,
      BikeGatt.firmwareRevision,
      BikeGatt.softwareRevision,
    ];
    if (revisions.any(
      (uuid) => !connection.hasCharacteristic(
        serviceUuid: BikeGatt.deviceInformationService,
        characteristicUuid: uuid,
      ),
    )) {
      return;
    }

    try {
      final hardware = _decodeRevision(
        await _timed(
          connection.readCharacteristic(
            serviceUuid: BikeGatt.deviceInformationService,
            characteristicUuid: BikeGatt.hardwareRevision,
          ),
          'Reading hardware revision',
        ),
      );
      final firmware = _decodeRevision(
        await _timed(
          connection.readCharacteristic(
            serviceUuid: BikeGatt.deviceInformationService,
            characteristicUuid: BikeGatt.firmwareRevision,
          ),
          'Reading firmware revision',
        ),
      );
      final software = _decodeRevision(
        await _timed(
          connection.readCharacteristic(
            serviceUuid: BikeGatt.deviceInformationService,
            characteristicUuid: BikeGatt.softwareRevision,
          ),
          'Reading software revision',
        ),
      );
      final info = BikeProtocol.decodeVersionInfo(
        hardwareRevision: hardware,
        firmwareRevision: firmware,
        softwareRevision: software,
        fcfc: await _protocol.readHistoryRecord(
          BikeGatt.displayVersionSelector,
        ),
        fafa: await _protocol.readHistoryRecord(
          BikeGatt.componentVersionsSelector,
        ),
      );
      _versions.value = info;
      try {
        await _onVersionsRead?.call(info);
      } on Object catch (error) {
        // A cached version write must not prevent the bike becoming ride-ready.
        _log('config', 'saving versions failed: $error');
      }
    } on Object catch (error) {
      // Some bikes omit version data. Keep the last cache and continue setup.
      _log('config', 'reading versions failed: $error');
    }
  }

  Future<void> _refreshOdometer() async {
    try {
      final meters = await _protocol.readOdometer(
        cachedMeters: _odometerMeters.peek(),
      );
      _odometerMeters.value = meters;
      try {
        await _onOdometerRead?.call(meters);
      } on Object catch (error) {
        // A cached odometer write must not prevent the bike becoming ride-ready.
        _log('config', 'saving odometer failed: $error');
      }
    } on Object catch (error) {
      // Missing odometer history is optional metadata, not a connection failure.
      _log('config', 'reading odometer failed: $error');
    }
  }

  String _decodeRevision(List<int> value) {
    return utf8.decode(value).replaceAll('\u0000', '').trim();
  }

  Future<void> _authenticate() async {
    final challenge = await _timed(
      connection.readCharacteristic(
        serviceUuid: BikeGatt.authenticationService,
        characteristicUuid: BikeGatt.authenticationChallenge,
      ),
      'Reading authentication challenge',
    );
    final response = BikeProtocol.authenticationResponse(
      challenge: challenge,
      key: _authenticationKey,
    );
    await _timed(
      connection.writeCharacteristic(
        serviceUuid: BikeGatt.authenticationService,
        characteristicUuid: BikeGatt.authenticationResponse,
        value: response,
      ),
      'Writing authentication response',
    );
    final state = await _timed(
      connection.readCharacteristic(
        serviceUuid: BikeGatt.authenticationService,
        characteristicUuid: BikeGatt.authenticationState,
      ),
      'Verifying authentication',
    );
    _log('auth', 'state bytes=$state');
    if (state.length != 1 || state.single != 1) {
      throw const BikeAuthenticationFailed(
        'The bike rejected the challenge response.',
      );
    }
  }

  Future<void> _enableNotifications() async {
    await _telemetrySubscription?.cancel();
    _telemetrySubscription = connection
        .characteristicNotifications(
          serviceUuid: BikeGatt.metricsService,
          characteristicUuid: BikeGatt.telemetry,
        )
        .listen(_onTelemetry, onError: _onTelemetryError);
    try {
      await _timed(
        connection.setCharacteristicNotifications(
          serviceUuid: BikeGatt.metricsService,
          characteristicUuid: BikeGatt.telemetry,
          enabled: true,
        ),
        'Enabling bike updates',
      );
    } on Object {
      await _telemetrySubscription?.cancel();
      _telemetrySubscription = null;
      rethrow;
    }
  }

  Future<void> _disableNotifications({required bool updatePeripheral}) async {
    await _disableAuxiliaryCounter();
    final subscription = _telemetrySubscription;
    _telemetrySubscription = null;
    if (subscription == null) {
      return;
    }
    if (updatePeripheral) {
      try {
        await _timed(
          connection.setCharacteristicNotifications(
            serviceUuid: BikeGatt.metricsService,
            characteristicUuid: BikeGatt.telemetry,
            enabled: false,
          ),
          'Disabling bike updates',
        );
      } on Object catch (error) {
        // A disconnected peripheral no longer has an active notification
        // subscription to disable.
        _log('link', 'disabling telemetry failed: $error');
      }
    }
    await subscription.cancel();
  }

  void _onTelemetry(List<int> packet) {
    if (_disposed || _disconnectRequested || !_hasObservedConnection) {
      return;
    }
    _offTimeMeter.recordNotification();
    try {
      final speed = _protocol.decodeSpeedKmh(packet);
      if (speed != null) {
        if (_lastSpeedAt == null) {
          _log(
            'speed',
            'first speed sample since the link state reset: $speed km/h',
          );
        }
        _lastSpeedAt = _clock();
        _speedKmh.value = speed;
        return;
      }
      final current = _observed.peek();
      if (current == null) {
        return;
      }
      final updated = _protocol.applyTelemetry(packet, current);
      if (updated == null) {
        return;
      }
      if (updated != current) {
        _log(
          'config',
          'bike changed its configuration: ${_describeConfig(current)} -> '
              '${_describeConfig(updated)}',
        );
      }
      _publishObserved(updated);
    } on BikeProtocolFailure catch (error) {
      // Ignore malformed or unsupported telemetry; the next valid notification
      // remains authoritative.
      _log('config', 'telemetry ignored: $error');
    }
  }

  void _onTelemetryError(Object error, StackTrace stackTrace) {
    if (_disposed) {
      return;
    }
    _log('link', 'telemetry stream error: $error');
    _offTimeMeter.linkLost();
    _reconnectTimer?.cancel();
    _nextGeneration('telemetry stream error');
    _hasObservedConnection = false;
    _pollTimer?.cancel();
    _invalidateConfigurationState();
    unawaited(_disableNotifications(updatePeripheral: false));
    _scheduleReconnect(BikeSessionTransportFailure(error));
  }

  Future<void> _enableAuxiliaryCounter() async {
    await _disableAuxiliaryCounter();
    _counterSampleLogged = false;
    if (!_streetLegalOnQuickRestart ||
        !connection.hasCharacteristic(
          serviceUuid: BikeGatt.auxiliaryService,
          characteristicUuid: BikeGatt.auxiliaryCounter,
        )) {
      return;
    }
    _auxiliarySubscription = connection
        .characteristicNotifications(
          serviceUuid: BikeGatt.auxiliaryService,
          characteristicUuid: BikeGatt.auxiliaryCounter,
        )
        .listen(
          _onAuxiliaryCounter,
          onError: (Object error) {
            _log('meter', 'counter stream error: $error');
          },
        );
    try {
      await _timed(
        connection.setCharacteristicNotifications(
          serviceUuid: BikeGatt.auxiliaryService,
          characteristicUuid: BikeGatt.auxiliaryCounter,
          enabled: true,
        ),
        'Enabling the bike counter',
      );
    } on Object catch (error) {
      _log('meter', 'enabling the counter failed: $error');
      await _disableAuxiliaryCounter();
    }
  }

  Future<void> _stopAuxiliaryCounterOnBike() async {
    if (!connection.hasCharacteristic(
      serviceUuid: BikeGatt.auxiliaryService,
      characteristicUuid: BikeGatt.auxiliaryCounter,
    )) {
      return;
    }
    try {
      await _timed(
        connection.setCharacteristicNotifications(
          serviceUuid: BikeGatt.auxiliaryService,
          characteristicUuid: BikeGatt.auxiliaryCounter,
          enabled: false,
        ),
        'Disabling the bike counter',
      );
    } on Object catch (error) {
      // The link is down or the bike refuses: its notifications end with the
      // link.
      _log('meter', 'disabling the counter on the bike failed: $error');
    }
  }

  Future<void> _disableAuxiliaryCounter() async {
    final cancelled = _auxiliarySubscription?.cancel();
    _auxiliarySubscription = null;
    await cancelled;
  }

  void _onAuxiliaryCounter(List<int> packet) {
    if (_disposed || _disconnectRequested || !_hasObservedConnection) {
      return;
    }
    final counter = BikeProtocol.decodeAuxiliaryCounter(packet);
    if (counter == null) {
      return;
    }
    if (_offTimeMeter.awaitsCounterSample || !_counterSampleLogged) {
      _counterSampleLogged = true;
      _log('meter', 'first counter sample: $counter');
    }
    _offTimeMeter.recordCounter(counter);
    final waiter = _counterSampleWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  /// Waits at most [_counterSampleTimeout] for the first counter sample
  /// after a loss.
  Future<void> _awaitCounterSample() async {
    if (_auxiliarySubscription == null || !_offTimeMeter.awaitsCounterSample) {
      return;
    }
    final waiter = Completer<void>();
    _counterSampleWaiter = waiter;
    var timedOut = false;
    try {
      await waiter.future.timeout(
        _counterSampleTimeout,
        onTimeout: () => timedOut = true,
      );
      _log(
        'meter',
        timedOut
            ? 'no counter sample within ${_counterSampleTimeout.inMilliseconds}'
                  'ms'
            : 'counter sample received',
      );
    } finally {
      _counterSampleWaiter = null;
    }
  }

  /// The marker of the control-history record, or null when two reads gave
  /// no usable record. A short record is a failed read.
  Future<int?> _readSessionMarker() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final record = await _protocol.readProtocolRecord(
          _protocol.controlHistorySelector,
          invalidateRetained: true,
        );
        if (record.length > 5) {
          _log(
            'lock',
            'marker read attempt=${attempt + 1} length=${record.length} '
                'byte5=${record[5]}',
          );
          return record[5];
        }
        _log(
          'lock',
          'marker read attempt=${attempt + 1} too short: '
              'length=${record.length}',
        );
      } on BikeProtocolFailure catch (error) {
        // The next attempt reads the record again.
        _log('lock', 'marker read attempt=${attempt + 1} failed: $error');
      }
    }
    return null;
  }

  int get _writeMarker => _streetLegalLocked.peek()
      ? BikeGatt.sessionLockedMarker
      : BikeGatt.sessionAppliedMarker;

  /// Reads the marker and decides the lock ("Decision at each connect").
  /// Returns the configuration of the first write: the stock mode after a
  /// quick restart, else the observed configuration.
  Future<BikeConfiguration> _decideStreetLegalLock(
    int generation,
    BikeConfiguration observed,
    DateTime readAt,
  ) async {
    final marker = await _readSessionMarker();
    if (marker != BikeGatt.sessionLockedMarker) {
      await _awaitCounterSample();
    }
    if (!_isCurrent(generation) || !_hasObservedConnection) {
      throw const BikeSessionDisposedFailure();
    }
    final gap = _offTimeMeter.takeGap(readAt);
    _lastSessionMarker = marker;
    final gapText = gap == null
        ? 'offTime=unknown'
        : 'offTime=${gap.offTime.inSeconds}s '
              'onTime=${gap.onTime?.inSeconds}s '
              'source=${gap.fromCounter ? 'counter' : 'phone'} '
              'quick=${gap.quickRestart}';
    final wasLocked = _streetLegalLocked.peek();
    if (marker == null) {
      _log(
        'lock',
        'marker=unknown $gapText -> lock keeps its state '
            '(${wasLocked ? 'ON' : 'OFF'}), no mode written',
      );
      // Without a record the off time is unknown, and an unknown off time is
      // not quick. The lock keeps its state from memory: a running lock stays
      // on, and no lock starts.
      _dropoutOnTime = null;
      return observed;
    }
    _dropoutOnTime = marker == BikeGatt.sessionAppliedMarker
        ? gap?.onTime
        : null;
    switch (marker) {
      case BikeGatt.sessionLockedMarker:
        _log('lock', 'marker=2 $gapText -> lock stays ON');
        _streetLegalLocked.value = true;
        return observed;
      case BikeGatt.sessionAppliedMarker:
        _log('lock', 'marker=1 $gapText -> dropout, lock OFF');
        _streetLegalLocked.value = false;
        return observed;
      default:
        // The bike restarted. Only a quick restart starts the lock. An
        // unknown off time is not quick.
        final quick = gap?.quickRestart ?? false;
        _log(
          'lock',
          'marker=$marker $gapText -> '
              '${quick ? (observed.mode == _streetLegalStockMode ? 'lock ON, bike reports stock wire $_streetLegalStockMode' : 'lock ON, write stock wire $_streetLegalStockMode') : 'slow restart, lock OFF'}',
        );
        _streetLegalLocked.value = quick;
        return quick
            ? observed.copyWith(mode: _streetLegalStockMode)
            : observed;
    }
  }

  BikeConfiguration _publishObserved(BikeConfiguration configuration) {
    _observed.value = configuration;
    return configuration;
  }

  Future<void> _synchronizeNow({bool initialConnection = false}) async {
    final generation = _generation;
    _pollTimer?.cancel();
    final observed = await _readConfiguration();
    final readAt = _clock();
    if (!_isCurrent(generation) || !_hasObservedConnection) {
      _log('config', 'synchronize dropped: the link or generation changed');
      throw const BikeSessionDisposedFailure();
    }
    _publishObserved(observed);
    _log(
      'config',
      'synchronize initial=$initialConnection observed '
          '${_describeConfig(observed)}',
    );

    var base = observed;
    if (initialConnection) {
      if (_streetLegalOnQuickRestart) {
        base = await _decideStreetLegalLock(generation, observed, readAt);
      } else {
        _lastSessionMarker = null;
        _dropoutOnTime = null;
      }
      _log(
        'config',
        'first write ${_describeConfig(base)} marker=$_writeMarker '
            'locked=${_streetLegalLocked.peek()}',
      );
      await _protocol.writeConfiguration(base, marker: _writeMarker);
      if (!_isCurrent(generation) || !_hasObservedConnection) {
        _log('config', 'first write done, but the link or generation changed');
        throw const BikeSessionDisposedFailure();
      }
      if (base != observed) {
        _publishObserved(base);
      }
    }

    // During the lock the session writes the light and the assist values,
    // not the set-on-connect mode.
    final intent = _streetLegalLocked.peek()
        ? _connectionIntent.copyWith(mode: null)
        : _connectionIntent;
    if (intent.isEmpty) {
      _log(
        'config',
        'set-on-connect has nothing to write (locked='
            '${_streetLegalLocked.peek()})',
      );
      _markReady(base);
      return;
    }
    final target = intent.applyTo(base);
    if (!initialConnection && intent.matches(base)) {
      _log('config', 'set-on-connect already matches the bike');
      _markReady(base);
      return;
    }
    _state.value = const SessionSynchronizing(attempt: 1);
    _log(
      'config',
      'set-on-connect write ${_describeConfig(target)} '
          'marker=$_writeMarker locked=${_streetLegalLocked.peek()}',
    );
    await _protocol.writeConfiguration(target, marker: _writeMarker);
    if (!_isCurrent(generation) || !_hasObservedConnection) {
      _log('config', 'set-on-connect write done, but the link changed');
      throw const BikeSessionDisposedFailure();
    }
    _publishObserved(target);
    _markReady(target);
  }

  Future<BikeConfiguration> _changeConfiguration(BikeControlPatch controls) {
    _ensureNotDisposed();
    if (!canChangeConfiguration) {
      throw const BikeSessionNotReady();
    }
    final current = _pending.peek() ?? _observed.peek();
    if (current == null) {
      throw const BikeSessionNotReady();
    }
    _pendingControls = _pendingControls?.merge(controls) ?? controls;
    final target = _pendingControls!.applyTo(current);
    final generation = _generation;
    _pending.value = target;
    _state.value = const SessionSynchronizing(attempt: 1);
    final existing = _configurationChangeFuture;
    if (_configurationChangeGeneration == generation && existing != null) {
      return existing;
    }
    final pending = _commands.add(() => _drainConfigurationChanges(generation));
    _configurationChangeFuture = pending;
    _configurationChangeGeneration = generation;
    return pending;
  }

  Future<BikeConfiguration> _drainConfigurationChanges(int generation) async {
    try {
      while (true) {
        if (!_isCurrent(generation) || !_hasObservedConnection) {
          throw const BikeSessionDisposedFailure();
        }
        final current = _observed.peek();
        if (_pending.peek() == null || current == null) {
          throw const BikeSessionNotReady();
        }
        final controls = _pendingControls!;
        final target = controls.applyTo(current);
        _pending.value = target;
        // An explicit control must reach the bike even when telemetry claims
        // the cached state already matches; the controller can lag that cache.
        _pollTimer?.cancel();
        late BikeConfiguration written;
        _log(
          'config',
          'write ${_describeConfig(current)} -> ${_describeConfig(target)} '
              'marker=$_writeMarker',
        );
        try {
          await _protocol.writeConfiguration(target, marker: _writeMarker);
          if (!_isCurrent(generation) || !_hasObservedConnection) {
            throw const BikeSessionDisposedFailure();
          }
          written = _publishObserved(target);
          _log('config', 'write accepted');
        } on Object catch (error) {
          final failure = _asFailure(error);
          _log('config', 'write failed: ${_describeFailure(failure)}');
          _clearPendingConfiguration();
          if (_isConnectionFailure(failure)) {
            _scheduleReconnect(failure);
          } else if (failure is! BikeSessionDisposedFailure) {
            _state.value = SessionFailed(failure: failure, canRetry: true);
          }
          throw failure;
        }

        _clearPendingIf(target);
        if (_pending.peek() != null) {
          continue;
        }
        _markReady(written);
        return written;
      }
    } finally {
      if (_configurationChangeGeneration == generation) {
        _configurationChangeFuture = null;
        _configurationChangeGeneration = null;
      }
    }
  }

  Future<BikeConfiguration> _readConfiguration() async {
    return await _protocol.readConfiguration(
      onOdometer: (meters) => _odometerMeters.value = meters,
    );
  }

  void _markReady(
    BikeConfiguration configuration, {
    BikeConfiguration? completedTarget,
  }) {
    if (_disposed || !_hasObservedConnection) {
      return;
    }
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    if (completedTarget != null) {
      _clearPendingIf(completedTarget);
    }
    if (_pending.peek() != null) {
      _state.value = const SessionSynchronizing(attempt: 1);
      return;
    }
    _state.value = SessionReady(configuration: configuration);
    if (_pollInterval case final interval?) {
      _pollTimer = Timer.periodic(interval, (_) {
        if (!_commands.isBusy && _state.peek() is SessionReady) {
          unawaited(
            _pollConfiguration().catchError((Object error) {
              _log('config', 'poll ended with $error');
            }),
          );
        }
      });
    }
  }

  Future<void> _pollConfiguration() {
    final generation = _generation;
    return _commands.add(() async {
      if (!_isCurrent(generation) ||
          !_hasObservedConnection ||
          _state.peek() is! SessionReady) {
        return;
      }
      try {
        final confirmed = await _readConfiguration();
        if (!_isCurrent(generation) || !_hasObservedConnection) {
          return;
        }
        final published = _publishObserved(confirmed);
        _state.value = SessionReady(configuration: published);
      } on Object catch (error) {
        if (!_isCurrent(generation)) {
          return;
        }
        final failure = _asFailure(error);
        _log('config', 'poll failed: ${_describeFailure(failure)}');
        if (_isConnectionFailure(failure)) {
          _scheduleReconnect(failure);
        } else if (failure is! BikeSessionDisposedFailure) {
          _state.value = SessionFailed(failure: failure, canRetry: true);
        }
      }
    });
  }

  void _clearPendingIf(BikeConfiguration target) {
    if (_pending.peek() == target) {
      _clearPendingConfiguration();
    }
  }

  void _clearPendingConfiguration() {
    _pending.value = null;
    _pendingControls = null;
  }

  Future<void> _enqueueDisconnect({
    required bool manuallyPaused,
    required bool abortPendingConnect,
  }) async {
    final previousGeneration = _generation;
    final hadPendingConnect =
        abortPendingConnect && _platformConnectGeneration == previousGeneration;
    _disconnectRequested = true;
    _nextGeneration(
      manuallyPaused ? 'manual disconnect' : 'pause for background',
    );
    final disconnectGeneration = _generation;
    _expectedDisconnect = true;
    // A deliberate disconnect is no bike restart: the next connect has an
    // unknown off time.
    _offTimeMeter.clear(
      manuallyPaused ? 'manual disconnect' : 'background pause',
    );
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    _invalidateConfigurationState();
    if (hadPendingConnect) {
      try {
        await connection.disconnect();
      } on Object catch (error) {
        // Disconnecting is also the cancellation mechanism for a platform
        // connection attempt, so this is best-effort.
        _log('link', 'abort of the pending connect failed: $error');
      }
    }
    return await _commands.add(() async {
      if (!_isCurrent(disconnectGeneration) || !_disconnectRequested) {
        return;
      }
      await _disconnectNow(manuallyPaused: manuallyPaused);
    });
  }

  Future<void> _disconnectNow({
    required bool manuallyPaused,
    bool disconnectPeripheral = true,
  }) async {
    _hasObservedConnection = false;
    _invalidateConfigurationState();
    await _disableNotifications(updatePeripheral: true);
    if (disconnectPeripheral) {
      try {
        await _timed(connection.disconnect(), 'Disconnecting');
      } on Object catch (error) {
        // The local session is still paused even if the platform already lost
        // the link before it could acknowledge the disconnect.
        _log('link', 'platform disconnect failed: $error');
      }
    }
    if (!_disposed) {
      _state.value = SessionDisconnected(manuallyPaused: manuallyPaused);
    }
  }

  void _onConnectionState(BikeConnectionState connectionState) {
    if (_disposed) {
      return;
    }
    _log('link', 'platform link state: ${connectionState.name}');
    if (connectionState == BikeConnectionState.connected) {
      _hasObservedConnection = true;
      return;
    }
    if (!_hasObservedConnection) {
      _log('link', 'platform state ignored: no observed connection');
      return;
    }
    _hasObservedConnection = false;
    _invalidateConfigurationState();
    if (_expectedDisconnect ||
        _manualReconnectPaused ||
        _foregroundPaused ||
        _state.peek() is SessionIdle) {
      _log(
        'link',
        'link loss ignored: expected=$_expectedDisconnect '
            'manual=$_manualReconnectPaused paused=$_foregroundPaused '
            'idle=${_state.peek() is SessionIdle}',
      );
      return;
    }
    _log('link', 'unexpected loss');
    // Only an unexpected loss can be a bike restart.
    _offTimeMeter.linkLost();
    _reconnectTimer?.cancel();
    _nextGeneration('link loss');
    _pollTimer?.cancel();
    unawaited(_disableNotifications(updatePeripheral: false));
    _scheduleReconnect(
      const BikeSessionTransportFailure('The bike disconnected.'),
    );
  }

  void _scheduleReconnect(BikeSessionFailure failure) {
    if (_disposed || _manualReconnectPaused || _foregroundPaused) {
      _log(
        'link',
        'reconnect skipped: disposed=$_disposed manual=$_manualReconnectPaused '
            'paused=$_foregroundPaused',
      );
      return;
    }
    if (_reconnectTimer?.isActive ?? false) {
      _log('link', 'reconnect skipped: a timer runs');
      return;
    }
    _invalidateConfigurationState();
    if (_reconnectDelays.isEmpty) {
      _log('link', 'reconnect skipped: no delays, session fails');
      _state.value = SessionFailed(failure: failure, canRetry: true);
      return;
    }
    final delayIndex = _reconnectAttempt < _reconnectDelays.length
        ? _reconnectAttempt
        : _reconnectDelays.length - 1;
    final delay = _reconnectDelays[delayIndex];
    _reconnectAttempt++;
    _state.value = SessionReconnecting(
      attempt: _reconnectAttempt,
      retryAfter: delay,
      failure: failure,
    );
    final generation = _generation;
    _log(
      'link',
      'reconnect attempt=$_reconnectAttempt delay=${delay.inMilliseconds}ms',
    );
    _reconnectTimer = Timer(delay, () {
      if (_isCurrent(generation) &&
          !_manualReconnectPaused &&
          !_foregroundPaused) {
        _log('link', 'reconnect timer fired');
        unawaited(_startConnect());
      } else {
        _log(
          'link',
          'reconnect timer dropped: current=${_isCurrent(generation)} '
              'manual=$_manualReconnectPaused paused=$_foregroundPaused',
        );
      }
    });
  }

  Future<T> _timed<T>(Future<T> operation, String name) async {
    try {
      return await operation.timeout(_commandTimeout);
    } on TimeoutException {
      throw BikeCommandTimedOut(name);
    }
  }

  BikeSessionFailure _asFailure(Object error) {
    return switch (error) {
      final BikeSessionFailure failure => failure,
      final BikeAdapterUnavailable failure => BikeBluetoothUnavailable(
        failure.message,
        canRetry: failure.canRetry,
      ),
      final BikeGattNotSupported failure => BikeProtocolNotSupported(
        failure.message,
      ),
      final BikeProtocolFailure failure => _ProtocolSessionFailure(failure),
      _ => BikeSessionTransportFailure(error),
    };
  }

  bool _isConnectionFailure(BikeSessionFailure failure) {
    return failure is BikeSessionTransportFailure ||
        failure is BikeCommandTimedOut ||
        failure is BikeBluetoothUnavailable && failure.canRetry;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _log(String area, String message) {
    _debugLog.log(area, message, generation: _generation);
  }

  /// Starts a new generation. Every lines of the log carry the generation.
  void _nextGeneration(String reason) {
    _generation++;
    _log('link', 'generation $_generation: $reason');
  }

  /// Logs each state change once: `old -> new`.
  void _logStateChanges() {
    String? previous;
    _state.subscribe((value) {
      final text = describeState(value);
      if (previous != null && previous != text) {
        _log('link', '$previous -> $text');
      }
      previous = text;
    });
  }

  static String describeState(BikeSessionState state) {
    return switch (state) {
      SessionIdle() => 'Idle',
      SessionConnecting() => 'Connecting',
      SessionDiscovering() => 'Discovering',
      SessionConnected() => 'Connected',
      SessionAuthenticating() => 'Authenticating',
      SessionSynchronizing(:final attempt) => 'Synchronizing($attempt)',
      SessionReady(:final configuration) =>
        'Ready(mode=${configuration.mode} light=${configuration.light} '
            'assist=${configuration.assist})',
      SessionReconnecting(:final attempt, :final retryAfter, :final failure) =>
        'Reconnecting(attempt=$attempt retryAfter=${retryAfter.inMilliseconds}'
            'ms failure=${_describeFailure(failure)})',
      SessionDisconnected(:final manuallyPaused) =>
        'Disconnected(manuallyPaused=$manuallyPaused)',
      SessionFailed(:final failure, :final canRetry) =>
        'Failed(canRetry=$canRetry failure=${_describeFailure(failure)})',
      SessionDisposed() => 'Disposed',
    };
  }

  static String _describeConfig(BikeConfiguration configuration) {
    return 'mode=${configuration.mode} light=${configuration.light} '
        'assist=${configuration.assist}';
  }

  static String _describeFailure(Object failure) {
    final platform = switch (failure) {
      BikeSessionTransportFailure(cause: BikeConnectionFailure(:final cause)) =>
        cause,
      _ => null,
    };
    final detail = platform == null ? '' : ' platform=$platform';
    return '${failure.runtimeType}: '
        '${failure is BikeSessionFailure ? failure.message : failure}$detail';
  }

  void _invalidateConfigurationState() {
    _clearPendingConfiguration();
    _observed.value = null;
    _speedKmh.value = null;
    _lastSpeedAt = null;
    _protocol.reset();
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw const BikeSessionDisposedFailure();
    }
  }
}

final class _ProtocolSessionFailure extends BikeSessionFailure {
  const new(BikeProtocolFailure failure)
    : super('The bike returned invalid data: $failure');
}

final class _SerialCommandQueue {
  Future<void> _tail = Future.value();
  var _pending = 0;
  var _disposed = false;

  bool get isBusy => _pending > 0;
  Future<void> get done => _tail;

  Future<T> add<T>(Future<T> Function() command) {
    if (_disposed) {
      return Future.error(const BikeSessionDisposedFailure());
    }
    final previous = _tail;
    final released = Completer<void>();
    final result = Completer<T>();
    _tail = released.future;
    _pending++;

    unawaited(() async {
      try {
        await previous;
        if (_disposed) {
          throw const BikeSessionDisposedFailure();
        }
        result.complete(await command());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        _pending--;
        released.complete();
      }
    }());
    return result.future;
  }

  void dispose() {
    _disposed = true;
  }
}

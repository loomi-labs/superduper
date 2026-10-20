import 'dart:async';

import 'package:signals/signals.dart';
import 'package:superduper/src/ble/bike_identity_resolver.dart';
import 'package:superduper/src/ble/bike_session.dart';
import 'package:superduper/src/ble/ride_mode_controller.dart';
import 'package:superduper/src/diagnostics/debug_log.dart';
import 'package:superduper/src/domain/bike.dart';
import 'package:superduper/src/platform/background_hold.dart';
import 'package:superduper/src/platform/bluetooth_permissions.dart';
import 'package:superduper/src/repositories/bike_repository.dart';
import 'package:superduper/src/repositories/settings_repository.dart';

sealed class ActiveBikeState {
  const new();
}

final class ActiveBikeLoading extends ActiveBikeState {
  const new();
}

final class NoActiveBike extends ActiveBikeState {
  const new();
}

final class ActiveBikePermissionRequired extends ActiveBikeState {
  const new({required this.permission});

  final BluetoothPermissionState permission;
}

final class ActiveBikeSessionStatus extends ActiveBikeState {
  const new({
    required this.bike,
    required this.session,
    required this.sessionState,
    required this.isTemporary,
    required this.rideMode,
  });

  final SavedBike bike;
  final BikeSession session;
  final RideModeController rideMode;
  final BikeSessionState sessionState;
  final bool isTemporary;
}

final class ActiveBikeCoordinatorFailure extends ActiveBikeState {
  const new(this.error);

  final Object error;
}

typedef BikeSessionBuilder = BikeSession Function(SavedBike bike);

typedef RideModeBuilder = RideModeController Function(
  BikeSession session,
  SavedBike bike,
);

final class ActiveBikeDiscoveryPause {
  new _(this._coordinator);

  ActiveBikeCoordinator? _coordinator;

  Future<void> release({SavedBike? temporarilySelect}) async {
    final coordinator = _coordinator;
    if (coordinator == null) {
      return;
    }
    _coordinator = null;
    await coordinator._releaseDiscoveryPause(
      this,
      temporarilySelect: temporarilySelect,
    );
  }

  void _detach() {
    _coordinator = null;
  }
}

final class _CoordinatorInputs {
  const new({this.bikes, this.settings});

  final List<SavedBike>? bikes;
  final AppPreferences? settings;

  bool get isReady => bikes != null && settings != null;
}

final class ActiveBikeCoordinator {
  new({
    required this.bikeRepository,
    required this.settingsRepository,
    required this.permissions,
    required this.buildSession,
    this.identityResolver,
    RideModeBuilder? rideModeBuilder,
    this.backgroundHold = const NoopBackgroundHoldGateway(),
    this.debugLogFor = noDebugLogFor,
    this.onBikesChanged,
    this.onBikeForgotten,
    this.onLinkHeldChanged,
    bool startsHeadless = false,
  }) : _headless = startsHeadless,
       _foreground = !startsHeadless,
       _rideModeBuilder =
           rideModeBuilder ??
           ((session, bike) => RideModeController(
             session: session,
             bike: bike,
             debugLog: debugLogFor(bike.bike.deviceId),
           ));

  final BikeRepository bikeRepository;
  final SettingsRepository settingsRepository;
  final BluetoothPermissionGateway permissions;
  final BikeSessionBuilder buildSession;
  final BikeIdentityResolver? identityResolver;
  final BackgroundHoldGateway backgroundHold;
  final DebugLogFor debugLogFor;

  /// Called with the saved bikes at each change. The debug log store reads
  /// the debug log preference from it.
  final void Function(List<SavedBike> bikes)? onBikesChanged;

  /// Called when the rider forgets a bike. The debug log deletes its files.
  final void Function(String deviceId)? onBikeForgotten;

  /// Called when the hold changes. The native background sync stands down
  /// while the hold is on.
  final void Function({required bool held})? onLinkHeldChanged;
  bool? _linkHeldSent;
  final RideModeBuilder _rideModeBuilder;
  final Signal<ActiveBikeState> _state = signal(
    const ActiveBikeLoading(),
    options: const SignalOptions(name: 'activeBike.state'),
  );
  final Signal<List<SavedBike>> _bikes = signal(
    const [],
    options: const SignalOptions(name: 'activeBike.bikes'),
  );
  final Signal<String?> _activeBikeId = signal(
    null,
    options: const SignalOptions(name: 'activeBike.activeId'),
  );
  final Signal<bool> _migrationNoticePending = signal(
    false,
    options: const SignalOptions(name: 'activeBike.migrationNoticePending'),
  );
  final Completer<void> _disposeSignal = Completer<void>();

  StreamSubscription<List<SavedBike>>? _bikesSubscription;
  StreamSubscription<AppPreferences>? _settingsSubscription;
  EffectCleanup? _sessionStateCleanup;
  Future<BluetoothPermissionState>? _permissionCheck;
  Future<void>? _reconcileFuture;
  _CoordinatorInputs _inputs = const _CoordinatorInputs();
  BikeSession? _session;
  RideModeController? _rideMode;
  EffectCleanup? _holdCleanup;
  SavedBike? _currentBike;
  String? _temporaryBikeId;
  final Set<String> _forgettingBikeIds = {};
  var _reconcileRequested = false;
  var _reconcileForce = false;
  var _reconcileMayRequestPermission = false;
  var _switchGeneration = 0;
  var _started = false;
  var _disposed = false;
  ActiveBikeDiscoveryPause? _discoveryPause;
  bool _foreground;

  /// True from a start without a screen until the first `resumed`. The
  /// coordinator then builds the session in the background and never asks for
  /// the Bluetooth permission.
  bool _headless;
  var _suppressHoldPause = false;
  var _readyRecorded = false;

  bool get _discoveryPaused => _discoveryPause != null;

  bool get _mayBuildSession => _foreground || _headless;

  ReadonlySignal<ActiveBikeState> get state => _state.readonly();
  ReadonlySignal<List<SavedBike>> get bikes => _bikes.readonly();
  ReadonlySignal<String?> get activeBikeId => _activeBikeId.readonly();
  ReadonlySignal<bool> get migrationNoticePending =>
      _migrationNoticePending.readonly();

  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    final bikesReady = Completer<void>();
    final settingsReady = Completer<void>();
    var initialized = false;
    _bikesSubscription = bikeRepository.watchBikes().listen(
      (bikes) {
        if (_disposed) {
          return;
        }
        _acceptBikes(bikes);
        onBikesChanged?.call(bikes);
        if (!bikesReady.isCompleted) {
          bikesReady.complete();
        }
        if (initialized) {
          _scheduleReconcile();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _onStreamError(error, stackTrace);
        if (!bikesReady.isCompleted) {
          bikesReady.completeError(error, stackTrace);
        }
      },
    );
    _settingsSubscription = settingsRepository.watch().listen(
      (settings) {
        if (_disposed) {
          return;
        }
        _acceptSettings(settings);
        if (!settingsReady.isCompleted) {
          settingsReady.complete();
        }
        if (initialized) {
          _scheduleReconcile();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _onStreamError(error, stackTrace);
        if (!settingsReady.isCompleted) {
          settingsReady.completeError(error, stackTrace);
        }
      },
    );
    await Future.any([
      Future.wait([bikesReady.future, settingsReady.future]),
      _disposeSignal.future,
    ]);
    if (_disposed) {
      return;
    }
    initialized = true;
    final targetId = _activeBikeId.peek();
    final hasTarget =
        targetId != null &&
        _bikes.peek().any((saved) => saved.bike.deviceId == targetId);
    if (!hasTarget) {
      _state.value = const NoActiveBike();
    }
    _scheduleReconcile();
  }

  Future<void> selectTemporarily(String deviceId) async {
    if (!_bikes.peek().any((saved) => saved.bike.deviceId == deviceId)) {
      _acceptBikes(await bikeRepository.getBikes());
      if (_disposed) {
        return;
      }
    }
    _requireSavedBike(deviceId);
    if (_temporaryBikeId == deviceId && _session?.deviceId == deviceId) {
      return;
    }
    _temporaryBikeId = deviceId;
    await _reconcile(force: true);
  }

  Future<void> returnToActiveBike() async {
    if (_temporaryBikeId == null) {
      return;
    }
    _temporaryBikeId = null;
    await _reconcile(force: true);
  }

  Future<void> makeBikeActive(String deviceId) async {
    await settingsRepository.makeBikeActive(deviceId);
    if (_disposed) {
      return;
    }
    _acceptSettings(await settingsRepository.get());
    if (_disposed) {
      return;
    }
    _temporaryBikeId = null;
    await _reconcile(force: _session?.deviceId != deviceId);
  }

  Future<void> forgetBike(String deviceId) async {
    if (_disposed || !_forgettingBikeIds.add(deviceId)) {
      return;
    }
    try {
      _switchGeneration++;
      _acceptBikes(
        _bikes
            .peek()
            .where((saved) => saved.bike.deviceId != deviceId)
            .toList(),
      );
      if (_temporaryBikeId == deviceId) {
        _temporaryBikeId = null;
      }
      if (_session?.deviceId == deviceId) {
        await _clearSession();
      }
      await bikeRepository.forgetBike(deviceId);
      onBikeForgotten?.call(deviceId);
      if (_disposed) {
        return;
      }
      _acceptBikes(await bikeRepository.getBikes());
      if (_disposed) {
        return;
      }
      _acceptSettings(await settingsRepository.get());
      if (_disposed) {
        return;
      }
      await _reconcile();
    } finally {
      _forgettingBikeIds.remove(deviceId);
    }
  }

  Future<void> retry() async {
    final current = _session;
    if (current != null) {
      if (current.state.peek() case SessionReady() || SessionSynchronizing()) {
        return;
      }
      await current.retry();
      return;
    }
    await _reconcile(force: true);
  }

  Future<void> disconnectManually() async {
    await _session?.disconnect();
  }

  Future<void> dismissMigrationNotice() {
    return settingsRepository.dismissMigrationNotice();
  }

  Future<ActiveBikeDiscoveryPause?> acquireDiscoveryPause() async {
    if (_disposed || _discoveryPause != null) {
      return null;
    }
    final pause = ActiveBikeDiscoveryPause._(this);
    _discoveryPause = pause;
    _switchGeneration++;
    try {
      await _clearSession();
      return pause;
    } on Object {
      if (identical(_discoveryPause, pause)) {
        _discoveryPause = null;
      }
      pause._detach();
      rethrow;
    }
  }

  Future<void> _releaseDiscoveryPause(
    ActiveBikeDiscoveryPause pause, {
    SavedBike? temporarilySelect,
  }) async {
    if (!identical(_discoveryPause, pause)) {
      return;
    }
    try {
      if (temporarilySelect != null) {
        _acceptBikes(await bikeRepository.getBikes());
        if (_disposed) {
          return;
        }
        _temporaryBikeId = temporarilySelect.bike.deviceId;
      }
    } finally {
      if (identical(_discoveryPause, pause)) {
        _discoveryPause = null;
      }
    }
    if (_mayBuildSession) {
      await _reconcile(force: true);
    }
  }

  Future<void> setForeground(bool foreground) async {
    var headlessEnded = false;
    if (foreground && _headless) {
      _headless = false;
      headlessEnded = true;
      _log('headless start ends: the app is in the foreground');
    }
    final changed = _foreground != foreground;
    _foreground = foreground;
    // The app reports hidden, paused and detached one after the other. Only a
    // change gets log lines.
    await _applyForeground(
      foreground,
      log: changed,
      requestPermission: headlessEnded,
    );
  }

  Future<void> _applyForeground(
    bool foreground, {
    required bool log,
    bool requestPermission = false,
  }) async {
    void note(String message, [String area = 'app']) {
      if (log) {
        _log(message, area);
      }
    }

    if (_discoveryPaused) {
      note('setForeground($foreground): ignored, discovery pause is active');
      return;
    }
    if (foreground) {
      final current = _session;
      if (current == null) {
        note('setForeground(true): no session, reconcile');
        await _reconcile(force: true, requestPermission: requestPermission);
      } else {
        note('setForeground(true): resume the session');
        await current.resumeFromBackground();
      }
    } else {
      if (_rideMode?.needsBackgroundHold.peek() ?? false) {
        note(
          'setForeground(false): hold wanted, speedLimit='
          '${_rideMode?.holdsSpeedLimit.peek()}, session stays connected',
        );
        // A service that did not start keeps the process at risk.
        await backgroundHold
            .setHeld(
              true,
              speedLimit: _rideMode?.holdsSpeedLimit.peek() ?? true,
              log: _holdLog,
            )
            .catchError((Object error) {
              note('setForeground(false): hold start failed: $error', 'hold');
            });
        return;
      }
      note('setForeground(false): no hold, pause the session');
      await _session?.pauseForBackground();
    }
  }

  void _onHoldChanged(bool held, {required bool speedLimit}) {
    _log('hold changed: held=$held speedLimit=$speedLimit', 'hold');
    _sendLinkHeld(held);
    unawaited(
      backgroundHold
          .setHeld(held, speedLimit: speedLimit, log: _holdLog)
          .catchError((Object error) {
            _log('hold gateway failed: $error', 'hold');
          }),
    );
    // Without the hold Android stops the process at an unknown time. An
    // orderly pause matches the behaviour without a dynamic mode.
    if (!held && !_foreground && !_discoveryPaused && !_suppressHoldPause) {
      _log('hold ended in the background: pause the session', 'hold');
      unawaited(_session?.pauseForBackground());
    }
  }

  void _sendLinkHeld(bool held) {
    if (_linkHeldSent == held) {
      return;
    }
    _linkHeldSent = held;
    onLinkHeldChanged?.call(held: held);
  }

  /// The hold gateway logs to the bike of the session only.
  DebugLog get _holdLog {
    final id = _session?.deviceId ?? _currentBike?.bike.deviceId;
    return id == null ? const NoopDebugLog() : debugLogFor(id);
  }

  void _log(String message, [String area = 'app']) {
    final id =
        _session?.deviceId ??
        _currentBike?.bike.deviceId ??
        _inputs.settings?.activeBikeId;
    if (id == null) {
      return;
    }
    debugLogFor(id).log(area, message, generation: _session?.generation);
  }

  /// The CDM event says the bike is in range. A session that waits for its
  /// reconnect timer connects at once. The event changes nothing else: a
  /// paused or manually disconnected session stays as it is.
  void onBikeAppeared(String deviceId) {
    final session = _session;
    if (session == null ||
        session.deviceId.toUpperCase() != deviceId.toUpperCase()) {
      _log('bike appeared ignored: other device', 'link');
      return;
    }
    // The session logs the event or the reason it ignores it.
    session.reconnectNow('the bike appeared (CDM)');
  }

  Future<bool> openPermissionSettings() => permissions.openSettings();

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _discoveryPause?._detach();
    _discoveryPause = null;
    if (!_disposeSignal.isCompleted) {
      _disposeSignal.complete();
    }
    _switchGeneration++;
    await _bikesSubscription?.cancel();
    await _settingsSubscription?.cancel();
    await _clearSession();
    _state.dispose();
    _bikes.dispose();
    _activeBikeId.dispose();
    _migrationNoticePending.dispose();
  }

  Future<void> _reconcile({bool force = false, bool requestPermission = true}) {
    if (_disposed) {
      return Future.value();
    }
    _reconcileRequested = true;
    _reconcileForce = _reconcileForce || force;
    _reconcileMayRequestPermission =
        _reconcileMayRequestPermission || requestPermission;
    if (_reconcileFuture case final pending?) {
      return pending;
    }

    late final Future<void> pending;
    pending = _drainReconciliation();
    _reconcileFuture = pending;
    unawaited(
      pending.whenComplete(() {
        if (identical(_reconcileFuture, pending)) {
          _reconcileFuture = null;
        }
      }),
    );
    return pending;
  }

  Future<void> _drainReconciliation() async {
    while (_reconcileRequested && !_disposed) {
      final force = _reconcileForce;
      final requestPermission = _reconcileMayRequestPermission;
      _reconcileRequested = false;
      _reconcileForce = false;
      _reconcileMayRequestPermission = false;
      await _recomputeOnce(force: force, requestPermission: requestPermission);
    }
  }

  Future<void> _recomputeOnce({
    bool force = false,
    bool requestPermission = true,
  }) async {
    final inputs = _inputs;
    if (_disposed || !inputs.isReady || _discoveryPaused || !_mayBuildSession) {
      return;
    }
    try {
      final targetId = _temporaryBikeId ?? inputs.settings!.activeBikeId;
      if (targetId == null) {
        await _clearSession();
        if (!_disposed) {
          _state.value = const NoActiveBike();
        }
        return;
      }
      final target = inputs.bikes!.where(
        (saved) => saved.bike.deviceId == targetId,
      );
      if (target.isEmpty) {
        await _clearSession();
        if (!_disposed) {
          _state.value = const NoActiveBike();
        }
        return;
      }
      final bike = target.single;
      final current = _session;
      if (!force &&
          current?.deviceId == targetId &&
          current?.protocolVersion == bike.bike.protocol) {
        _log(
          'in-place update of the session: streetLegal='
          '${bike.streetLegalOnQuickRestart} setOnConnect=${bike.setOnConnect}',
        );
        _currentBike = bike;
        current!
          ..updateSetOnConnect(resolveSetOnConnect(bike).patch)
          ..updateStreetLegalOnQuickRestart(
            bike.streetLegalOnQuickRestart,
            stockMode: resolveStockMode(bike),
          );
        _rideMode?.updateBike(bike);
        if (!_disposed &&
            !_discoveryPaused &&
            _session == current &&
            _currentBike?.bike.deviceId == bike.bike.deviceId) {
          _publishSessionState(current.state.peek());
        }
        return;
      }

      final generation = ++_switchGeneration;
      await _clearSession();
      if (_disposed ||
          _discoveryPaused ||
          !_mayBuildSession ||
          generation != _switchGeneration) {
        return;
      }
      final permission = await _ensurePermission(
        request: requestPermission && !_headless,
      );
      if (_disposed ||
          _discoveryPaused ||
          !_mayBuildSession ||
          generation != _switchGeneration) {
        return;
      }
      if (permission != BluetoothPermissionState.granted) {
        if (_headless) {
          _log('headless start: no permission');
        }
        _state.value = ActiveBikePermissionRequired(permission: permission);
        return;
      }
      _state.value = const ActiveBikeLoading();

      var preparedBike = bike;
      if (bike.bike.moduleSerial == null && identityResolver != null) {
        try {
          preparedBike = await identityResolver!.resolve(bike);
        } on Object catch (error) {
          // Advertisement metadata improves background behavior but must not
          // prevent the normal foreground connection.
          _log('identity resolve failed: $error');
        }
      }
      if (_disposed ||
          _discoveryPaused ||
          !_mayBuildSession ||
          generation != _switchGeneration) {
        return;
      }
      if (_headless) {
        _log('headless start: build the session in the background');
      }
      final next = buildSession(preparedBike);
      if (_disposed ||
          _discoveryPaused ||
          !_mayBuildSession ||
          generation != _switchGeneration) {
        debugLogFor(preparedBike.bike.deviceId).log(
          'app',
          'session built but stale: disposed=$_disposed '
              'discoveryPaused=$_discoveryPaused foreground=$_foreground '
              'switch=$generation/$_switchGeneration',
        );
        await next.dispose();
        return;
      }
      _readyRecorded = false;
      _currentBike = preparedBike;
      _session = next;
      final rideMode = _rideModeBuilder(next, preparedBike);
      _rideMode = rideMode;
      _log(
        'session built for ${preparedBike.bike.deviceId} '
        'protocol=${preparedBike.bike.protocol.name} '
        'region=${preparedBike.bike.region?.name} '
        'temporary=${_temporaryBikeId != null}',
      );
      final hold = computed(
        () => (
          held: rideMode.needsBackgroundHold.value,
          speedLimit: rideMode.holdsSpeedLimit.value,
        ),
      );
      // The first call of the subscription runs before the connect. A headless
      // start applies the background rule after the connect call.
      _suppressHoldPause = true;
      final stopHold = hold.subscribe(
        (value) => _onHoldChanged(value.held, speedLimit: value.speedLimit),
      );
      _suppressHoldPause = false;
      _holdCleanup = () {
        stopHold();
        hold.dispose();
      };
      _sessionStateCleanup = next.state.subscribe((sessionState) {
        if (!_disposed && _session == next) {
          _publishSessionState(sessionState);
        }
      });
      if (_headless && !rideMode.needsBackgroundHold.peek()) {
        // No hold: the session pauses at once and connects at the first
        // foreground. A connect now would only race with the pause.
        await _applyForeground(false, log: true);
        return;
      }
      unawaited(
        next.connect().catchError((Object error) {
          _log('connect failed: $error');
          if (!_disposed && _session == next) {
            _state.value = ActiveBikeCoordinatorFailure(error);
          }
        }),
      );
      if (_headless) {
        // The first value of the hold subscription started the hold already.
        _log('headless start: hold wanted, the session stays connected');
      }
    } on Object catch (error) {
      _log('reconcile failed: $error');
      if (!_disposed && !_discoveryPaused && _mayBuildSession) {
        _state.value = ActiveBikeCoordinatorFailure(error);
      }
    }
  }

  Future<BluetoothPermissionState> _ensurePermission({
    required bool request,
  }) async {
    final existing = _permissionCheck;
    if (existing != null) {
      return await existing;
    }
    late final Future<BluetoothPermissionState> pending;
    pending = permissions.ensureAccess(request: request);
    _permissionCheck = pending;
    try {
      return await pending;
    } finally {
      if (identical(_permissionCheck, pending)) {
        _permissionCheck = null;
      }
    }
  }

  Future<void> _clearSession() async {
    if (_session != null) {
      _log('session cleared');
    }
    _sessionStateCleanup?.call();
    _sessionStateCleanup = null;
    _holdCleanup?.call();
    _holdCleanup = null;
    _rideMode?.dispose();
    _rideMode = null;
    _sendLinkHeld(false);
    await backgroundHold.setHeld(false, log: _holdLog).catchError((
      Object error,
    ) {
      _log('hold release failed: $error', 'hold');
    });
    final old = _session;
    _session = null;
    _currentBike = null;
    _readyRecorded = false;
    if (!_disposed) {
      _state.value = const ActiveBikeLoading();
    }
    if (old != null) {
      await old.dispose();
    }
  }

  void _publishSessionState(BikeSessionState sessionState) {
    final bike = _currentBike;
    final session = _session;
    final rideMode = _rideMode;
    if (bike == null || session == null || rideMode == null) {
      return;
    }
    _state.value = ActiveBikeSessionStatus(
      bike: bike,
      session: session,
      sessionState: sessionState,
      isTemporary: _temporaryBikeId != null,
      rideMode: rideMode,
    );
    if (sessionState is SessionReady && !_readyRecorded) {
      _readyRecorded = true;
      unawaited(
        bikeRepository.markConnected(bike.bike.deviceId).catchError((
          Object error,
        ) {
          _log('markConnected failed: $error');
        }),
      );
    }
  }

  SavedBike _requireSavedBike(String deviceId) {
    final bike = _bikes.peek().where(
      (saved) => saved.bike.deviceId == deviceId,
    );
    if (bike.isEmpty) {
      throw BikeNotFoundException(deviceId);
    }
    return bike.single;
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    if (!_disposed) {
      _state.value = ActiveBikeCoordinatorFailure(error);
    }
  }

  void _acceptBikes(List<SavedBike> bikes) {
    final immutable = List<SavedBike>.unmodifiable(
      bikes.where((saved) => !_forgettingBikeIds.contains(saved.bike.deviceId)),
    );
    _inputs = _CoordinatorInputs(bikes: immutable, settings: _inputs.settings);
    _bikes.value = immutable;
  }

  void _acceptSettings(AppPreferences settings) {
    _inputs = _CoordinatorInputs(bikes: _inputs.bikes, settings: settings);
    _activeBikeId.value = settings.activeBikeId;
    if (_temporaryBikeId == settings.activeBikeId) {
      _temporaryBikeId = null;
    }
    _migrationNoticePending.value = settings.migrationNoticePending;
  }

  void _scheduleReconcile() {
    unawaited(_reconcile().catchError((Object _, StackTrace _) {}));
  }
}

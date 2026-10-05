import 'dart:async';

import 'package:signals/signals.dart';
import 'package:superduper/src/ble/bike_protocol.dart';
import 'package:superduper/src/ble/bike_session.dart';
import 'package:superduper/src/domain/bike.dart';
import 'package:superduper/src/domain/ride_modes.dart';

/// Runs the ride mode of one session: it keeps the selected mode, writes the
/// base or cap wire of a custom mode as the speed crosses its limit, and says
/// when the link must stay alive in the background.
final class RideModeController {
  new({
    required this.session,
    required this._bike,
    DateTime Function()? clock,
    this.speedTimeout = const Duration(seconds: 5),
    this.parkedTimeout = const Duration(minutes: 10),
    Duration watchdogInterval = const Duration(seconds: 1),
  }) : _clock = clock ?? DateTime.now {
    _stateCleanup = session.state.subscribe(_onState);
    _observedCleanup = session.observed.subscribe(_onObserved);
    _speedCleanup = session.speedKmh.subscribe(_onSpeed);
    _lockCleanup = session.streetLegalLocked.subscribe(_onStreetLegalLocked);
    _watchdog = Timer.periodic(watchdogInterval, (_) {
      _checkSpeedStream();
      _checkParked();
    });
  }

  final BikeSession session;
  final Duration speedTimeout;
  final Duration parkedTimeout;
  final DateTime Function() _clock;
  final Signal<RideModeSelection?> _selection = signal(
    null,
    options: const SignalOptions(name: 'rideMode.selection'),
  );
  final Signal<int?> _parkedMinutesLeft = signal(
    null,
    options: const SignalOptions(name: 'rideMode.parkedMinutesLeft'),
  );
  final Signal<bool> _needsBackgroundHold = signal(
    false,
    options: const SignalOptions(name: 'rideMode.hold'),
  );
  final Signal<bool> _holdsSpeedLimit = signal(
    false,
    options: const SignalOptions(name: 'rideMode.holdsSpeedLimit'),
  );
  late final EffectCleanup _stateCleanup;
  late final EffectCleanup _observedCleanup;
  late final EffectCleanup _speedCleanup;
  late final EffectCleanup _lockCleanup;
  late final Timer _watchdog;
  SavedBike _bike;
  int? _assertedWire;
  DateTime? _lastRideDataRequestAt;
  // While a select write is in flight, the hold follows the previous
  // selection: the new mode is not on the bike yet.
  var _selectInFlight = false;
  RideModeSelection? _holdSelection;
  // The parked fallback timer. It runs from _parkedSince on a settled link.
  // A dropout pauses it and keeps the elapsed time in _parkedPaused.
  DateTime? _parkedSince;
  Duration? _parkedPaused;
  var _parkedWriteInFlight = false;
  Future<void>? _parkedWrite;
  var _linkSettled = false;
  var _disposed = false;

  ReadonlySignal<RideModeSelection?> get selection => _selection.readonly();
  ReadonlySignal<bool> get needsBackgroundHold =>
      _needsBackgroundHold.readonly();
  int? get assertedWire => _assertedWire;

  /// True while the hold keeps a switching custom mode. False while the hold
  /// comes only from the street-legal preference.
  ReadonlySignal<bool> get holdsSpeedLimit => _holdsSpeedLimit.readonly();

  /// The minutes until the parked fallback writes the stock mode, rounded
  /// up. Null while the timer does not run.
  ReadonlySignal<int?> get parkedMinutesLeft => _parkedMinutesLeft.readonly();
  BikeRegion? get _region => _bike.bike.region;

  /// The selection the hold follows until the bike confirms one: the
  /// set-on-connect custom mode, so a rider who leaves the app during the
  /// first connection keeps the speed check.
  RideModeSelection? get _savedSelection =>
      switch (resolveSetOnConnect(_bike).rideMode) {
        final mode? => CustomRideMode(mode),
        null => null,
      };

  // The parked fallback needs speed samples. A V2 bike sends none, so the
  // timer runs on V1 bikes only.
  bool get _parkedApplies {
    if (!_bike.streetLegalOnQuickRestart ||
        _bike.bike.protocol != BikeProtocolVersion.v1 ||
        session.streetLegalLocked.peek()) {
      return false;
    }
    final current = _selection.peek();
    return current != null &&
        current != NativeRideMode(resolveStockMode(_bike));
  }

  bool get _ready => switch (session.state.peek()) {
    SessionReady() || SessionSynchronizing() => session.canChangeConfiguration,
    _ => false,
  };

  /// Selects a mode. The state changes only when the bike accepts the write;
  /// on an error the previous selection comes back.
  Future<void> select(RideModeSelection next) async {
    if (_disposed) {
      return;
    }
    // A parked write that runs now finishes first: the rider's choice comes
    // after it and ends the lock that it starts.
    await _parkedWrite;
    if (_disposed) {
      return;
    }
    final wire = initialWireFor(next, _region);
    final previousSelection = _selection.peek();
    final previousWire = _assertedWire;
    final previousLock = session.streetLegalLocked.peek();
    // A mode choice ends the lock. Its write carries marker 1.
    session.endStreetLegalLock();
    _selectInFlight = true;
    _holdSelection = previousSelection;
    _selection.value = next;
    _assertedWire = wire;
    try {
      await session.setMode(wire);
      // A mode choice restarts the parked fallback timer.
      _parkedSince = null;
      _parkedPaused = null;
    } on Object {
      if (!_disposed) {
        _selection.value = previousSelection;
        _assertedWire = previousWire;
        session.restoreStreetLegalLock(previousLock);
      }
      rethrow;
    } finally {
      _selectInFlight = false;
      _holdSelection = null;
      // The hold changes only when the bike runs the new mode. A hold that
      // ends in the background pauses the session, which must not happen
      // during this write.
      _publishHold();
      _updateParkedTimer();
    }
  }

  void updateBike(SavedBike bike) {
    _bike = bike;
    if (_selection.peek() case CustomRideMode(:final mode)) {
      final stillThere = bike.customModes
          .where((candidate) => candidate.id == mode.id)
          .firstOrNull;
      if (stillThere == null) {
        final observed = session.observed.peek()?.mode;
        _selection.value = observed == null ? null : NativeRideMode(observed);
        _assertedWire = observed;
      } else if (stillThere != mode) {
        _selection.value = CustomRideMode(stillThere);
        _assertedWire = entryWireFor(stillThere, _region);
        if (_ready) {
          unawaited(
            session
                .setMode(_assertedWire!)
                .catchError((Object _) => session.observed.peek()!),
          );
        }
      }
    }
    _publishHold();
    _updateParkedTimer();
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _watchdog.cancel();
    _stateCleanup();
    _observedCleanup();
    _speedCleanup();
    _lockCleanup();
    _needsBackgroundHold.value = false;
    _holdsSpeedLimit.value = false;
    _selection.dispose();
    _needsBackgroundHold.dispose();
    _holdsSpeedLimit.dispose();
    _parkedMinutesLeft.dispose();
  }

  void _onState(BikeSessionState state) {
    if (_disposed) {
      return;
    }
    final wasSettled = _linkSettled;
    _linkSettled = switch (state) {
      SessionReady() => true,
      SessionSynchronizing() => _linkSettled,
      _ => false,
    };
    if (state is SessionReady && !wasSettled) {
      _onBecameReady();
    }
    _publishHold();
    _updateParkedTimer();
  }

  /// The lock leaves the bike on the wire it reports: no custom mode runs.
  void _onStreetLegalLocked(bool locked) {
    if (_disposed) {
      return;
    }
    if (locked && _ready) {
      final observed = session.observed.peek()?.mode;
      if (observed != null) {
        _selection.value = NativeRideMode(observed);
        _assertedWire = observed;
      }
    }
    _updateParkedTimer();
    _publishHold();
  }

  /// Decides the selection for a fresh connection. A write on a settled link
  /// does not call it.
  void _onBecameReady() {
    _continueParkedTimer();
    final observed = session.observed.peek()?.mode;
    if (observed == null) {
      return;
    }
    if (session.streetLegalLocked.peek()) {
      _selection.value = NativeRideMode(observed);
      _assertedWire = observed;
      return;
    }
    final current = _selection.peek();
    if (current is CustomRideMode && assertsWire(current, observed, _region)) {
      _assertedWire = observed;
      return;
    }
    final resolved = resolveSetOnConnect(_bike);
    if (resolved.rideMode case final mode?
        when assertsWire(CustomRideMode(mode), observed, _region)) {
      _selection.value = CustomRideMode(mode);
      _assertedWire = observed;
      return;
    }
    _selection.value = NativeRideMode(observed);
    _assertedWire = observed;
  }

  /// Follows the rider: a wire the selected mode never asserts ends the mode.
  void _onObserved(BikeConfiguration? observed) {
    if (_disposed || observed == null) {
      return;
    }
    // During a connection the session publishes the wire it reads before the
    // set-on-connect write. That wire is not a rider choice.
    if (!_linkSettled) {
      return;
    }
    final current = _selection.peek();
    if (current == null) {
      return;
    }
    if (!assertsWire(current, observed.mode, _region)) {
      _selection.value = NativeRideMode(observed.mode);
      _assertedWire = observed.mode;
      _publishHold();
      _updateParkedTimer();
    }
  }

  void _onSpeed(double? speedKmh) {
    if (_disposed || speedKmh == null) {
      return;
    }
    if (speedKmh > 0 && _parkedSince != null) {
      _parkedSince = _clock();
      _publishParked();
    }
    if (!_ready || _parkedWriteInFlight) {
      return;
    }
    final current = _selection.peek();
    if (current is! CustomRideMode || !isDynamicSelection(current, _region)) {
      return;
    }
    final asserted = _assertedWire ?? initialWireFor(current, _region);
    final next = dynamicWireFor(current.mode, speedKmh, asserted, _region);
    if (next == asserted) {
      return;
    }
    _writeWire(next, previous: asserted);
  }

  /// Without speed samples a mode with an unlimited base must go back on its
  /// cap, and the bike must be asked to stream again.
  void _checkSpeedStream() {
    if (_disposed || _parkedWriteInFlight) {
      return;
    }
    if (!_ready) {
      return;
    }
    final current = _selection.peek();
    final switching =
        current is CustomRideMode && isDynamicSelection(current, _region);
    // The bike stops its ride data at a standstill. The parked timer needs
    // the samples of a ride, in any mode.
    if (!switching && _parkedSince == null) {
      return;
    }
    final last = session.lastSpeedAt;
    final now = _clock();
    if (last != null && now.difference(last) < speedTimeout) {
      return;
    }
    if (switching) {
      final capped = unwatchedWireFor(current.mode, _region);
      if (capped != null && capped != _assertedWire) {
        _writeWire(capped, previous: _assertedWire ?? capped);
      }
    }
    final lastRequest = _lastRideDataRequestAt;
    if (lastRequest == null || now.difference(lastRequest) >= speedTimeout) {
      _lastRideDataRequestAt = now;
      unawaited(session.requestRideData().catchError((Object _) {}));
    }
  }

  void _writeWire(int wire, {required int previous}) {
    _assertedWire = wire;
    unawaited(
      session.setMode(wire).catchError((Object _) {
        if (_assertedWire == wire) {
          _assertedWire = previous;
        }
        return session.observed.peek() ??
            const BikeConfiguration(light: false, mode: 0, assist: 0);
      }),
    );
  }

  void _updateParkedTimer() {
    if (_disposed) {
      return;
    }
    if (!_parkedApplies) {
      _parkedSince = null;
      _parkedPaused = null;
    } else if (_linkSettled) {
      _parkedSince ??= _clock().subtract(_parkedPaused ?? Duration.zero);
      _parkedPaused = null;
    } else if (_parkedSince case final since?) {
      // A dropout pauses the timer.
      _parkedPaused = _clock().difference(since);
      _parkedSince = null;
    }
    _publishParked();
  }

  /// After a dropout (marker 1) the timer continues, and the bike on time
  /// of the dropout counts as parked time. After a restart it starts again.
  void _continueParkedTimer() {
    final paused = _parkedPaused;
    if (paused == null) {
      return;
    }
    _parkedPaused = session.lastSessionMarker == BikeGatt.sessionAppliedMarker
        ? paused + (session.dropoutOnTime ?? Duration.zero)
        : null;
  }

  void _checkParked() {
    final since = _parkedSince;
    if (_disposed || since == null || _parkedWriteInFlight || _selectInFlight) {
      return;
    }
    _publishParked();
    if (_clock().difference(since) >= parkedTimeout) {
      unawaited(_onParkedExpired());
    }
  }

  Future<void> _onParkedExpired() {
    // The speed check stops first, so no custom wire follows the stock mode.
    _parkedWriteInFlight = true;
    final write = _writeParkedLock();
    _parkedWrite = write;
    return write;
  }

  Future<void> _writeParkedLock() async {
    try {
      await session.startStreetLegalLock();
    } on Object {
      // The lock starts only when the bike accepted the stock mode. The timer
      // stays expired, so the next tick on a settled link tries again.
    } finally {
      _parkedWriteInFlight = false;
      _parkedWrite = null;
    }
  }

  void _publishParked() {
    if (_disposed) {
      return;
    }
    final since = _parkedSince;
    if (since == null) {
      _parkedMinutesLeft.value = null;
      return;
    }
    final left = parkedTimeout - _clock().difference(since);
    _parkedMinutesLeft.value = left <= Duration.zero
        ? 0
        : (left.inSeconds + 59) ~/ 60;
  }

  void _publishHold() {
    if (_disposed) {
      return;
    }
    final current =
        (_selectInFlight ? _holdSelection : _selection.peek()) ??
        _savedSelection;
    final dynamic = current != null && isDynamicSelection(current, _region);
    final linkWanted = switch (session.state.peek()) {
      SessionDisconnected(manuallyPaused: true) ||
      SessionFailed(canRetry: false) ||
      SessionDisposed() => false,
      _ => true,
    };
    // The street-legal preference needs the link to see the next restart,
    // in any ride mode.
    _needsBackgroundHold.value =
        (dynamic || _bike.streetLegalOnQuickRestart) && linkWanted;
    _holdsSpeedLimit.value = dynamic && linkWanted;
  }
}

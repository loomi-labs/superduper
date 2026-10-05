import 'dart:async';

import 'package:signals/signals.dart';
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
    Duration watchdogInterval = const Duration(seconds: 1),
  }) : _clock = clock ?? DateTime.now {
    _stateCleanup = session.state.subscribe(_onState);
    _observedCleanup = session.observed.subscribe(_onObserved);
    _speedCleanup = session.speedKmh.subscribe(_onSpeed);
    _watchdog = Timer.periodic(watchdogInterval, (_) => _checkSpeedStream());
  }

  final BikeSession session;
  final Duration speedTimeout;
  final DateTime Function() _clock;
  final Signal<RideModeSelection?> _selection = signal(
    null,
    options: const SignalOptions(name: 'rideMode.selection'),
  );
  final Signal<bool> _needsBackgroundHold = signal(
    false,
    options: const SignalOptions(name: 'rideMode.hold'),
  );
  late final EffectCleanup _stateCleanup;
  late final EffectCleanup _observedCleanup;
  late final EffectCleanup _speedCleanup;
  late final Timer _watchdog;
  SavedBike _bike;
  int? _assertedWire;
  DateTime? _lastRideDataRequestAt;
  // While a select write is in flight, the hold follows the previous
  // selection: the new mode is not on the bike yet.
  var _selectInFlight = false;
  RideModeSelection? _holdSelection;
  var _wasReady = false;
  var _linkSettled = false;
  var _disposed = false;

  ReadonlySignal<RideModeSelection?> get selection => _selection.readonly();
  ReadonlySignal<bool> get needsBackgroundHold =>
      _needsBackgroundHold.readonly();
  int? get assertedWire => _assertedWire;
  BikeRegion? get _region => _bike.bike.region;

  /// The selection the hold follows until the bike confirms one: the
  /// set-on-connect custom mode, so a rider who leaves the app during the
  /// first connection keeps the speed check.
  RideModeSelection? get _savedSelection =>
      switch (resolveSetOnConnect(_bike).rideMode) {
        final mode? => CustomRideMode(mode),
        null => null,
      };

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
    final wire = initialWireFor(next, _region);
    final previousSelection = _selection.peek();
    final previousWire = _assertedWire;
    _selectInFlight = true;
    _holdSelection = previousSelection;
    _selection.value = next;
    _assertedWire = wire;
    try {
      await session.setMode(wire);
    } on Object {
      if (!_disposed) {
        _selection.value = previousSelection;
        _assertedWire = previousWire;
      }
      rethrow;
    } finally {
      _selectInFlight = false;
      _holdSelection = null;
      // The hold changes only when the bike runs the new mode. A hold that
      // ends in the background pauses the session, which must not happen
      // during this write.
      _publishHold();
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
    _needsBackgroundHold.value = false;
    _selection.dispose();
    _needsBackgroundHold.dispose();
  }

  void _onState(BikeSessionState state) {
    if (_disposed) {
      return;
    }
    _linkSettled = switch (state) {
      SessionReady() => true,
      SessionSynchronizing() => _linkSettled,
      _ => false,
    };
    final ready = state is SessionReady;
    if (ready && !_wasReady) {
      _onBecameReady();
    }
    _wasReady = ready;
    _publishHold();
  }

  /// Decides the selection for a fresh connection.
  void _onBecameReady() {
    final observed = session.observed.peek()?.mode;
    if (observed == null) {
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
    }
  }

  void _onSpeed(double? speedKmh) {
    if (_disposed || speedKmh == null || !_ready) {
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
    if (_disposed) {
      return;
    }
    if (!_ready) {
      return;
    }
    final current = _selection.peek();
    if (current is! CustomRideMode || !isDynamicSelection(current, _region)) {
      return;
    }
    final last = session.lastSpeedAt;
    final now = _clock();
    if (last != null && now.difference(last) < speedTimeout) {
      return;
    }
    final capped = unwatchedWireFor(current.mode, _region);
    if (capped != null && capped != _assertedWire) {
      _writeWire(capped, previous: _assertedWire ?? capped);
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
    _needsBackgroundHold.value = dynamic && linkWanted;
  }
}

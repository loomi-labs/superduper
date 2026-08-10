import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;
import 'package:permission_handler/permission_handler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:superduper/colors.dart';
import 'package:superduper/db.dart';
import 'package:superduper/edit_bike.dart' as edit;
import 'package:superduper/models.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/theme.dart';
import 'package:superduper/utils/logger.dart';
import 'package:superduper/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

export 'package:superduper/models.dart';

part 'bike.g.dart';

/// The rider-owned fields of a settings packet. A caller of [Bike.writeStateData]
/// is authoritative for the ones it just changed itself; the rest are taken from
/// the bike, which the rider can change on the handlebar at any time.
enum PacketField { light, assist }

/// The fixed-interval speed line for the ride log, or null when there is
/// nothing honest to write.
///
/// Fed from the 5 s poll rather than from every sample: speed arrives roughly
/// once a second, which is a line per second against the rotating file's cap.
/// A sample older than [maxAge] is dropped instead of repeated — the bike stops
/// streaming ride data at a standstill, so repeating the last value would
/// record a parked bike as still moving.
String? speedTraceLine({
  required double? speedKmh,
  required Duration? sampleAge,
  required Duration maxAge,
  required int wire,
}) =>
    (speedKmh == null || sampleAge == null || sampleAge > maxAge)
        ? null
        : 'Speed $speedKmh km/h, wire $wire';

@riverpod
class Bike extends _$Bike {
  /// A speed stream quieter than this is assumed to have died: the bike stops
  /// streaming ride data on its own, and after every reconnect.
  static const _speedTimeout = Duration(seconds: 5);

  /// Grace period after a (re)connect before the notifier touches the register.
  /// The transport requests ride data itself as part of becoming ready, and that
  /// request selects a different register than a state read does — see
  /// [_withRegister].
  static const _connectSettle = Duration(seconds: 1);

  Timer? _updateDebounce;
  Timer? _updateTimer;

  /// Fires the ride-log trace and the speed-stream watchdog. Deliberately not
  /// [_updateTimer]: every write resets that one through [_resetDebounce], so
  /// during a switching storm it never fires — and the storm is exactly what
  /// the trace must record. Only [build] and dispose touch this timer.
  Timer? _traceTimer;

  @visibleForTesting
  Timer? get debugTraceTimer => _traceTimer;

  bool _writing = false;

  /// The wire mode byte the app currently asserts on the bike.
  ///
  /// For a switching custom mode the phone is the speed limiter, so this is the
  /// only source of truth for which half of the mode's profile pair the bike is
  /// supposed to be in — the read-back cannot tell a mode from a wire any more.
  /// Set from [initialWireFor] in [build], and kept in step by every write.
  late int _assertedWire;

  /// When the last speed sample arrived, for the staleness watchdog.
  DateTime? _lastSpeedAt;

  /// The last speed the bike reported, in km/h, for the ride log's trace.
  double? _lastSpeedKmh;

  /// Last known contents of the bike's settings register: updated from every
  /// valid settings read and from every successful write (the bike echoes a
  /// write into the register). Fallback when a compose read fails.
  ({bool light, int assist})? _lastKnown;

  /// Whether the one-off work of entering a speed-switching mode has been done
  /// for the mode that is active now, so rebuilds and repeated writes do not
  /// re-run it (and do not ask for the notification permission again).
  bool _dynamicActive = false;

  /// Holds this provider alive while the control loop has to keep running
  /// without a mounted UI. Riverpod drops keepAlive links on every rebuild, so
  /// this is re-acquired from [build].
  KeepAliveLink? _keepAlive;

  StreamSubscription<double>? _speedSub;

  /// Set once the bike was deleted from the app. This notifier can outlive its
  /// record (see [deleteStateData]), and a single late write or save would
  /// bring the bike back.
  bool _deleted = false;

  /// Tail of the queue of register accesses this notifier has started. Reading
  /// state and requesting ride data both mean "select a register, then use it",
  /// on one shared characteristic: interleaved, a state read comes back with
  /// ride data, which the poll would then write to the bike as settings.
  Future<void> _registerQueue = Future<void>.value();

  /// Settings writes queued but not yet completed. A poll read that returns
  /// while this is non-zero predates the write behind it, so its wire byte
  /// says nothing the verdict may act on.
  int _pendingWrites = 0;

  /// Every line this notifier writes carries the device id: it is the join key
  /// against the `[Bluetooth]` lines, which log the same id, and it is the only
  /// way to tell two bikes apart in one session. Through helpers rather than at
  /// each call site so a new line cannot forget it.
  void _logD(String message) => log.d(SDLogger.bike, '[$id] $message');
  void _logI(String message) => log.i(SDLogger.bike, '[$id] $message');
  void _logW(String message) => log.w(SDLogger.bike, '[$id] $message');
  void _logE(String message, [Object? error, StackTrace? stackTrace]) =>
      log.e(SDLogger.bike, '[$id] $message', error, stackTrace);

  @override
  BikeState build(String id) {
    ref.onDispose(() {
      _updateTimer?.cancel();
      _updateDebounce?.cancel();
      _traceTimer?.cancel();
      _traceTimer = null;
      _speedSub?.cancel();
      _speedSub = null;
      // The link itself is already released by riverpod here (both on rebuild
      // and on dispose); only drop the stale handle.
      _keepAlive = null;
    });
    _resetReadTimer();
    _traceTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!ref.mounted) {
        return;
      }
      _checkSpeedStream();
      logSpeedTrace();
    });
    var bike = ref.read(bikesDBProvider.notifier).getBike(id) ??
        BikeState.defaultState(id);
    // Deliberately listen instead of watch: a watch would invalidate this
    // notifier on every connection state change, and with no UI listening
    // riverpod skips the rebuild and disposes the provider instead — killing
    // the speed limiter on the first BLE dropout after BikePage is popped. A
    // listen subscription still keeps the transport alive.
    ref.listen(connectionHandlerProvider(id), _onConnectionState);
    // Speed is taken straight off the handler's broadcast stream rather than
    // through bikeSpeedProvider (which the UI uses): riverpod pauses a
    // StreamProvider as soon as nothing actively listens to it, and a provider
    // that is only kept alive does not count. Going through it would silently
    // stop the limiter the moment BikePage is popped.
    _speedSub = ref
        .read(connectionHandlerProvider(id).notifier)
        .speedStream
        .listen(_onSpeedSample);
    // Derived from the restored selection rather than started at a constant:
    // a bike that comes back from bikes.json on a mode whose base profile is
    // not [chWireLow] would otherwise have every write until the first speed
    // sample assert a wire that mode never rides.
    _assertedWire = initialWireFor(bike.selectedMode);
    _syncKeepAlive(bike);
    if (bike.needsSpeedSwitching) {
      // A switching mode is usually already active on the first build: it is
      // the default mode of a CH bike and it comes back from bikes.json that
      // way. Its setup must not depend on a transition through writeStateData.
      _enterSwitchingMode();
    }
    return bike;
  }

  void _onConnectionState(
      SDBluetoothConnectionState? previous, SDBluetoothConnectionState next) {
    if (previous == next || next != SDBluetoothConnectionState.connected) {
      return;
    }
    if (_deleted) {
      return;
    }
    // Re-take the speed stream from the handler as it is now: a subscription
    // made before the dropout may belong to a controller that is gone, which
    // would leave a switching mode blind for the rest of the session.
    _speedSub?.cancel();
    _speedSub = ref
        .read(connectionHandlerProvider(id).notifier)
        .speedStream
        .listen(_onSpeedSample);
    // The bike may have power-cycled into its own default mode, so re-assert
    // ours. Every mode needs this, not just a switching one: without it a
    // reconnected bike keeps whatever it came up with until the next poll, and
    // that poll does not force, so a difference the read cannot see (a wire
    // byte that maps back to the same mode) is never corrected at all. Done
    // here rather than on BikePage, so it also happens while no UI is mounted.
    unawaited(_reassertAfterReconnect());
  }

  bool get _isConnected =>
      ref.read(connectionHandlerProvider(id)) ==
      SDBluetoothConnectionState.connected;

  /// Runs [action] after every register access this notifier has already
  /// started, so a select-then-use sequence is never cut in half by another one.
  Future<T> _withRegister<T>(Future<T> Function() action) {
    final previous = _registerQueue;
    final done = Completer<void>();
    _registerQueue = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  /// Asks the bike to (re)start streaming ride data, without overlapping a
  /// state read.
  Future<void> _requestRideData() => _withRegister(
      () => ref.read(connectionHandlerProvider(id).notifier).requestRideData());

  Future<void> _reassertAfterReconnect() async {
    // Let the transport's own connect-time ride data request finish first: it
    // leaves a different register selected than a read expects.
    await Future<void>.delayed(_connectSettle);
    if (!ref.mounted || !_isConnected) {
      return;
    }
    _logD('Reconnected, re-asserting state');
    await updateStateDataNow(force: true);
  }

  /// Rides a switching custom mode: its base profile below its limit, its cap
  /// profile above. Writes only when the limit is crossed, never per sample.
  void _onSpeedSample(double speedKmh) {
    _lastSpeedAt = DateTime.now();
    // Before every gate: the ride log traces a bike that never switches too.
    _lastSpeedKmh = speedKmh;
    if (!state.needsSpeedSwitching) {
      return;
    }
    // A sample can still be delivered right after a disconnect, so gate on the
    // connection as it is now instead of trusting the sample.
    if (!_isConnected) {
      return;
    }
    final selected = state.selectedMode;
    if (selected is! CustomSelection) {
      // Unreachable: only a custom mode ever needs speed switching.
      return;
    }
    var newWire = dynamicWireFor(selected.mode, speedKmh, _assertedWire);
    if (newWire == _assertedWire) {
      return;
    }
    _logD(
        '${selected.name} at $speedKmh km/h: wire $_assertedWire -> $newWire');
    _assertedWire = newWire;
    // Same settings, new wire byte: writeStateData takes it from _assertedWire.
    // Nothing here is the rider's doing, so light and assist come off the bike.
    // Dropped if the rider changes mode before it reaches the queue's head:
    // this snapshot would otherwise put the mode they left back.
    writeStateData(state, authoritative: const {}, abortIfStale: true);
  }

  /// Delivers one speed sample synchronously, so a test can interleave a switch
  /// decision with a write that already sits in the register queue.
  @visibleForTesting
  void debugHandleSpeedSample(double speedKmh) => _onSpeedSample(speedKmh);

  /// The bike stops streaming ride data on its own; without speed samples a
  /// switching mode is blind, so re-arm the stream when it dries up.
  void _checkSpeedStream() {
    if (!state.needsSpeedSwitching || !_isConnected) {
      return;
    }
    var last = _lastSpeedAt;
    if (last != null && DateTime.now().difference(last) < _speedTimeout) {
      return;
    }
    _logD('No speed samples, requesting ride data again');
    unawaited(_requestRideData());
  }

  /// Writes one speed line per tick of [_traceTimer], so a ride leaves a
  /// continuous trace instead of only the moments a switching mode crossed its
  /// limit.
  ///
  /// Shares [_speedTimeout] with [_checkSpeedStream]: the trace goes quiet on
  /// exactly the tick the watchdog decides the stream died, so it can never
  /// claim a speed the watchdog is already treating as gone.
  @visibleForTesting
  void logSpeedTrace() {
    if (!_isConnected) {
      return;
    }
    var last = _lastSpeedAt;
    var line = speedTraceLine(
        speedKmh: _lastSpeedKmh,
        sampleAge: last == null ? null : DateTime.now().difference(last),
        maxAge: _speedTimeout,
        wire: _assertedWire);
    if (line == null) {
      return;
    }
    _logD(line);
  }

  /// A switching mode and the Background Lock both need the control loop to
  /// keep running when the UI is gone.
  void _syncKeepAlive(BikeState bike) {
    var needed = bike.modeLock || bike.needsSpeedSwitching;
    if (needed == (_keepAlive != null)) {
      return;
    }
    if (needed) {
      _logD('Keeping alive without UI');
      _keepAlive = ref.keepAlive();
    } else {
      _logD('Releasing');
      _keepAlive?.close();
      _keepAlive = null;
    }
  }

  void _resetReadTimer() {
    if (_updateTimer?.isActive ?? false) {
      _updateTimer?.cancel();
    }
    _updateTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!ref.mounted) {
        return;
      }
      if (_writing) {
        return;
      }
      if (!_isConnected) {
        return;
      }
      // Straight to the read: updateStateData's 2 s debounce belongs to user
      // writes and to the post-write echo read, not to the idle poll. Through
      // the debounce the effective poll period was 7 s, not the 5 s the
      // interval promises. _withRegister still serializes this behind any
      // write in flight.
      unawaited(updateStateDataNow());
    });
  }

  void _resetDebounce() {
    if (_updateDebounce?.isActive ?? false) _updateDebounce?.cancel();
    _resetReadTimer();
  }

  Future<void> updateStateData({bool force = false}) async {
    if (_deleted) {
      return;
    }
    var status = ref.read(connectionHandlerProvider(state.id));
    if (status != SDBluetoothConnectionState.connected) {
      return;
    }
    _resetDebounce();
    _writing = false;
    _updateDebounce = Timer(const Duration(seconds: 2), () async {
      _resetReadTimer();
      await updateStateDataNow();
    });
  }

  Future<void> updateStateDataNow({bool force = false}) async {
    if (_deleted) {
      return;
    }
    var data = await _withRegister(
        () => ref.read(connectionHandlerProvider(state.id).notifier).read());
    if (data == null) {
      return;
    }
    if (!isSettingsPacket(data)) {
      // Not the settings register: a ride data frame from a read that raced a
      // register selection, or a truncated answer. Using it would parse speed
      // bytes as settings and write them back to the bike.
      _logW('Ignoring non settings read: $data');
      return;
    }
    // Bike truth, before any lock override turns it into app desire.
    _lastKnown = (light: data[4] == 1, assist: data[2]);
    if (_pendingWrites > 0) {
      // This read predates a settings write that waits in the queue. Judging
      // its wire byte would heal against the past — the ride log shows the
      // same packet written twice after ~10 % of switches. The next poll
      // judges fresh data.
      _logD('Skipping state update, a write is pending');
      return;
    }
    var newState = state.updateFromData(data);
    // Judged on [newState], not on [state]: for a legacy bike without a region
    // this read is what guesses one, and the guess moves the selection into
    // that region's bank. Asking with the old, bankless selection would call
    // the bike's own EU wire foreign and heal it back into the US bank. For
    // every bike that already has a region the two are the same question.
    final verdict = wireVerdict(
        region: newState.region,
        selected: newState.selectedMode,
        reportedWire: data[5],
        assertedWire: _assertedWire);
    var heal = false;
    switch (verdict) {
      case WireInSync():
        break;
      case WireFollow(:final modeId):
        // A locked mode is the one thing that does not follow: the rider asked
        // the app to hold this mode against anything that moves it.
        if (state.pinMode == PinState.locked) {
          heal = true;
        } else {
          newState = newState.withSelectedMode(modeId);
        }
      case WireHeal():
        heal = true;
    }
    if (heal) {
      _logD(
          'Bike is on wire ${data[5]}, re-asserting ${state.selectedMode.name}');
    }
    if (newState == state && !force && !heal) {
      return;
    }
    _logD('State update from data: $data');
    if (state.pinLight == PinState.locked && state.light != newState.light) {
      newState = newState.copyWith(light: state.light);
    }

    if (state.pinAssist == PinState.locked && state.assist != newState.assist) {
      newState = newState.copyWith(assist: state.assist);
    }
    writeStateData(newState);
  }

  /// Whether [field] has to come off the bike rather than out of the app: the
  /// caller did not set it, and no lock pins the app's value over bike truth.
  bool _needsBikeTruth(
      PacketField field, BikeState bike, Set<PacketField> authoritative) {
    if (authoritative.contains(field)) {
      return false;
    }
    // Only a locked pin holds a value against the bike. A startup pin acts on
    // one moment, so between those moments it follows the bike like an open
    // one.
    final pin = field == PacketField.light ? bike.pinLight : bike.pinAssist;
    return pin != PinState.locked;
  }

  /// Rider-owned packet fields, per the priority in [writeStateData].
  ({bool light, int assist}) _composePacket(BikeState bike,
      Set<PacketField> authoritative, ({bool light, int assist})? fresh) {
    final known = fresh ?? _lastKnown;
    return (
      light: _needsBikeTruth(PacketField.light, bike, authoritative)
          ? (known?.light ?? bike.light)
          : bike.light,
      assist: _needsBikeTruth(PacketField.assist, bike, authoritative)
          ? (known?.assist ?? bike.assist)
          : bike.assist,
    );
  }

  /// Writes [newState] to the bike and saves it.
  ///
  /// The caller is [authoritative] only for the fields it changed itself. Every
  /// other rider-owned field is composed, in this order: the app value if the
  /// field is locked, a fresh read taken in the same register slot as the write,
  /// [_lastKnown], and finally the app value. Without this a machine write (a
  /// speed transition) or a one-field user toggle puts a stale copy of the other
  /// field back on the bike, undoing what the rider did on the handlebar.
  void writeStateData(BikeState newState,
      {saveToBike = true,
      bool abortIfStale = false,
      Set<PacketField> authoritative = const {
        PacketField.light,
        PacketField.assist
      }}) async {
    if (_deleted) {
      // The record is gone; saving would put it back into bikes.json.
      return;
    }
    // A machine write carries a snapshot of the state it was composed from. If
    // the rider changes mode while it sits in the register queue, it would land
    // last and put the snapshot — the mode they just left — back into state and
    // into bikes.json, and the app owns the mode, so nothing would ever heal
    // it. Dropping the write instead costs at most one transition, which the
    // next sample or the poll's heal re-asserts.
    final stale = abortIfStale ? state : null;
    _resetDebounce();
    if (state.id != newState.id) {
      throw Exception('Bike id mismatch');
    }
    final oldSel = state.selectedMode;
    final newSel = newState.selectedMode;
    // Identity only: renaming the mode the bike is riding is not a mode change,
    // and must neither reset the wire (lifting the cap mid-ride) nor re-run the
    // one-off setup, which asks for the notification permission again.
    final modeChanged = oldSel.id != newSel.id;
    final wasSwitching = state.needsSpeedSwitching;
    final nowSwitching = newState.needsSpeedSwitching;
    // Evaluated at the queue head, not here: a speed transition can change
    // [_assertedWire] while this write waits behind other register work, and
    // the packet must carry the wire the app intends at the moment it goes on
    // the wire — see the 2026-08-08 ride log, 20:12:29. A wire the selection
    // never asserts is normalised exactly as [wireVerdict] normalises it, so
    // a heal write can never contradict the verdict that asked for it.
    int computeWire() => wireForWrite(
        sel: newSel,
        modeChanged: modeChanged,
        nowSwitching: nowSwitching,
        assertedWire: _assertedWire);
    var wire = computeWire();
    if (wasSwitching && !nowSwitching && state.modeLockAuto) {
      // Only the lock a switching mode turned on is turned off again.
      newState = newState.copyWith(modeLock: false, modeLockAuto: false);
    }
    var status = ref.read(connectionHandlerProvider(state.id));
    if (saveToBike) {
      if (status != SDBluetoothConnectionState.connected) {
        return;
      }
      _writing = true;
      final repo = ref.read(connectionHandlerProvider(state.id).notifier);
      // Skipped when every field resolves without the bike, so the heal path,
      // which composed from a read microseconds ago, does not read twice.
      final needsFreshRead =
          _needsBikeTruth(PacketField.light, newState, authoritative) ||
              _needsBikeTruth(PacketField.assist, newState, authoritative);
      List<int>? data;
      var aborted = false;
      _pendingWrites++;
      try {
        // One queue slot for read and write both: a settings write is a
        // select-then-write sequence on the same characteristic reads and ride
        // data requests use, so a poll or ride data request queued between the
        // two would break the select-then-use invariant.
        await _withRegister(() async {
          if (stale != null && !identical(stale, state)) {
            _logD('Dropping a write composed before a change');
            aborted = true;
            return;
          }
          ({bool light, int assist})? fresh;
          if (needsFreshRead) {
            final read = await repo.read();
            if (read != null && isSettingsPacket(read)) {
              fresh = (light: read[4] == 1, assist: read[2]);
              _lastKnown = fresh;
            } else {
              _logW('Composing from cache, bad read: $read');
            }
          }
          final composed = _composePacket(newState, authoritative, fresh);
          newState =
              newState.copyWith(light: composed.light, assist: composed.assist);
          wire = computeWire();
          data = newState.toWriteData(wire: wire);
          await repo.write(data!);
        });
      } catch (e) {
        // A latched _writing would silence the poll for good, and with it the
        // dynamic-mode self-heal that is meant to recover from exactly this.
        _writing = false;
        _logE('Error writing to bike', e);
        return;
      } finally {
        _pendingWrites--;
      }
      if (aborted) {
        // Nothing went on the wire, so nothing about the bike is known now —
        // and the state this write carried is out of date by definition.
        _writing = false;
        return;
      }
      // The bike echoes a write into its register, so this is bike truth too.
      _lastKnown = (light: newState.light, assist: newState.assist);
      // The bike may have been deleted while the write was in flight; saving
      // now would bring it back.
      if (!ref.mounted || _deleted) {
        return;
      }
      _logD('Wrote data to bike: $data');
    }
    _assertedWire = wire;
    var lockChanged = state.modeLock != newState.modeLock;
    ref.read(bikesDBProvider.notifier).saveBike(newState);
    state = newState;
    _syncKeepAlive(newState);
    if (lockChanged) {
      _syncBackgroundLock(newState.modeLock);
    }
    // Re-armed on any mode change, not only on leaving: switching from one
    // custom mode to another has to re-run the setup for the new one.
    if (modeChanged || (wasSwitching && !nowSwitching)) {
      _dynamicActive = false;
    }
    if (nowSwitching) {
      _enterSwitchingMode();
    }
    updateStateData();
  }

  /// One-off work for a speed-switching mode being active: ask for the speed
  /// stream it lives on, and put the phone in a state where it keeps running.
  /// Idempotent — both a transition and a fresh build land here.
  void _enterSwitchingMode() {
    if (_dynamicActive) {
      return;
    }
    _dynamicActive = true;
    _logD('Speed switching is active');
    // Deferred: this also runs from build, where state cannot be read yet.
    unawaited(Future<void>.microtask(() async {
      if (!ref.mounted) {
        return;
      }
      await _requestRideData();
      if (!ref.mounted) {
        return;
      }
      await _enableAutoBackgroundLock();
    }));
  }

  /// A switching mode has to keep limiting the speed while the phone sits in a
  /// pocket, which on Android needs the foreground service. A lock the rider
  /// turned on themselves is left alone (and never auto-disabled).
  Future<void> _enableAutoBackgroundLock() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (!ref.mounted || !state.needsSpeedSwitching || state.modeLock) {
      return;
    }
    await Permission.notification.request();
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    if (!ref.mounted || !state.needsSpeedSwitching || state.modeLock) {
      return;
    }
    _logI('Speed switching: turning Background Lock on');
    writeStateData(state.copyWith(modeLock: true, modeLockAuto: true),
        saveToBike: false);
  }

  /// Keeps the foreground service in step with [BikeState.modeLock] even when
  /// no BikePage is mounted to do it. Idempotent, so it can overlap with the
  /// widget path.
  void _syncBackgroundLock(bool enabled) {
    if (!Platform.isAndroid) {
      return;
    }
    _initBackgroundLockService();
    unawaited(_syncBackgroundLockService(enabled));
  }

  void toggleLight() async {
    _logD('Toggling light: ${!state.light}');
    writeStateData(state.copyWith(light: !state.light),
        authoritative: const {PacketField.light});
  }

  /// Selects [modeId], which may be a native or a custom mode. A dangling id
  /// resolves to the bike's fallback rather than being rejected.
  void selectMode(String modeId) {
    _logD('Selecting mode: $modeId');
    // A mode change is nobody's light or assist change, so both come off the
    // bike rather than out of a state that may be a poll interval old.
    writeStateData(state.withSelectedMode(modeId), authoritative: const {});
  }

  /// Saves a change to the bike's own set of modes, and puts it on the wire
  /// when it changes what the bike is riding.
  ///
  /// The save is unconditional and comes first: a mode the rider authored, or
  /// deleted, is theirs whether or not the bike happens to be in range. Only
  /// the wire needs a connection, and it catches up on its own — through the
  /// poll's heal or the reconnect re-assert.
  void _saveModes(BikeState next, {required bool assertWire}) {
    writeStateData(next, saveToBike: false, authoritative: const {});
    if (assertWire && _isConnected) {
      writeStateData(state, authoritative: const {});
    }
  }

  /// Adds a custom mode, or replaces the one with the same id.
  ///
  /// Editing the mode the bike is on re-initialises the asserted wire when the
  /// edit moves the mode's profile pair; a rename leaves the bike where it is.
  void upsertCustomMode(CustomMode mode) {
    final modes = [...state.customModes];
    final index = modes.indexWhere((m) => m.id == mode.id);
    if (index == -1) {
      modes.add(mode);
    } else {
      modes[index] = mode;
    }
    _saveModes(state.copyWith(customModes: modes),
        assertWire: state.selectedMode.id == mode.id);
  }

  /// Removes a custom mode. If the bike was on it, selection lands on
  /// [BikeState.fallbackMode] and that mode's initial wire goes to the bike,
  /// with the usual teardown if the bike stops switching.
  void deleteCustomMode(String modeId) {
    _logI('Deleting custom mode: $modeId');
    final selected = state.selectedMode.id == modeId;
    final remaining = state.customModes.where((m) => m.id != modeId).toList();
    var next = state.copyWith(customModes: remaining);
    if (next.region == BikeRegion.ch && remaining.isEmpty) {
      // CH has no limited native mode, so its fallback is a custom one. Left
      // empty, the fallback would resolve to a mode that is not in
      // [selectableModes] at all — in memory only, and gone on the next load.
      next = next.copyWith(customModes: const [seededChMode]);
    }
    if (selected) {
      next = next.withSelectedMode(next.fallbackMode.id);
    }
    _saveModes(next, assertWire: selected);
  }

  /// Sets the pedal assist level. The rider owns the level they just picked;
  /// the light still comes off the bike.
  void setAssist(int level) {
    assert(level >= 0 && level <= 4, 'assist level out of range: $level');
    if (level == state.assist) {
      return;
    }
    _logD('Setting assist to: $level');
    writeStateData(state.copyWith(assist: level),
        authoritative: const {PacketField.assist});
  }

  /// Where a padlock tap moves the pin. The startup state is not in the cycle
  /// yet: it needs a control that can show which value it pins.
  static PinState _flipPin(PinState pin) =>
      pin == PinState.locked ? PinState.open : PinState.locked;

  void toggleLightLocked() async {
    final next = _flipPin(state.pinLight);
    _logD('Toggling light lock: ${next.name}');
    writeStateData(state.copyWith(pinLight: next), saveToBike: false);
  }

  void toggleModeLocked() async {
    final next = _flipPin(state.pinMode);
    _logD('Toggling mode lock: ${next.name}');
    writeStateData(state.copyWith(pinMode: next), saveToBike: false);
  }

  void toggleAssistLocked() async {
    final next = _flipPin(state.pinAssist);
    _logD('Toggling assist lock: ${next.name}');
    writeStateData(state.copyWith(pinAssist: next), saveToBike: false);
  }

  void toggleBackgroundLock() async {
    _logD('Toggling background lock: ${!state.modeLock}');
    // The rider took over the lock, so dynamic mode stops managing it.
    writeStateData(
        state.copyWith(modeLock: !state.modeLock, modeLockAuto: false),
        saveToBike: false);
  }

  /// Deletes the bike and tears this notifier down with it.
  ///
  /// Removing the record is not enough: a switching mode and the Background
  /// Lock hold the notifier alive without any UI, so its poll, its samples and
  /// the foreground service would all keep running — and the first write would
  /// call [BikesDB.saveBike], putting the deleted bike straight back into
  /// bikes.json.
  void deleteStateData(BikeState bike) {
    _logI('Deleting bike: ${bike.name}');
    _deleted = true;
    _updateTimer?.cancel();
    _updateDebounce?.cancel();
    _speedSub?.cancel();
    _speedSub = null;
    ref.read(bikesDBProvider.notifier).deleteBike(bike);
    if (bike.modeLock) {
      _syncBackgroundLock(false);
    }
    // Last: with no UI listening this disposes the provider.
    _keepAlive?.close();
    _keepAlive = null;
  }
}

class BikePage extends ConsumerStatefulWidget {
  const BikePage({super.key, required this.bikeID});
  final String bikeID;

  @override
  BikePageState createState() => BikePageState();
}

@pragma('vm:entry-point')
void _startBackgroundLockCallback() {
  FlutterForegroundTask.setTaskHandler(_BackgroundLockTaskHandler());
}

class _BackgroundLockTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

void _initBackgroundLockService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'notification_channel_id',
      channelName: 'Background Lock Notification',
      priority: NotificationPriority.LOW,
      channelImportance: NotificationChannelImportance.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
    ),
  );
}

Future<void> _syncBackgroundLockService(bool enabled) async {
  final running = await FlutterForegroundTask.isRunningService;
  if (enabled && !running) {
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'SuperDuper Background Lock On',
      notificationText: 'Tap to return to the app',
      callback: _startBackgroundLockCallback,
    );
  } else if (!enabled && running) {
    await FlutterForegroundTask.stopService();
  }
}

class ForegroundNotificationWrapper extends StatefulWidget {
  const ForegroundNotificationWrapper(
      {super.key, required this.child, required this.enabled});
  final Widget child;
  final bool enabled;

  @override
  State<ForegroundNotificationWrapper> createState() =>
      _ForegroundNotificationWrapperState();
}

class _ForegroundNotificationWrapperState
    extends State<ForegroundNotificationWrapper> {
  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      _initBackgroundLockService();
      _syncBackgroundLockService(widget.enabled);
    }
  }

  @override
  void didUpdateWidget(ForegroundNotificationWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Platform.isAndroid && oldWidget.enabled != widget.enabled) {
      _syncBackgroundLockService(widget.enabled);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return widget.child;
    }
    return WithForegroundTask(child: widget.child);
  }
}

class BikePageState extends ConsumerState<BikePage> {
  @override
  void initState() {
    super.initState();
    // Schedule a post-frame callback to ensure providers are initialized
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final bikeControl = ref.read(bikeProvider(widget.bikeID).notifier);
      final connectionState =
          ref.read(connectionHandlerProvider(widget.bikeID));

      if (connectionState == SDBluetoothConnectionState.connected) {
        bikeControl.updateStateDataNow(force: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    var bike = ref.watch(bikeProvider(widget.bikeID));
    // No reconnect listener here: the Bike notifier re-asserts state for every
    // bike on reconnect (_onConnectionState), whether or not this page is
    // mounted.
    return ForegroundNotificationWrapper(
      enabled: bike.modeLock,
      child: Scaffold(
          backgroundColor: SDSurface.page,
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // Modern App Bar without bike name
              SliverAppBar(
                backgroundColor: SDSurface.page,
                pinned: true,
                expandedHeight: 60, // Reduced height without the title
                stretch: true,
                leading: IconButton(
                  tooltip: 'Back',
                  // No box behind the icon: the old one painted black on a
                  // black page, so it only made the icon look boxed in.
                  icon: const Icon(Icons.arrow_back, color: SDSurface.text),
                  onPressed: () {
                    var settings = ref.read(settingsDBProvider);
                    ref
                        .read(settingsDBProvider.notifier)
                        .save(settings.copyWith(currentBike: null));
                    Navigator.pop(context);
                  },
                ),
                actions: [
                  IconButton(
                    tooltip: 'Bike settings',
                    icon: const Icon(Icons.settings, color: SDSurface.text),
                    onPressed: () {
                      edit.show(context, bike);
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(color: SDSurface.page),
                  collapseMode: CollapseMode.pin,
                  stretchModes: const [],
                ),
              ),

              // Bike name as a header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The one place the bike's full gradient survives: an
                      // identity dot. No card is painted with it any more.
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [
                                getColor(bike.color).start,
                                getColor(bike.color).end,
                              ],
                              begin: Alignment.bottomLeft,
                              end: Alignment.topRight,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              bike.name,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: SDSurface.text,
                                  ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 2,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                EnhancedConnectionWidget(bike: bike),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Controls Section
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    // Light Control
                    EnhancedLightControlWidget(bike: bike),
                    const SizedBox(height: 16),

                    // Mode Control
                    EnhancedModeControlWidget(bike: bike),
                    const SizedBox(height: 16),

                    // Assist Control
                    EnhancedAssistControlWidget(bike: bike),

                    // Background Lock (Android only)
                    if (Platform.isAndroid) ...[
                      const SizedBox(height: 16),
                      EnhancedBackgroundLockWidget(bike: bike),
                    ],

                    // Help Section
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32.0),
                      child: Center(
                        // A quiet text button: help is not a control, so it
                        // must not compete with the cards above it.
                        child: TextButton.icon(
                          onPressed: () {
                            final Uri url = Uri.parse(
                                'https://github.com/blopker/superduper/?tab=readme-ov-file#getting-started');
                            launchUrl(url,
                                mode: LaunchMode.externalApplication);
                          },
                          icon: const Icon(Icons.help_outline, size: 18),
                          label: Text(
                            "Help & tips",
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: SDSurface.muted,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),

              // Bottom Padding
              const SliverToBoxAdapter(child: SizedBox(height: 40)),
            ],
          )),
    );
  }
}

class EnhancedConnectionWidget extends ConsumerWidget {
  const EnhancedConnectionWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var connectionProvider = connectionHandlerProvider(bike.id);
    var connectionStatus = ref.watch(connectionProvider);
    var connectionHandler = ref.watch(connectionProvider.notifier);
    var isScanning = ref.watch(isScanningStatusProvider).value == true;

    String text = 'Connecting...';
    IconData icon = Icons.sync;
    Color textColor = Colors.grey;
    bool disabled = true;
    Color bgColor =
        Colors.grey.withAlpha(51); // 0.2 opacity equals alpha 51 (0.2 * 255)

    if (connectionStatus == SDBluetoothConnectionState.connected) {
      text = 'Connected';
      icon = Icons.bluetooth_connected;
      textColor = Colors.green;
      bgColor = Colors.green
          .withAlpha(38); // 0.15 opacity equals alpha 38 (0.15 * 255)
      disabled = true;
    } else if (connectionStatus == SDBluetoothConnectionState.disconnected) {
      // Offered while a scan is running too. The select page scans for 100 s on
      // startup, and with auto-reconnect off that is exactly the window a rider
      // who just power-cycled the bike reaches for this button in — the Edit
      // sheet's own caption promises them it always works.
      text = 'Connect';
      icon = Icons.bluetooth;
      textColor = const Color(0xff4A80F0);
      bgColor = const Color(0xff4A80F0).withAlpha(38); // 0.15 opacity
      disabled = false;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: disabled
          ? null
          : () async {
              // A scan in flight comes down first: connecting out from under an
              // active scan is the case the platforms are least happy about,
              // and the rider asking for this bike is done looking for others.
              if (isScanning) {
                await ref.read(bluetoothRepositoryProvider).stopScan();
              }
              connectionHandler.connect();
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: textColor),
            const SizedBox(width: 4),
            Text(
              text,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: textColor,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class EnhancedLockWidget extends StatelessWidget {
  const EnhancedLockWidget({
    super.key,
    required this.locked,
    required this.onTap,
    required this.tooltip,
  });

  final bool locked;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: 20,
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      onPressed: onTap,
      icon: Icon(
        locked ? Icons.lock : Icons.lock_open,
        color: locked ? SDSurface.text : SDSurface.muted,
      ),
    );
  }
}

class EnhancedLightControlWidget extends ConsumerWidget {
  const EnhancedLightControlWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var bikeControl = ref.watch(bikeProvider(bike.id).notifier);
    // Light and assist are bike truth: an offline change cannot stick, and
    // writeStateData drops it silently — the 2026-08-08 log tail shows four
    // identical light taps going nowhere. Honest UI: grey the card out, like
    // the Connect chip.
    final connected = ref.watch(connectionHandlerProvider(bike.id)) ==
        SDBluetoothConnectionState.connected;
    return ControlCard(
      colorIndex: bike.color,
      title: "Light",
      titleIcon: bike.light ? Icons.lightbulb : Icons.lightbulb_outline,
      active: bike.light,
      enabled: connected,
      onTap: connected ? bikeControl.toggleLight : null,
      trailing: EnhancedLockWidget(
        locked: bike.pinLight == PinState.locked,
        onTap: bikeControl.toggleLightLocked,
        tooltip: 'Lock the light',
      ),
    );
  }
}

class EnhancedModeControlWidget extends ConsumerWidget {
  const EnhancedModeControlWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var bikeControl = ref.watch(bikeProvider(bike.id).notifier);
    // Matched by id, never by list membership: a CH bike whose custom modes are
    // gone rides a fallback that is not in [selectableModes] at all, and the
    // card then has to render with nothing selected rather than misaccent or
    // throw.
    final selectedModeId = bike.selectedMode.id;
    // The app owns the mode, but the wire byte that puts it on the bike does
    // not go out while the bike is away — writeStateData drops it silently. So
    // the card greys out, like the Connect chip. See
    // [EnhancedLightControlWidget].
    final connected = ref.watch(connectionHandlerProvider(bike.id)) ==
        SDBluetoothConnectionState.connected;

    return Column(
      children: [
        ControlCard(
          colorIndex: bike.color,
          title: "Mode",
          titleIcon: Icons.electric_bike,
          showSwitch: false,
          enabled: connected,
          trailing: EnhancedLockWidget(
            locked: bike.pinMode == PinState.locked,
            onTap: bikeControl.toggleModeLocked,
            tooltip: 'Lock the mode',
          ),
          body: SelectorBody(
            colorIndex: bike.color,
            layout: SelectorLayout.rows,
            items: [
              for (final mode in bike.selectableModes)
                SelectorItem(
                  keyValue: 'modeChip:${mode.id}',
                  label: mode.name,
                  tooltip: 'Select mode ${mode.name}',
                  selected: mode.id == selectedModeId,
                  onTap:
                      connected ? () => bikeControl.selectMode(mode.id) : null,
                ),
            ],
          ),
        ),
        // iOS has no background service, so a custom mode's speed switching
        // only runs while the app is in the foreground.
        if (Platform.isIOS && bike.needsSpeedSwitching)
          Padding(
            padding: const EdgeInsets.only(top: 12.0, left: 8.0, right: 8.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    "Dynamic mode switching stops when the app is closed or the phone is locked. The bike stays in the profile written last.",
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class EnhancedBackgroundLockWidget extends ConsumerWidget {
  const EnhancedBackgroundLockWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var bikeControl = ref.watch(bikeProvider(bike.id).notifier);
    return Column(
      children: [
        ControlCard(
          colorIndex: bike.color,
          title: "Background Lock",
          titleIcon: Icons.phonelink_lock,
          active: bike.modeLock,
          // No [enabled] gate: Background Lock is app state, and works while
          // the bike is out of range, exactly like the lock buttons.
          onTap: () async {
            await Permission.notification.request();
            if (Platform.isAndroid) {
              await FlutterForegroundTask.requestIgnoreBatteryOptimization();
            }
            bikeControl.toggleBackgroundLock();
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12.0, left: 8.0, right: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  "Background Lock may cause phone battery drain. See Help for more info.",
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        color: Colors.grey,
                        fontSize: 12,
                      ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class EnhancedAssistControlWidget extends ConsumerWidget {
  const EnhancedAssistControlWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var bikeControl = ref.watch(bikeProvider(bike.id).notifier);
    // Assist is bike truth: an offline change cannot stick, and writeStateData
    // drops it silently. See [EnhancedLightControlWidget].
    final connected = ref.watch(connectionHandlerProvider(bike.id)) ==
        SDBluetoothConnectionState.connected;

    return ControlCard(
      colorIndex: bike.color,
      title: "Assist",
      titleIcon: Icons.autorenew,
      showSwitch: false,
      enabled: connected,
      trailing: EnhancedLockWidget(
        locked: bike.pinAssist == PinState.locked,
        onTap: bikeControl.toggleAssistLocked,
        tooltip: 'Lock the assist',
      ),
      body: SelectorBody(
        colorIndex: bike.color,
        layout: SelectorLayout.segments,
        items: [
          for (var level = 0; level <= 4; level++)
            SelectorItem(
              keyValue: 'assistChip:$level',
              label: '$level',
              tooltip: 'Select assist $level',
              selected: bike.assist == level,
              onTap: connected ? () => bikeControl.setAssist(level) : null,
            ),
        ],
      ),
    );
  }
}

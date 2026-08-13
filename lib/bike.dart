import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;
import 'package:permission_handler/permission_handler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:superduper/calibration_page.dart';
import 'package:superduper/colors.dart';
import 'package:superduper/db.dart';
import 'package:superduper/edit_bike.dart' as edit;
import 'package:superduper/models.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/services.dart';
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

/// Whether the app has to keep working for [bike] with no UI on screen.
///
/// The one rule both layers read: the keep-alive that holds the control loop,
/// and the Android foreground service that holds the process. Two hand-written
/// copies of it are what let a locked value stop being enforced the moment the
/// page was popped.
///
/// Both conditions are continuous work — a switching mode limits the speed in
/// the rider's pocket, a locked padlock holds its value there. A startup pin is
/// deliberately not one of them: it needs the app awake for the one connect
/// after a power cycle, which does not earn a permanent notification.
bool needsBackgroundEnforcement(BikeState bike) =>
    bike.needsSpeedSwitching || bike.anyPinLocked;

/// What the page says at its foot about the work that goes on with no UI.
enum BackgroundStatus {
  /// Nothing has to keep running, so the page says nothing.
  none,

  /// The service holds the phone awake for it.
  active,

  /// It has to keep running, but nothing can hold the phone awake for it: the
  /// notification permission was refused, or the platform has no service.
  degraded,
}

/// The status of the background work for [bike].
///
/// [hasService] is false where there is no foreground service to run (iOS), and
/// [notificationsBlocked] is true where the rider refused the notification the
/// service needs. Both come in as values rather than being read here, so the
/// rule can be tested on any platform.
BackgroundStatus backgroundStatusFor(BikeState bike,
    {required bool hasService, required bool notificationsBlocked}) {
  if (!needsBackgroundEnforcement(bike)) {
    return BackgroundStatus.none;
  }
  if (!hasService || notificationsBlocked) {
    return BackgroundStatus.degraded;
  }
  return BackgroundStatus.active;
}

/// What [backgroundStatusFor] tells the rider, or null when there is nothing to
/// say. [hasService] is false where there is no service to ask for at all, and
/// the rider can do nothing about it.
String? backgroundStatusText(BackgroundStatus status, BikeState bike,
    {required bool hasService}) {
  // Named rather than "your locks": a switching mode is the thing riders came
  // for, and its name is what they picked.
  final what = bike.needsSpeedSwitching ? bike.selectedMode.name : 'your locks';
  // A mode with a fallback wire rides an unlimited base profile: the firmware
  // holds no limit under it, so "the app stops" does not mean "you get the
  // firmware limit", it means the bike can be left unlimited. Say that.
  final unlimited = unwatchedWireFor(bike.selectedMode, bike.region) != null;
  return switch (status) {
    BackgroundStatus.none => null,
    BackgroundStatus.active =>
      'Keeping $what active while your phone is locked. Uses some battery.',
    BackgroundStatus.degraded when !hasService && unlimited =>
      'Locks and speed limiting only work while the app is open. $what has no '
          'firmware limit. If you close the app, the bike can stay unlimited.',
    BackgroundStatus.degraded when !hasService =>
      'Locks and speed limiting only work while the app is open.',
    BackgroundStatus.degraded when unlimited =>
      'Notifications are off, so $what can stop when your phone is locked. '
          '$what has no firmware limit, so the bike can stay unlimited. '
          'Turn notifications on to keep it active.',
    BackgroundStatus.degraded =>
      'Notifications are off, so $what can stop when your phone is locked. '
          'Turn notifications on to keep it active.',
  };
}

/// What a measured boot says about this bike, against the values the guide
/// staged before the outage.
///
/// A byte that comes back exactly as it was staged is persisted: the firmware
/// carried it through the power cycle, so it holds no boot news and detection
/// has to ignore it. Null is that answer — "unusable", never "unknown". The
/// staged pair is kept whole, so a later audit can read what the measurement
/// compared against.
BootSignature classifyBootSignature({
  required ({int assist, int wire}) preOff,
  required ({int assist, int wire}) settled,
  required DateTime measuredAt,
}) =>
    BootSignature(
      measuredAt: measuredAt,
      bootWire: settled.wire == preOff.wire ? null : settled.wire,
      bootAssist: settled.assist == preOff.assist ? null : settled.assist,
      preOffWire: preOff.wire,
      preOffAssist: preOff.assist,
    );

/// Whether this platform can hold the app awake with no UI.
bool get _hasBackgroundService => Platform.isAndroid;

/// Whether a padlock cannot be held while the phone is in a pocket, and the
/// rider can do something about it.
///
/// A platform with no service at all is deliberately not marked here: every
/// padlock would carry a warning nobody can act on. The page foot says that
/// once, for the whole page.
bool pinDegraded(PinState pin,
        {required bool hasService, required bool notificationsBlocked}) =>
    pin == PinState.locked && hasService && notificationsBlocked;

/// Whether the rider refused the notification the foreground service needs, so
/// a locked padlock cannot be held while the phone is in a pocket.
///
/// Not gated on the platform: the pins show as degraded from this one flag, and
/// [backgroundStatusFor] adds what the platform can do.
@Riverpod(keepAlive: true)
class NotificationsBlocked extends _$NotificationsBlocked {
  @override
  bool build() => false;

  void set(bool blocked) {
    if (state != blocked) {
      log.i(SDLogger.bike, 'Notification permission blocked: $blocked');
    }
    state = blocked;
  }
}

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

  /// Whether a calibration recording window is open.
  ///
  /// While it is, every path that puts a settings packet on the bike is
  /// suppressed: the app writes about 200 ms after the first read of a
  /// reconnect, and that write overwrites exactly the bytes the calibration
  /// exists to measure. A suppressed write is dropped and logged, never queued —
  /// replaying it when the window closes would put the pre-outage state back on
  /// a bike the rider is still measuring.
  bool _calibrating = false;

  @visibleForTesting
  bool get debugCalibrating => _calibrating;

  /// Whether the next settings read still has to answer whether the bike was
  /// power-cycled.
  ///
  /// Armed on every connect, and once here for a bike that is connected before
  /// this notifier is built. Cleared by the read that answers it, so a startup
  /// pin is applied at most once per outage — a later poll compares two reads
  /// of the same ride, where every difference is the rider on the handlebar.
  bool _powerCycleCheckDue = true;

  /// Every line this notifier writes carries the device id: it is the join key
  /// against the `[Bluetooth]` lines, which log the same id, and it is the only
  /// way to tell two bikes apart in one session. Through helpers rather than at
  /// each call site so a new line cannot forget it.
  void _logD(String message) => log.d(SDLogger.bike, '[$id] $message');
  void _logI(String message) => log.i(SDLogger.bike, '[$id] $message');
  void _logW(String message) => log.w(SDLogger.bike, '[$id] $message');
  void _logE(String message, [Object? error, StackTrace? stackTrace]) =>
      log.e(SDLogger.bike, '[$id] $message', error, stackTrace);

  /// A calibration line, at info level and with its own prefix inside the bike
  /// tag: the recording window is evidence a rider shares, and the whole window
  /// has to be one greppable block in a release log too.
  void _logCalibration(String message) =>
      log.i(SDLogger.bike, '[$id] [Calibration] $message');

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
    _assertedWire = initialWireFor(bike.selectedMode, region: bike.region);
    _syncKeepAlive(bike);
    _refreshNotificationPermission();
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
    // The first read after this connect decides whether the bike kept its
    // settings across the outage, and a startup pin acts on that answer alone.
    _powerCycleCheckDue = true;
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
    // Checked after the settle as well as inside [writeStateData]: the window
    // can open while this waits, and the read this would take is noise in it.
    if (_calibrating) {
      _logCalibration('Suppressed the reconnect re-assert');
      return;
    }
    // A mode with an unlimited base may not come back on that base: no speed
    // has arrived on this connection yet, so nothing says the app can see the
    // bike. Re-entered on its cap, exactly as selecting it enters it.
    final capped = unwatchedWireFor(state.selectedMode, state.region);
    if (capped != null) {
      _assertedWire = capped;
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
    var newWire = dynamicWireFor(selected.mode, speedKmh, _assertedWire,
        region: state.region);
    if (newWire == _assertedWire) {
      return;
    }
    // Before [_assertedWire] moves: a wire the app records as asserted but never
    // wrote would make every later heal judge against a bike state that does not
    // exist. A speed sample can arrive before the first read of a reconnect, so
    // this is one of the two write-before-read paths the window has to close.
    if (_calibrating) {
      _logCalibration(
          'Suppressed a speed switch: wire $_assertedWire -> $newWire');
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
  ///
  /// A blind app is also the one moment a mode with an unlimited base must not
  /// stay on it: the firmware holds no limit there, so the app is the limiter,
  /// and a limiter that cannot see the speed has to give the bike back to the
  /// firmware. The cap goes on the wire first, before the ride data request.
  void _checkSpeedStream() {
    if (!state.needsSpeedSwitching || !_isConnected) {
      return;
    }
    var last = _lastSpeedAt;
    if (last != null && DateTime.now().difference(last) < _speedTimeout) {
      return;
    }
    _capUnwatchedMode();
    _logD('No speed samples, requesting ride data again');
    unawaited(_requestRideData());
  }

  /// Puts a mode whose base is unlimited back on its cap profile. Does nothing
  /// for every other mode: their base profile carries a firmware limiter, so a
  /// blind app still leaves a limited bike.
  void _capUnwatchedMode() {
    final wire = unwatchedWireFor(state.selectedMode, state.region);
    if (wire == null || wire == _assertedWire) {
      return;
    }
    // The watchdog fires from its own timer, so it can land inside the connect
    // settle — the second write-before-read path. Suppressed before
    // [_assertedWire] moves, for the reason [_onSpeedSample] gives.
    if (_calibrating) {
      _logCalibration('Suppressed the cap of ${state.selectedMode.name}: '
          'wire $_assertedWire -> $wire');
      return;
    }
    _logW('No speed samples, capping ${state.selectedMode.name}: '
        'wire $_assertedWire -> $wire');
    _assertedWire = wire;
    // Same settings, new wire byte, exactly as a speed transition writes it.
    writeStateData(state, authoritative: const {}, abortIfStale: true);
  }

  /// Ages the last speed sample past the watchdog's timeout and runs the
  /// watchdog, so a test can reach the stream-death path without waiting out
  /// five real seconds.
  @visibleForTesting
  void debugExpireSpeedStream() {
    _lastSpeedAt = DateTime.now().subtract(_speedTimeout * 2);
    _checkSpeedStream();
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

  /// Holds the control loop alive when the UI is gone, for as long as
  /// [needsBackgroundEnforcement] says there is something to enforce.
  void _syncKeepAlive(BikeState bike) {
    var needed = needsBackgroundEnforcement(bike);
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

  /// Reads the notification permission without raising a dialog, so a padlock
  /// shows as degraded from the first frame after an app start.
  ///
  /// The flag has to be refreshed here and not only when the app asks: a rider
  /// who refused once keeps the refusal, and a flag that starts clean on every
  /// launch would say the padlock works for the rest of the session.
  void _refreshNotificationPermission() {
    if (!_hasBackgroundService) {
      return;
    }
    // Deferred: this runs from build, where ref may not be read yet.
    unawaited(Future<void>.microtask(() async {
      final granted = await Permission.notification.isGranted;
      if (!ref.mounted) {
        return;
      }
      ref.read(notificationsBlockedProvider.notifier).set(!granted);
    }));
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
    if (!ref.mounted || _deleted) {
      // The bike went away while the read was in flight: touching state now
      // would throw, and saving would put a deleted bike back.
      return;
    }
    // Bike truth, and only out of a read the gate above let through: a read
    // that predates a queued write says nothing about what the bike came up
    // with, and answering the question with it would consume the power cycle
    // signature and lose the pins for this outage.
    final seen = LastSeen(assist: data[2], light: data[4] == 1, wire: data[5]);
    var powerCycled = false;
    if (_calibrating) {
      // The pins stay armed rather than being answered and suppressed: the boot
      // the rider caused to measure the bike is not the moment to apply them,
      // and consuming the check here would lose them for the ride that follows
      // the calibration.
      _logCalibration('Suppressed the startup pins, the check stays due');
    } else {
      powerCycled = _powerCycleCheckDue && _isPowerCycle(seen);
      _powerCycleCheckDue = false;
    }
    if (seen != state.lastSeen) {
      // Saved on its own, because an unchanged poll returns below without ever
      // reaching a write — and the record has to survive an app restart: the
      // sequence this exists for (bike off overnight, app opened, bike
      // switched on) is a cold start.
      final next = state.copyWith(lastSeen: seen);
      ref.read(bikesDBProvider.notifier).saveBike(next);
      state = next;
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
    // The one moment a startup pin acts: the ride starts on the pinned values.
    // After the verdict, so a pinned mode wins over the mode the bike came up
    // with; before the return, so a pin that changes nothing the read can see
    // still reaches the bike — the mode lives in the wire byte.
    var pinned = false;
    if (powerCycled) {
      final withPins = _applyStartupPins(newState);
      if (withPins != null) {
        _logI('Bike was power-cycled, applying the pinned values');
        newState = withPins;
        pinned = true;
      }
    }
    if (newState == state && !force && !heal && !pinned) {
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

  /// Whether [seen] says the bike lost the settings it had before the outage,
  /// which only a power cycle does.
  ///
  /// Compared against the last value the bike itself reported, never against
  /// what the app wanted: a write lost to a disconnect makes intent differ
  /// from reality with no power cycle involved, and the 2026-08-07 ride log
  /// has nine of those in one ride without a single power cycle.
  ///
  /// A calibrated bike is answered by its own measurement — see
  /// [_matchesBootSignature]. Everything below it is the heuristic that serves
  /// a bike the guide never measured.
  bool _isPowerCycle(LastSeen seen) {
    final before = state.lastSeen;
    if (before == null) {
      // The app has never read this bike, so there is no state it can claim
      // the bike preserved. Honouring the pin beats being careful about a bike
      // we know nothing about.
      return true;
    }
    final signature = state.bootSignature;
    final measured = signature == null
        ? null
        : _matchesBootSignature(signature, before: before, seen: seen);
    if (measured != null) {
      return measured;
    }
    // No signature, or one with no usable byte: the bike was never calibrated,
    // the rider skipped the guide, or the firmware keeps every byte. The old
    // heuristic below is all there is, and every migrated bike rides on it.
    if (before.assist != seen.assist || before.light != seen.light) {
      return true;
    }
    if (before.wire == seen.wire) {
      return false;
    }
    // Normalised, not raw: a switching mode rides its base profile or its cap
    // profile, and both mean the bike kept the mode it was in. Raw equality
    // would call every speed switch a power cycle.
    final selected = state.selectedMode;
    return !assertsWire(selected, before.wire, region: state.region) ||
        !assertsWire(selected, seen.wire, region: state.region);
  }

  /// Whether [seen] is the boot this bike was measured to produce, or null when
  /// [signature] has no usable byte at all — then the caller falls back.
  ///
  /// The rule, on the bytes the calibration classified as resetting: the bike
  /// reports exactly what it boots with, AND no longer what it reported before
  /// the outage. Both halves are necessary. The first alone would call a rider
  /// who selects the boot mode a power cycle; the second alone is the old
  /// heuristic, which any handlebar change satisfies.
  bool? _matchesBootSignature(BootSignature signature,
      {required LastSeen before, required LastSeen seen}) {
    var usable = false;
    final bootWire = signature.bootWire;
    if (bootWire != null) {
      // The raw byte, never normalised through [assertsWire]: the wire a bike
      // boots on is frequently one half of the selected mode's own pair — a
      // 25 km/h custom mode caps on the EU boot wire — and forgiving it there
      // is the defect this rule removes. Five boots on 2026-08-11 applied no
      // pin because of it. The absorption belongs to the heal verdict, which
      // asks a different question: which mode the bike is riding.
      if (seen.wire != bootWire) {
        return false;
      }
      if (before.wire == bootWire) {
        // The bike already sat on its boot wire before the outage, so a boot
        // and a dropout report the same byte. Accepted and deliberate: with no
        // change to see there is no evidence, and a wrong pin write costs the
        // rider the mode they were riding. Detection stays conservative.
        return false;
      }
      usable = true;
    }
    final bootAssist = signature.bootAssist;
    if (bootAssist != null) {
      if (seen.assist != bootAssist || before.assist == bootAssist) {
        return false;
      }
      usable = true;
    }
    // The light is not part of the signature: it has a boot transient and the
    // register value for it is untrustworthy. See [BootSignature].
    return usable ? true : null;
  }

  /// [bike] with the value of every padlock that is on [PinState.startup], or
  /// null when no padlock pins anything — so the caller does not force a write
  /// for a bike that has no startup pin at all.
  BikeState? _applyStartupPins(BikeState bike) {
    var next = bike;
    var any = false;
    final modeId = bike.startupModeId;
    if (bike.pinMode == PinState.startup && modeId != null) {
      next = next.withSelectedMode(modeId);
      any = true;
    }
    final light = bike.startupLight;
    if (bike.pinLight == PinState.startup && light != null) {
      next = next.copyWith(light: light);
      any = true;
    }
    final assist = bike.startupAssist;
    if (bike.pinAssist == PinState.startup && assist != null) {
      next = next.copyWith(assist: assist);
      any = true;
    }
    return any ? next : null;
  }

  /// When the recording window reads the settings register, counted from the
  /// moment [recordBootWindow] starts.
  ///
  /// Spread out rather than dense: the 2026-08-11 logs show the bike answers the
  /// first read within a second of the link coming up, and the light transient
  /// of the boot lasts about two seconds — a value that still moves at the end
  /// of the window is not the one the calibration may classify.
  static const bootWindowSchedule = <Duration>[
    Duration.zero,
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 8),
  ];

  /// Registers the window probes once each, for the log only.
  static const _odometerId = [2, 2];
  static const _batteryId = [4, 1];

  /// How many of the frames the app normally drops the window records. A few
  /// are the firmware probe; a transcript of the ride is not.
  static const _maxProbeFrames = 5;

  /// Reads the settings register through the boot window and returns the pair
  /// the bike settled on, or null when no valid read came back.
  ///
  /// Nothing is written for the whole window — the caller holds
  /// [setCalibrating] open around it — and nothing is stored: the caller
  /// classifies the settled pair against the values it staged before the
  /// outage. The odometer, the battery and the frames the app normally drops are
  /// logged as a firmware probe. A cleaner power-on tell (a trip reset, an
  /// uptime) may be in them, and only a real bike can show that; the model
  /// deliberately holds none of it yet.
  Future<({int assist, int wire})?> recordBootWindow({
    List<Duration> schedule = bootWindowSchedule,
  }) async {
    if (!_calibrating) {
      // Not refused: the window still records. But every write inside it
      // corrupts what it records, so the evidence has to say the guard was off.
      _logCalibration('Recording without the write suppression');
    }
    final handler = ref.read(connectionHandlerProvider(id).notifier);
    var frames = 0;
    handler.onRawNotification = (data) {
      // Only what the app drops: the speed frames are already in the ride
      // trace, and they arrive about once a second.
      if (frames >= _maxProbeFrames || parseSpeedNotification(data) != null) {
        return;
      }
      frames++;
      _logCalibration('Notification frame: $data');
    };
    final started = DateTime.now();
    ({int assist, int wire})? settled;
    try {
      for (final at in schedule) {
        final wait = at - DateTime.now().difference(started);
        if (wait > Duration.zero) {
          await Future<void>.delayed(wait);
        }
        if (!ref.mounted || _deleted) {
          return settled;
        }
        final ms = DateTime.now().difference(started).inMilliseconds;
        if (!_isConnected) {
          // A gap, not an end: the bike can drop once more while it boots, and
          // a later read of the same window still answers the question.
          _logCalibration('t=$ms ms: not connected, no read');
          continue;
        }
        final data = await _withRegister(() => handler.read());
        _logCalibration('t=$ms ms: settings register $data');
        if (data != null && isSettingsPacket(data)) {
          settled = (assist: data[2], wire: data[5]);
        }
      }
      // After the window, never inside it: both select another register, and a
      // settings read that follows one of them too closely comes back with the
      // wrong register's bytes.
      await _probeRegister('Odometer', _odometerId);
      await _probeRegister('Battery', _batteryId);
    } finally {
      handler.onRawNotification = null;
    }
    _logCalibration(settled == null
        ? 'No valid read in the window'
        : 'Settled on assist ${settled.assist}, wire ${settled.wire}');
    return settled;
  }

  /// Logs one read of [registerId]. The value is evidence for a later task, so
  /// nothing here parses it.
  Future<void> _probeRegister(String name, List<int> registerId) async {
    if (!ref.mounted || _deleted || !_isConnected) {
      return;
    }
    final data = await _withRegister(() => ref
        .read(connectionHandlerProvider(id).notifier)
        .read(registerId: registerId));
    _logCalibration('$name register $registerId: $data');
  }

  /// The assist level the guide puts on the bike before the rider switches it
  /// off.
  ///
  /// Deliberately not 0: the 2026-08-11 logs show the bike boots with assist 0,
  /// and a pre-off state equal to the boot state cannot be classified at all —
  /// every byte would come back "unchanged" and be excluded.
  static const calibrationStageAssist = 2;

  /// Whether the bike stands still, as far as the app can tell.
  ///
  /// A bike that never streamed, or stopped streaming, is standing: the bike
  /// itself stops sending ride data at a standstill. Asked before the staging
  /// write, which changes the assist level — not something to do under a rider.
  bool get _isStopped {
    final at = _lastSpeedAt;
    final speed = _lastSpeedKmh;
    if (at == null || speed == null) {
      return true;
    }
    return DateTime.now().difference(at) > _speedTimeout || speed <= 0;
  }

  /// Puts a known, non-boot state on the bike and confirms it with a read of
  /// the register. Returns the pair the bike reports back — the guide's
  /// `preOff` values — or null when nothing could be staged.
  ///
  /// Runs BEFORE the recording window opens: [writeStateData] suppresses every
  /// settings write while [_calibrating] is set, and this one is a settings
  /// write like any other.
  Future<({int assist, int wire})?> stageForCalibration() async {
    if (_calibrating) {
      _logCalibration('Refused to stage inside the recording window');
      return null;
    }
    if (!_isConnected || !_isStopped) {
      _logCalibration('Refused to stage: connected $_isConnected, '
          'standing $_isStopped');
      return null;
    }
    // Through the normal write path, so the record, [_assertedWire] and the
    // bike hold the same state afterwards. The wire is the selection's own:
    // the guide must never put a profile on the bike the app would not.
    writeStateData(state.copyWith(assist: calibrationStageAssist),
        authoritative: const {PacketField.assist});
    // Queued behind the write above by [_withRegister], so this read really is
    // its echo and not the state from before it.
    final data = await _withRegister(
        () => ref.read(connectionHandlerProvider(id).notifier).read());
    if (!ref.mounted || _deleted) {
      return null;
    }
    if (data == null || !isSettingsPacket(data)) {
      _logCalibration('Staging read came back as $data');
      return null;
    }
    final staged = (assist: data[2], wire: data[5]);
    if (staged.assist != calibrationStageAssist) {
      // The write was lost. Measuring against a pre-off state the bike does not
      // hold would classify every byte wrong.
      _logCalibration('Staging did not land: assist ${staged.assist}');
      return null;
    }
    _logCalibration('Staged assist ${staged.assist}, wire ${staged.wire}');
    return staged;
  }

  /// Classifies [settled] against the staged [preOff] pair and saves the
  /// signature on this bike's record.
  ///
  /// App data, not bike data: it goes out through the same `saveToBike: false`
  /// path a padlock takes, so nothing here reaches the bike.
  BootSignature saveBootSignature(
      {required ({int assist, int wire}) preOff,
      required ({int assist, int wire}) settled}) {
    final signature = classifyBootSignature(
        preOff: preOff, settled: settled, measuredAt: DateTime.now());
    _logCalibration('Signature: boot wire ${signature.bootWire}, boot assist '
        '${signature.bootAssist} (staged wire ${preOff.wire}, assist '
        '${preOff.assist})');
    writeStateData(state.copyWith(bootSignature: signature), saveToBike: false);
    return signature;
  }

  /// Opens or closes the write-suppression window. See [_calibrating].
  ///
  /// The guide holds it open from the moment it asks the rider to switch the
  /// bike off until the signature is classified, so nothing between the two
  /// touches the bike. Its own staging write goes on the bike before this
  /// opens.
  void setCalibrating(bool value) {
    if (_calibrating == value) {
      return;
    }
    _calibrating = value;
    _logCalibration(value ? 'Writes suppressed' : 'Writes allowed again');
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
    // The one gate every settings packet passes: the poll's adoption, the heal,
    // the startup pins, the speed switch, the watchdog cap and the rider's own
    // taps all end here, so a path added later cannot escape the window by
    // being missed. App-only writes (a padlock, a saved mode) go through, they
    // touch no byte of the bike.
    if (saveToBike == true && _calibrating) {
      _logCalibration('Suppressed a write of ${newState.selectedMode.name}, '
          'assist ${newState.assist}, light ${newState.light}');
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
        assertedWire: _assertedWire,
        region: newState.region);
    var wire = computeWire();
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
    // Read here rather than before the write, which may not return for
    // seconds: another write can land in that window and start the service
    // already.
    final wasNeeded = needsBackgroundEnforcement(state);
    final nowNeeded = needsBackgroundEnforcement(newState);
    ref.read(bikesDBProvider.notifier).saveBike(newState);
    state = newState;
    _syncKeepAlive(newState);
    if (wasNeeded != nowNeeded) {
      unawaited(_syncBackgroundService(nowNeeded));
    }
    // Re-armed on any mode change, not only on leaving: switching from one
    // custom mode to another has to re-run the setup for the new one.
    if (modeChanged || (wasSwitching && !nowSwitching)) {
      _dynamicActive = false;
    }
    if (nowSwitching) {
      _enterSwitchingMode();
    }
    if (!ref.mounted) {
      // Releasing the keep-alive above disposes this notifier on the spot when
      // the page is already popped, and everything below needs ref.
      return;
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
      // A bike that comes back from bikes.json on a switching mode reaches this
      // without ever passing the transition in [writeStateData]. Asked again
      // rather than assumed: the rider can leave the mode while the ride data
      // request above is still in flight.
      if (!needsBackgroundEnforcement(state)) {
        return;
      }
      await _syncBackgroundService(true);
    }));
  }

  /// Starts or stops the foreground service so it matches what has to be
  /// enforced. Idempotent, so it can overlap with the widget path, and it runs
  /// even when no BikePage is mounted.
  ///
  /// The Background Lock button used to ask for the notification permission and
  /// the battery exemption on a deliberate tap. With the button gone, this is
  /// that moment: a padlock reaching locked, or a switching mode being
  /// selected.
  Future<void> _syncBackgroundService(bool needed) async {
    if (!_hasBackgroundService) {
      return;
    }
    _initBackgroundService();
    if (needed) {
      final status = await Permission.notification.request();
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      if (!ref.mounted) {
        return;
      }
      ref.read(notificationsBlockedProvider.notifier).set(!status.isGranted);
      if (!status.isGranted) {
        // Started all the same: the service may still hold the process, and a
        // rider who gets the enforcement is better off than one who does not.
        // Nothing is promised either way — the page shows the padlocks as
        // degraded while this flag is set.
        _logW('Notification permission refused, the pins are degraded');
      }
    }
    await _setBackgroundService(needed);
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

  /// Moves the light padlock one step, through [nextPin].
  ///
  /// Arming [PinState.startup] captures the value that is selected now — that
  /// is what makes a picker unnecessary. The captured value stays behind when
  /// the pin moves on: nothing reads it unless the pin is on startup, and the
  /// next arming overwrites it.
  void cycleLightPin() {
    final next = nextPin(state.pinLight);
    _logD('Light pin: ${next.name}');
    var updated = state.copyWith(pinLight: next);
    if (next == PinState.startup) {
      updated = updated.copyWith(startupLight: state.light);
    }
    writeStateData(updated, saveToBike: false);
  }

  /// Moves the mode padlock one step. See [cycleLightPin].
  void cycleModePin() {
    final next = nextPin(state.pinMode);
    _logD('Mode pin: ${next.name}');
    var updated = state.copyWith(pinMode: next);
    if (next == PinState.startup) {
      // The resolved selection, not [modeId]: a dangling id would arm a pin on
      // a mode the bike cannot be put into.
      updated = updated.copyWith(startupModeId: state.selectedMode.id);
    }
    writeStateData(updated, saveToBike: false);
  }

  /// Moves the assist padlock one step. See [cycleLightPin].
  void cycleAssistPin() {
    final next = nextPin(state.pinAssist);
    _logD('Assist pin: ${next.name}');
    var updated = state.copyWith(pinAssist: next);
    if (next == PinState.startup) {
      updated = updated.copyWith(startupAssist: state.assist);
    }
    writeStateData(updated, saveToBike: false);
  }

  /// Aims the light padlock at the value a ride should start on.
  ///
  /// The counterpart of the capture in [cycleLightPin]: arming takes the value
  /// that is on now, and this re-aims it afterwards — the card is a picker
  /// while its pin is on [PinState.startup]. App state only, like the padlock
  /// itself, so the choice can be made with the bike out of range and never
  /// touches the light the bike is riding.
  void setStartupLight(bool on) {
    if (state.startupLight == on) {
      return;
    }
    _logD('Startup light: $on');
    writeStateData(state.copyWith(startupLight: on), saveToBike: false);
  }

  /// Aims the mode padlock. See [setStartupLight].
  void setStartupMode(String modeId) {
    if (state.startupModeId == modeId) {
      return;
    }
    _logD('Startup mode: $modeId');
    writeStateData(state.copyWith(startupModeId: modeId), saveToBike: false);
  }

  /// Aims the assist padlock. See [setStartupLight].
  void setStartupAssist(int level) {
    assert(level >= 0 && level <= 4, 'assist level out of range: $level');
    if (state.startupAssist == level) {
      return;
    }
    _logD('Startup assist: $level');
    writeStateData(state.copyWith(startupAssist: level), saveToBike: false);
  }

  /// Deletes the bike and tears this notifier down with it.
  ///
  /// Removing the record is not enough: a switching mode and a locked padlock
  /// hold the notifier alive without any UI, so its poll, its samples and the
  /// foreground service would all keep running — and the first write would call
  /// [BikesDB.saveBike], putting the deleted bike straight back into
  /// bikes.json.
  void deleteStateData(BikeState bike) {
    _logI('Deleting bike: ${bike.name}');
    _deleted = true;
    _updateTimer?.cancel();
    _updateDebounce?.cancel();
    _speedSub?.cancel();
    _speedSub = null;
    ref.read(bikesDBProvider.notifier).deleteBike(bike);
    if (needsBackgroundEnforcement(bike)) {
      unawaited(_syncBackgroundService(false));
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
void _startBackgroundServiceCallback() {
  FlutterForegroundTask.setTaskHandler(_BackgroundServiceTaskHandler());
}

class _BackgroundServiceTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

void _initBackgroundService() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      // The id an installed app already has its channel under. A new one would
      // orphan the channel the rider may have tuned.
      channelId: 'notification_channel_id',
      channelName: 'Background service',
      priority: NotificationPriority.LOW,
      channelImportance: NotificationChannelImportance.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
    ),
  );
}

Future<void> _setBackgroundService(bool enabled) async {
  final running = await FlutterForegroundTask.isRunningService;
  if (enabled && !running) {
    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'SuperDuper is holding your bike settings',
      notificationText: 'Tap to return to the app',
      callback: _startBackgroundServiceCallback,
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
      _initBackgroundService();
      _setBackgroundService(widget.enabled);
    }
  }

  @override
  void didUpdateWidget(ForegroundNotificationWrapper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Platform.isAndroid && oldWidget.enabled != widget.enabled) {
      _setBackgroundService(widget.enabled);
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
      } else {
        // The page open is one of the re-arms of the reconnect ladder, and this
        // is where it happens: the handler's own build cannot carry it, because
        // a bike that needs enforcement keeps its notifier — and with it the
        // handler — alive with no UI, so a page that is opened again never
        // builds a second one. A ladder that gave up while the app was away
        // gets a new run here.
        //
        // Unconditional on any other state: connect() re-arms first and
        // attempts second, and an attempt that is already in flight is dropped
        // by the guard in the handler, so a bike that is still connecting only
        // gets the rungs back.
        unawaited(ref
            .read(connectionHandlerProvider(widget.bikeID).notifier)
            .connect());
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
      // The same rule the notifier keeps its control loop alive by: two
      // hand-written copies of it are what let a locked value lose its
      // enforcement while the page said it was locked.
      enabled: needsBackgroundEnforcement(bike),
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
                    // The one-time offer of the boot calibration, above the
                    // controls: it asks for an answer, and a rider who never
                    // scrolls this page would never see it at the foot. It
                    // takes itself away once the bike is measured, or for this
                    // visit once the rider says Later.
                    CalibrationPromptWidget(bike: bike),

                    // Light Control
                    EnhancedLightControlWidget(bike: bike),
                    const SizedBox(height: 16),

                    // Mode Control
                    EnhancedModeControlWidget(bike: bike),
                    const SizedBox(height: 16),

                    // Assist Control
                    EnhancedAssistControlWidget(bike: bike),

                    // What the app keeps doing with the page closed. A status
                    // line, not a control: the rider already asked for the work
                    // by locking a value or picking a switching mode.
                    BackgroundStatusWidget(bike: bike),

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

/// [pinDegraded] with the platform and the permission filled in from the app.
bool _pinDegradedNow(WidgetRef ref, PinState pin) => pinDegraded(pin,
    hasService: _hasBackgroundService,
    notificationsBlocked: ref.watch(notificationsBlockedProvider));

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
    // A pin on startup turns the card into a picker for the value the ride
    // starts on. That choice is app state, so it needs no bike: the connection
    // gate is bypassed for it, and only for it.
    final selecting = bike.pinLight == PinState.startup;
    final startupLight = bike.startupLight ?? bike.light;
    return ControlCard(
      colorIndex: bike.color,
      title: "Light",
      titleIcon: bike.light ? Icons.lightbulb : Icons.lightbulb_outline,
      active: bike.light,
      enabled: connected || selecting,
      caption: selecting
          ? 'Tap the card to choose: light on or off at the start'
          : null,
      onTap: selecting
          ? () => bikeControl.setStartupLight(!startupLight)
          : (connected ? bikeControl.toggleLight : null),
      // The light has no list, so its startup pin is a tag in the header.
      badge: bike.pinLight == PinState.startup && bike.startupLight != null
          ? (bike.startupLight! ? 'STARTS ON' : 'STARTS OFF')
          : null,
      trailing: EnhancedLockWidget(
        pin: bike.pinLight,
        degraded: _pinDegradedNow(ref, bike.pinLight),
        onTap: bikeControl.cycleLightPin,
        tooltip: pinTooltip(bike.pinLight, 'light'),
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
    // The card picks the mode a ride starts on while its pin is on startup —
    // app state, so it works with the bike away. See
    // [EnhancedLightControlWidget].
    final selecting = bike.pinMode == PinState.startup;

    return Column(
      children: [
        ControlCard(
          colorIndex: bike.color,
          title: "Mode",
          titleIcon: Icons.electric_bike,
          showSwitch: false,
          enabled: connected || selecting,
          caption: selecting ? 'Tap the mode the bike starts with' : null,
          trailing: EnhancedLockWidget(
            pin: bike.pinMode,
            degraded: _pinDegradedNow(ref, bike.pinMode),
            onTap: bikeControl.cycleModePin,
            tooltip: pinTooltip(bike.pinMode, 'mode'),
          ),
          body: SelectorBody(
            colorIndex: bike.color,
            layout: SelectorLayout.rows,
            items: [
              for (final mode in bike.selectableModes)
                SelectorItem(
                  keyValue: 'modeChip:${mode.id}',
                  label: mode.label(bike.region),
                  tooltip: mode.note == null
                      ? 'Select mode ${mode.name}'
                      : '${mode.name} · ${mode.note}',
                  selected: mode.id == selectedModeId,
                  // The captured value, not the live one: the pin marks the
                  // mode a ride starts on, which is not always the one on now.
                  pinned: selecting && mode.id == bike.startupModeId,
                  onTap: selecting
                      ? () => bikeControl.setStartupMode(mode.id)
                      : (connected
                          ? () => bikeControl.selectMode(mode.id)
                          : null),
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
                    // A mode on an unlimited base gets the plain word: "the
                    // profile written last" hides that the last profile can be
                    // OFFROAD.
                    unwatchedWireFor(bike.selectedMode, bike.region) != null
                        ? 'Dynamic mode switching stops when the app is closed '
                            'or the phone is locked. ${bike.selectedMode.name} '
                            'has no firmware limit, so the bike can stay '
                            'unlimited.'
                        : 'Dynamic mode switching stops when the app is closed '
                            'or the phone is locked. The bike stays in the '
                            'profile written last.',
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

/// The one-time offer of the boot calibration, on the page of a bike whose
/// [BikeState.bootSignature] is null — which every bike is until it is
/// measured, this app's own upgrade included.
///
/// A card and not a pushed guide: the rider opened the page to ride, and a
/// flow that asks them to switch the bike off and on has to be asked for. It
/// is offered only while the bike is connected and standing, because that is
/// what the first step needs, and "Later" takes it away for this visit. The
/// bike's settings sheet holds the same entry for a re-run.
class CalibrationPromptWidget extends ConsumerStatefulWidget {
  const CalibrationPromptWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  ConsumerState<CalibrationPromptWidget> createState() =>
      _CalibrationPromptWidgetState();
}

class _CalibrationPromptWidgetState
    extends ConsumerState<CalibrationPromptWidget> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final bike = widget.bike;
    final connected = ref.watch(connectionHandlerProvider(bike.id)) ==
        SDBluetoothConnectionState.connected;
    // The live stream, not the notifier's memory of it: the offer must go away
    // the moment the rider rides off, and only this card rebuilds for it.
    final speed = ref.watch(bikeSpeedProvider(bike.id)).value ?? 0;
    if (_dismissed ||
        bike.bootSignature != null ||
        !connected ||
        speed > 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      key: const ValueKey('calibrationPrompt'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: SDSurface.card,
          border: Border.all(color: SDSurface.border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Calibrate power-cycle detection',
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: SDSurface.text, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'The app measures your bike one time, so it knows a power cycle '
              'from a lost connection. You switch the bike off and on again.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: SDSurface.muted, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('calibrationPromptLater'),
                  onPressed: () => setState(() => _dismissed = true),
                  style: TextButton.styleFrom(foregroundColor: SDSurface.muted),
                  child: const Text('Later'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: const ValueKey('calibrationPromptStart'),
                  onPressed: () => showCalibration(context, bike.id),
                  style: TextButton.styleFrom(
                      foregroundColor: const Color(0xff4A80F0)),
                  child: const Text('Calibrate'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The read-only line where the Background Lock card used to be: what the app
/// keeps doing while the rider is not looking, and what it cannot do.
class BackgroundStatusWidget extends ConsumerWidget {
  const BackgroundStatusWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = backgroundStatusFor(bike,
        hasService: _hasBackgroundService,
        notificationsBlocked: ref.watch(notificationsBlockedProvider));
    final text =
        backgroundStatusText(status, bike, hasService: _hasBackgroundService);
    if (text == null) {
      return const SizedBox.shrink();
    }
    // Marked only where the rider can act. A platform that has no service at
    // all gets a plain line: a warning nobody can answer is noise.
    final actionable =
        status == BackgroundStatus.degraded && _hasBackgroundService;
    return Padding(
      padding: const EdgeInsets.only(top: 20.0, left: 8.0, right: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (actionable) ...[
            const Icon(Icons.warning_amber_rounded,
                size: 16, color: SDSurface.label),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                    color: SDSurface.muted,
                    fontSize: 12,
                  ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
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
    // The card picks the level a ride starts on while its pin is on startup —
    // app state, so it works with the bike away. See
    // [EnhancedLightControlWidget].
    final selecting = bike.pinAssist == PinState.startup;
    // The level a ride starts on, or null while nothing pins one.
    final startupAssist = selecting ? bike.startupAssist : null;

    return ControlCard(
      colorIndex: bike.color,
      title: "Assist",
      titleIcon: Icons.autorenew,
      showSwitch: false,
      enabled: connected || selecting,
      caption:
          selecting ? 'Tap the assist level the bike starts with' : null,
      trailing: EnhancedLockWidget(
        pin: bike.pinAssist,
        degraded: _pinDegradedNow(ref, bike.pinAssist),
        onTap: bikeControl.cycleAssistPin,
        tooltip: pinTooltip(bike.pinAssist, 'assist'),
      ),
      body: SelectorBody(
        colorIndex: bike.color,
        layout: SelectorLayout.segments,
        // The underline alone is too small to say what it means.
        caption: startupAssist == null ? null : 'Starts at $startupAssist',
        items: [
          for (var level = 0; level <= 4; level++)
            SelectorItem(
              keyValue: 'assistChip:$level',
              label: '$level',
              tooltip: 'Select assist $level',
              selected: bike.assist == level,
              pinned: level == startupAssist,
              onTap: selecting
                  ? () => bikeControl.setStartupAssist(level)
                  : (connected ? () => bikeControl.setAssist(level) : null),
            ),
        ],
      ),
    );
  }
}

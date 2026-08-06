import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show KeepAliveLink;
import 'package:permission_handler/permission_handler.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:superduper/db.dart';
import 'package:superduper/edit_bike.dart' as edit;
import 'package:superduper/models.dart';
import 'package:superduper/repository.dart';
import 'package:superduper/utils/logger.dart';
import 'package:superduper/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

export 'package:superduper/models.dart';

part 'bike.g.dart';

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
  bool _writing = false;

  /// The wire mode byte the app currently asserts on the bike while the CH
  /// dynamic mode is active. The phone is the speed limiter there, so this is
  /// the source of truth for which of [chWireLow]/[chWireHigh] the bike is
  /// supposed to be in — the read-back cannot tell them apart.
  int _dynamicWire = chWireLow;

  /// When the last speed sample arrived, for the staleness watchdog.
  DateTime? _lastSpeedAt;

  /// Whether the one-off work of entering dynamic mode has been done for the
  /// mode that is active now, so rebuilds and repeated writes do not re-run it
  /// (and do not ask for the notification permission again).
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

  @override
  BikeState build(String id) {
    ref.onDispose(() {
      _updateTimer?.cancel();
      _updateDebounce?.cancel();
      _speedSub?.cancel();
      _speedSub = null;
      // The link itself is already released by riverpod here (both on rebuild
      // and on dispose); only drop the stale handle.
      _keepAlive = null;
    });
    _resetReadTimer();
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
    _syncKeepAlive(bike);
    if (bike.isDynamicMode) {
      // Dynamic mode is usually already active on the first build: it is the
      // default mode of a CH bike and it comes back from bikes.json that way.
      // Its setup must not depend on a transition through writeStateData.
      _enterDynamicMode();
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
    // would leave the dynamic mode blind for the rest of the session.
    _speedSub?.cancel();
    _speedSub = ref
        .read(connectionHandlerProvider(id).notifier)
        .speedStream
        .listen(_onSpeedSample);
    // The bike may have power-cycled into its own default mode, so re-assert
    // ours. Every region needs this, not just the dynamic mode: without it a
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
    log.d(SDLogger.bike, 'Reconnected, re-asserting state');
    await updateStateDataNow(force: true);
  }

  /// Rides the CH dynamic mode: US Class 2 below the threshold, EPAC above it.
  /// Writes only when the threshold is crossed, never per sample.
  void _onSpeedSample(double speedKmh) {
    _lastSpeedAt = DateTime.now();
    if (!state.isDynamicMode) {
      return;
    }
    // A sample can still be delivered right after a disconnect, so gate on the
    // connection as it is now instead of trusting the sample.
    if (!_isConnected) {
      return;
    }
    var newWire = chDynamicWire(speedKmh, _dynamicWire);
    if (newWire == _dynamicWire) {
      return;
    }
    log.d(SDLogger.bike,
        'Dynamic mode at $speedKmh km/h: wire $_dynamicWire -> $newWire');
    _dynamicWire = newWire;
    // Same settings, new wire byte: writeStateData takes it from _dynamicWire.
    writeStateData(state);
  }

  /// The bike stops streaming ride data on its own; without speed samples the
  /// dynamic mode is blind, so re-arm the stream when it dries up.
  void _checkSpeedStream() {
    if (!state.isDynamicMode || !_isConnected) {
      return;
    }
    var last = _lastSpeedAt;
    if (last != null && DateTime.now().difference(last) < _speedTimeout) {
      return;
    }
    log.d(SDLogger.bike, 'No speed samples, requesting ride data again');
    unawaited(_requestRideData());
  }

  /// Dynamic mode and Background Lock both need the control loop to keep
  /// running when the UI is gone.
  void _syncKeepAlive(BikeState bike) {
    var needed = bike.modeLock || bike.isDynamicMode;
    if (needed == (_keepAlive != null)) {
      return;
    }
    if (needed) {
      log.d(SDLogger.bike, 'Keeping bike $id alive without UI');
      _keepAlive = ref.keepAlive();
    } else {
      log.d(SDLogger.bike, 'Releasing bike $id');
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
      _checkSpeedStream();
      if (_writing) {
        return;
      }
      updateStateData();
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
      log.w(SDLogger.bike, 'Ignoring non settings read: $data');
      return;
    }
    var newState = state.updateFromData(data);
    var healWire = _needsWireHeal(data);
    if (healWire) {
      log.d(SDLogger.bike,
          'Bike is on wire ${data[5]}, re-asserting mode ${state.mode}');
    }
    if (newState == state && !force && !healWire) {
      return;
    }
    log.d(SDLogger.bike, 'State update from data: $data');
    if (state.lightLocked && state.light != newState.light) {
      newState = newState.copyWith(light: state.light);
    }

    if (state.modeLocked && state.mode != newState.mode) {
      newState = newState.copyWith(mode: state.mode);
    }

    if (state.assistLocked && state.assist != newState.assist) {
      newState = newState.copyWith(assist: state.assist);
    }
    writeStateData(newState);
  }

  /// True when the bike has to be pushed back onto the packet the app asserts,
  /// even though the read-back reports no mode change.
  ///
  /// In the CH region the app owns the mode, because CH modes are the app's own
  /// composition of the bike's profiles. Two cases the mode comparison in
  /// [updateStateDataNow] cannot see:
  ///
  /// * a wire byte the CH read-back does not map ([chMapsToMode]). The state
  ///   keeps the mode it had, so nothing looks wrong, while the bike is on
  ///   whatever profile that byte selects (e.g. EU 35/45 km/h from wire 5/6).
  ///   The bike itself has no mode button — an unmapped byte means another app
  ///   (the official one writes any of 0-7) set it, or the controller powered
  ///   up in a different mode. True for every CH mode, dynamic or not.
  /// * dynamic mode sitting on the other of [chWireLow]/[chWireHigh] than the
  ///   app asserted, i.e. a lost transition write: models.dart maps both bytes
  ///   to dynamic mode.
  ///
  /// A mapped byte is otherwise the rider's: [chWireUsOffroad] and
  /// [chWireOffroad] are followed to off-road, [chWireLow]/[chWireHigh] follow
  /// the sticky dynamic-mode rules.
  bool _needsWireHeal(List<int> data) {
    if (state.region != BikeRegion.ch || data.length <= 5) {
      return false;
    }
    var raw = data[5];
    if (!chMapsToMode(raw)) {
      return true;
    }
    if (state.isDynamicMode && (raw == chWireLow || raw == chWireHigh)) {
      return raw != _dynamicWire;
    }
    return false;
  }

  void writeStateData(BikeState newState, {saveToBike = true}) async {
    if (_deleted) {
      // The record is gone; saving would put it back into bikes.json.
      return;
    }
    _resetDebounce();
    if (state.id != newState.id) {
      throw Exception('Bike id mismatch');
    }
    var wasDynamic = state.isDynamicMode;
    var entering = newState.isDynamicMode && !wasDynamic;
    var leaving = wasDynamic && !newState.isDynamicMode;
    // Dynamic mode always starts on the low (throttle) wire byte; the next
    // speed sample moves it up if the rider is already fast.
    var wire = entering ? chWireLow : _dynamicWire;
    if (leaving && state.modeLockAuto) {
      // Only the lock dynamic mode turned on is turned off again.
      newState = newState.copyWith(modeLock: false, modeLockAuto: false);
    }
    var status = ref.read(connectionHandlerProvider(state.id));
    if (saveToBike) {
      if (status != SDBluetoothConnectionState.connected) {
        return;
      }
      _writing = true;
      final repo = ref.read(connectionHandlerProvider(state.id).notifier);
      final data = newState.toWriteData(belowThreshold: wire == chWireLow);
      try {
        // Through the queue: a settings write is a select-then-write sequence
        // on the same characteristic reads and ride data requests use.
        await _withRegister(() => repo.write(data));
      } catch (e) {
        // A latched _writing would silence the poll for good, and with it the
        // dynamic-mode self-heal that is meant to recover from exactly this.
        _writing = false;
        log.e(SDLogger.bike, 'Error writing to bike', e);
        return;
      }
      // The bike may have been deleted while the write was in flight; saving
      // now would bring it back.
      if (!ref.mounted || _deleted) {
        return;
      }
      log.d(SDLogger.bike, 'Wrote data to bike: $data');
    }
    _dynamicWire = wire;
    var lockChanged = state.modeLock != newState.modeLock;
    ref.read(bikesDBProvider.notifier).saveBike(newState);
    state = newState;
    _syncKeepAlive(newState);
    if (lockChanged) {
      _syncBackgroundLock(newState.modeLock);
    }
    if (leaving) {
      _dynamicActive = false;
    }
    if (entering) {
      _enterDynamicMode();
    }
    updateStateData();
  }

  /// One-off work for dynamic mode being active: ask for the speed stream it
  /// lives on, and put the phone in a state where it keeps running. Idempotent —
  /// both a transition and a fresh build land here.
  void _enterDynamicMode() {
    if (_dynamicActive) {
      return;
    }
    _dynamicActive = true;
    log.d(SDLogger.bike, 'Dynamic mode is active');
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

  /// Dynamic mode has to keep limiting the speed while the phone sits in a
  /// pocket, which on Android needs the foreground service. A lock the rider
  /// turned on themselves is left alone (and never auto-disabled).
  Future<void> _enableAutoBackgroundLock() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (!ref.mounted || !state.isDynamicMode || state.modeLock) {
      return;
    }
    await Permission.notification.request();
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    if (!ref.mounted || !state.isDynamicMode || state.modeLock) {
      return;
    }
    log.i(SDLogger.bike, 'Dynamic mode: turning Background Lock on');
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
    log.d(SDLogger.bike, 'Toggling light: ${!state.light}');
    writeStateData(state.copyWith(light: !state.light));
  }

  void toggleMode() async {
    log.d(SDLogger.bike, 'Toggling mode to: ${state.nextMode}');
    writeStateData(state.copyWith(mode: state.nextMode));
  }

  void toggleAssist() async {
    final newAssist = (state.assist + 1) % 5;
    log.d(SDLogger.bike, 'Toggling assist to: $newAssist');
    writeStateData(state.copyWith(assist: newAssist));
  }

  void toggleLightLocked() async {
    log.d(SDLogger.bike, 'Toggling light lock: ${!state.lightLocked}');
    writeStateData(state.copyWith(lightLocked: !state.lightLocked),
        saveToBike: false);
  }

  void toggleModeLocked() async {
    log.d(SDLogger.bike, 'Toggling mode lock: ${!state.modeLocked}');
    writeStateData(state.copyWith(modeLocked: !state.modeLocked),
        saveToBike: false);
  }

  void toggleAssistLocked() async {
    log.d(SDLogger.bike, 'Toggling assist lock: ${!state.assistLocked}');
    writeStateData(state.copyWith(assistLocked: !state.assistLocked),
        saveToBike: false);
  }

  void toggleBackgroundLock() async {
    log.d(SDLogger.bike, 'Toggling background lock: ${!state.modeLock}');
    // The rider took over the lock, so dynamic mode stops managing it.
    writeStateData(
        state.copyWith(modeLock: !state.modeLock, modeLockAuto: false),
        saveToBike: false);
  }

  /// Deletes the bike and tears this notifier down with it.
  ///
  /// Removing the record is not enough: dynamic mode and the Background Lock
  /// hold the notifier alive without any UI, so its poll, its speed samples and
  /// the foreground service would all keep running — and the first write would
  /// call [BikesDB.saveBike], putting the deleted bike straight back into
  /// bikes.json.
  void deleteStateData(BikeState bike) {
    log.i(SDLogger.bike, 'Deleting bike: ${bike.name}');
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
          backgroundColor: Colors.black,
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // Modern App Bar without bike name
              SliverAppBar(
                backgroundColor: Colors.black,
                pinned: true,
                expandedHeight: 60, // Reduced height without the title
                stretch: true,
                leading: IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(51), // 0.2 opacity
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
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
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(51), // 0.2 opacity
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.settings, color: Colors.white),
                    ),
                    onPressed: () {
                      edit.show(context, bike);
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: Container(color: Colors.black),
                  collapseMode: CollapseMode.pin,
                  stretchModes: const [],
                ),
              ),

              // Bike name as a header
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
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
                                    color: Colors.white,
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
                        child: ElevatedButton.icon(
                          onPressed: () {
                            final Uri url = Uri.parse(
                                'https://github.com/blopker/superduper/?tab=readme-ov-file#getting-started');
                            launchUrl(url,
                                mode: LaunchMode.externalApplication);
                          },
                          icon: const Icon(Icons.help_outline, size: 18),
                          label: Text(
                            "HELP & TIPS",
                            style:
                                Theme.of(context).textTheme.bodySmall!.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xff4A80F0)
                                .withAlpha(51), // 0.2 opacity
                            foregroundColor: const Color(0xff4A80F0),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
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
    } else if (connectionStatus == SDBluetoothConnectionState.disconnected &&
        !isScanning) {
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
          : () {
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
  const EnhancedLockWidget(
      {super.key,
      required this.locked,
      required this.onTap,
      this.activeColor = Colors.white});

  final bool locked;
  final VoidCallback onTap;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        color: locked
            ? Colors.grey.withAlpha(38)
            : Colors.transparent, // 0.15 opacity
        borderRadius: BorderRadius.circular(50),
      ),
      child: IconButton(
        iconSize: 24,
        padding: const EdgeInsets.all(12),
        onPressed: onTap,
        icon: Icon(
          locked ? Icons.lock : Icons.lock_open,
          color: locked ? activeColor : Colors.grey[600],
        ),
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(50),
          ),
        ),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          child: DiscoverCard(
            colorIndex: bike.color,
            title: "Light",
            metric: bike.light ? "On" : "Off",
            titleIcon: bike.light ? Icons.lightbulb : Icons.lightbulb_outline,
            selected: bike.light,
            onTap: () {
              bikeControl.toggleLight();
            },
          ),
        ),
        EnhancedLockWidget(
          locked: bike.lightLocked,
          onTap: bikeControl.toggleLightLocked,
          activeColor: Colors.white,
        )
      ],
    );
  }
}

class EnhancedModeControlWidget extends ConsumerWidget {
  const EnhancedModeControlWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    var bikeControl = ref.watch(bikeProvider(bike.id).notifier);
    final bool isActiveMode = bike.viewMode != '1';

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: DiscoverCard(
                colorIndex: bike.color,
                title: "Mode",
                metric: "${bike.viewMode}/${bike.modeCount}",
                titleIcon: Icons.electric_bike,
                selected: isActiveMode,
                onTap: () {
                  bikeControl.toggleMode();
                },
              ),
            ),
            EnhancedLockWidget(
              locked: bike.modeLocked,
              onTap: bikeControl.toggleModeLocked,
              activeColor: Colors.white,
            )
          ],
        ),
        // iOS has no background service, so the dynamic mode's speed switching
        // only runs while the app is in the foreground.
        if (Platform.isIOS && bike.isDynamicMode)
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
        DiscoverCard(
          title: "Background Lock",
          metric: bike.modeLock ? "On" : "Off",
          titleIcon: Icons.phonelink_lock,
          selected: bike.modeLock,
          colorIndex: bike.color,
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
    final bool isActiveAssist = bike.assist > 0;

    return Row(
      children: [
        Expanded(
          child: DiscoverCard(
            colorIndex: bike.color,
            title: "Assist",
            metric: "${bike.assist}/4",
            titleIcon: Icons.autorenew,
            selected: isActiveAssist,
            onTap: () {
              bikeControl.toggleAssist();
            },
          ),
        ),
        EnhancedLockWidget(
          locked: bike.assistLocked,
          onTap: bikeControl.toggleAssistLocked,
          activeColor: Colors.white,
        )
      ],
    );
  }
}

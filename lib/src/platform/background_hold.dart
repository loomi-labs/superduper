import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:superduper/src/diagnostics/debug_log.dart';

/// Keeps the app process alive while the BLE link must stay up in the
/// background. A switching custom mode needs it for its speed limit
/// (`speedLimit` true). The street-legal preference needs it to see the next
/// restart of the bike (`speedLimit` false). Android runs a foreground
/// service with a notification. Other platforms have no hold.
abstract interface class BackgroundHoldGateway {
  Future<void> setHeld(
    bool held, {
    bool speedLimit = true,
    DebugLog log = const NoopDebugLog(),
  });
}

final class NoopBackgroundHoldGateway implements BackgroundHoldGateway {
  const new();

  @override
  Future<void> setHeld(
    bool held, {
    bool speedLimit = true,
    DebugLog log = const NoopDebugLog(),
  }) async {}
}

@pragma('vm:entry-point')
void backgroundHoldCallback() {
  FlutterForegroundTask.setTaskHandler(_HoldTaskHandler());
}

final class _HoldTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// The calls of the foreground task plugin that the hold uses. A test gives
/// its own implementation.
abstract interface class ForegroundServiceApi {
  void init();
  Future<NotificationPermission> checkNotificationPermission();
  Future<NotificationPermission> requestNotificationPermission();
  Future<bool> get isIgnoringBatteryOptimizations;
  Future<bool> requestIgnoreBatteryOptimization();
  Future<bool> get isRunningService;
  Future<void> updateService({
    required String notificationTitle,
    required String notificationText,
  });
  Future<ServiceRequestResult> startService({
    required String notificationTitle,
    required String notificationText,
  });
  Future<void> stopService();
}

final class _PluginForegroundServiceApi implements ForegroundServiceApi {
  const new();

  @override
  void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'notification_channel_id',
        channelName: 'Background service',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );
  }

  @override
  Future<NotificationPermission> checkNotificationPermission() =>
      FlutterForegroundTask.checkNotificationPermission();

  @override
  Future<NotificationPermission> requestNotificationPermission() =>
      FlutterForegroundTask.requestNotificationPermission();

  @override
  Future<bool> get isIgnoringBatteryOptimizations =>
      FlutterForegroundTask.isIgnoringBatteryOptimizations;

  @override
  Future<bool> requestIgnoreBatteryOptimization() =>
      FlutterForegroundTask.requestIgnoreBatteryOptimization();

  @override
  Future<bool> get isRunningService => FlutterForegroundTask.isRunningService;

  @override
  Future<void> updateService({
    required String notificationTitle,
    required String notificationText,
  }) async {
    await FlutterForegroundTask.updateService(
      notificationTitle: notificationTitle,
      notificationText: notificationText,
    );
  }

  @override
  Future<ServiceRequestResult> startService({
    required String notificationTitle,
    required String notificationText,
  }) => FlutterForegroundTask.startService(
    serviceTypes: [ForegroundServiceTypes.connectedDevice],
    serviceId: AndroidForegroundServiceHold.serviceId,
    notificationTitle: notificationTitle,
    notificationText: notificationText,
    callback: backgroundHoldCallback,
  );

  @override
  Future<void> stopService() async {
    await FlutterForegroundTask.stopService();
  }
}

final class AndroidForegroundServiceHold implements BackgroundHoldGateway {
  new([this._api = const _PluginForegroundServiceApi()]);

  final ForegroundServiceApi _api;

  static const serviceId = 256;
  static const speedLimitTitle = 'Superduper CH is holding your speed limit';
  static const linkTitle = 'Superduper CH keeps the link to your bike';
  static const _text = 'Tap to return to the app';
  var _initialized = false;
  var _held = false;
  var _speedLimit = true;
  Future<void> _tail = Future.value();

  @override
  Future<void> setHeld(
    bool held, {
    bool speedLimit = true,
    DebugLog log = const NoopDebugLog(),
  }) {
    final previous = _tail;
    final next = previous.then((_) => _apply(held, speedLimit, log));
    _tail = next.catchError((Object _) {});
    return next;
  }

  String _title(bool speedLimit) => speedLimit ? speedLimitTitle : linkTitle;

  Future<void> _apply(bool held, bool speedLimit, DebugLog debugLog) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    if (held && _held) {
      // The reason changed while the service runs: the text follows it.
      if (speedLimit != _speedLimit) {
        _speedLimit = speedLimit;
        debugLog.log('hold', 'update text: speedLimit=$speedLimit');
        if (await _api.isRunningService) {
          await _api.updateService(
            notificationTitle: _title(speedLimit),
            notificationText: _text,
          );
        }
      }
      return;
    }
    if (held == _held) {
      return;
    }
    debugLog.log(
      'hold',
      'service ${held ? 'start' : 'stop'} requested: '
          'speedLimit=$speedLimit',
    );
    _held = held;
    _speedLimit = speedLimit;
    _init();
    if (held) {
      try {
        await _start(speedLimit, debugLog);
        debugLog.log('hold', 'service started');
      } on Object catch (error) {
        debugLog.log('hold', 'service start failed: $error');
        // A service that runs after the failed start needs a stop later. Else
        // a later call starts the service again.
        _held = await _serviceRuns();
        rethrow;
      }
    } else if (await _api.isRunningService) {
      await _api.stopService();
      debugLog.log('hold', 'service stopped');
    } else {
      debugLog.log('hold', 'stop requested, but no service runs');
    }
  }

  Future<bool> _serviceRuns() async {
    try {
      return await _api.isRunningService;
    } on Object {
      return false;
    }
  }

  /// The permission steps never stop the start. Without an activity the
  /// plugin throws, and the app asks for nothing.
  Future<void> _start(bool speedLimit, DebugLog debugLog) async {
    try {
      final permission = await _api.checkNotificationPermission();
      debugLog.log('hold', 'notification permission: ${permission.name}');
      if (permission != NotificationPermission.granted) {
        final asked = await _api.requestNotificationPermission();
        debugLog.log('hold', 'notification permission asked: ${asked.name}');
      }
    } on Object {
      debugLog.log('hold', 'notification permission: unknown (no activity)');
    }
    try {
      final ignoring = await _api.isIgnoringBatteryOptimizations;
      debugLog.log('hold', 'battery optimization ignored: $ignoring');
      if (!ignoring) {
        final asked = await _api.requestIgnoreBatteryOptimization();
        debugLog.log('hold', 'battery optimization asked: $asked');
      }
    } on Object {
      debugLog.log('hold', 'battery optimization: not asked (no activity)');
    }
    if (await _api.isRunningService) {
      // The service of an earlier start runs: its title follows the reason.
      debugLog.log('hold', 'a service runs already: update its text');
      await _api.updateService(
        notificationTitle: _title(speedLimit),
        notificationText: _text,
      );
    } else {
      final result = await _api.startService(
        notificationTitle: _title(speedLimit),
        notificationText: _text,
      );
      if (result case ServiceRequestFailure(:final error)) {
        throw StateError('The foreground service did not start: $error');
      }
    }
  }

  void _init() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _api.init();
  }
}

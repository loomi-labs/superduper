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

final class AndroidForegroundServiceHold implements BackgroundHoldGateway {
  new();

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
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.updateService(
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
        // A later call starts the service again.
        debugLog.log('hold', 'service start failed: $error');
        _held = false;
        rethrow;
      }
    } else if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
      debugLog.log('hold', 'service stopped');
    } else {
      debugLog.log('hold', 'stop requested, but no service runs');
    }
  }

  Future<void> _start(bool speedLimit, DebugLog debugLog) async {
    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    debugLog.log('hold', 'notification permission: ${permission.name}');
    if (permission != NotificationPermission.granted) {
      final asked = await FlutterForegroundTask.requestNotificationPermission();
      debugLog.log('hold', 'notification permission asked: ${asked.name}');
    }
    final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    debugLog.log('hold', 'battery optimization ignored: $ignoring');
    if (!ignoring) {
      final asked =
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      debugLog.log('hold', 'battery optimization asked: $asked');
    }
    if (await FlutterForegroundTask.isRunningService) {
      // The service of an earlier start runs: its title follows the reason.
      debugLog.log('hold', 'a service runs already: update its text');
      await FlutterForegroundTask.updateService(
        notificationTitle: _title(speedLimit),
        notificationText: _text,
      );
    } else {
      final result = await FlutterForegroundTask.startService(
        serviceTypes: [ForegroundServiceTypes.connectedDevice],
        serviceId: serviceId,
        notificationTitle: _title(speedLimit),
        notificationText: _text,
        callback: backgroundHoldCallback,
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
}

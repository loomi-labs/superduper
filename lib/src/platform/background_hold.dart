import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps the app process alive while a dynamic custom mode needs the BLE link
/// in the background. Android runs a foreground service with a notification.
/// Other platforms have no hold.
abstract interface class BackgroundHoldGateway {
  Future<void> setHeld(bool held);
}

final class NoopBackgroundHoldGateway implements BackgroundHoldGateway {
  const new();

  @override
  Future<void> setHeld(bool held) async {}
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
  var _initialized = false;
  var _held = false;
  Future<void> _tail = Future.value();

  @override
  Future<void> setHeld(bool held) {
    final previous = _tail;
    final next = previous.then((_) => _apply(held));
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _apply(bool held) async {
    if (defaultTargetPlatform != TargetPlatform.android || held == _held) {
      return;
    }
    _held = held;
    _init();
    if (held) {
      final permission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      if (!await FlutterForegroundTask.isRunningService) {
        final result = await FlutterForegroundTask.startService(
          serviceTypes: [ForegroundServiceTypes.connectedDevice],
          serviceId: serviceId,
          notificationTitle: 'Superduper CH is holding your speed limit',
          notificationText: 'Tap to return to the app',
          callback: backgroundHoldCallback,
        );
        if (result case ServiceRequestFailure(:final error)) {
          _held = false;
          throw StateError('The foreground service did not start: $error');
        }
      }
    } else if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
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

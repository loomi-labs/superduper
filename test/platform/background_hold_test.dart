import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/platform/background_hold.dart';

import '../support/recording_debug_log.dart';

final class _FakeForegroundServiceApi implements ForegroundServiceApi {
  bool permissionThrows = false;
  bool batteryThrows = false;
  bool startThrows = false;

  /// The service runs although the start call threw.
  bool runsDespiteStartError = false;
  bool running = false;
  int starts = 0;
  int stops = 0;
  int permissionRequests = 0;
  int batteryRequests = 0;

  @override
  void init() {}

  @override
  Future<NotificationPermission> checkNotificationPermission() async {
    if (permissionThrows) {
      throw StateError('no activity');
    }
    return NotificationPermission.granted;
  }

  @override
  Future<NotificationPermission> requestNotificationPermission() async {
    permissionRequests++;
    return NotificationPermission.granted;
  }

  @override
  Future<bool> get isIgnoringBatteryOptimizations async {
    if (batteryThrows) {
      throw StateError('no activity');
    }
    return true;
  }

  @override
  Future<bool> requestIgnoreBatteryOptimization() async {
    batteryRequests++;
    return true;
  }

  @override
  Future<bool> get isRunningService async => running;

  @override
  Future<void> updateService({
    required String notificationTitle,
    required String notificationText,
  }) async {}

  @override
  Future<ServiceRequestResult> startService({
    required String notificationTitle,
    required String notificationText,
  }) async {
    starts++;
    if (startThrows) {
      running = runsDespiteStartError;
      throw StateError('start failed');
    }
    running = true;
    return const ServiceRequestSuccess();
  }

  @override
  Future<void> stopService() async {
    stops++;
    running = false;
  }
}

void main() {
  late _FakeForegroundServiceApi api;
  late AndroidForegroundServiceHold hold;
  late RecordingDebugLog log;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    api = _FakeForegroundServiceApi();
    hold = AndroidForegroundServiceHold(api);
    log = RecordingDebugLog();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('a permission check that throws does not stop the start', () async {
    api
      ..permissionThrows = true
      ..batteryThrows = true;

    await hold.setHeld(true, log: log);

    expect(api.running, isTrue);
    expect(api.permissionRequests, 0);
    expect(api.batteryRequests, 0);
    expect(
      log.has('hold', 'notification permission: unknown (no activity)'),
      isTrue,
    );
    expect(
      log.has('hold', 'battery optimization: not asked (no activity)'),
      isTrue,
    );
    expect(log.has('hold', 'service started'), isTrue);
  });

  test('a start that throws while a service runs sets held', () async {
    api
      ..startThrows = true
      ..runsDespiteStartError = true;

    await expectLater(hold.setHeld(true, log: log), throwsStateError);
    await hold.setHeld(false, log: log);

    expect(api.stops, 1);
    expect(api.running, isFalse);
  });

  test('a start that throws with no service running is tried again', () async {
    api.startThrows = true;
    await expectLater(hold.setHeld(true, log: log), throwsStateError);

    api.startThrows = false;
    await hold.setHeld(true, log: log);

    expect(api.starts, 2);
    expect(api.running, isTrue);
  });
}

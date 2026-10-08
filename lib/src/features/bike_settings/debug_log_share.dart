import 'dart:ui';

import 'package:share_plus/share_plus.dart';
import 'package:superduper/src/app_services.dart';
import 'package:superduper/src/ble/active_bike_coordinator.dart';
import 'package:superduper/src/ble/bike_session.dart';
import 'package:superduper/src/domain/bike.dart';
import 'package:superduper/src/platform/report_exporter.dart';

/// The text above the log lines: app, privacy note and bike.
String createDebugLogHeader({
  required SavedBike saved,
  required ReportMetadata metadata,
  DateTime? generatedAt,
}) {
  final generated = (generatedAt ?? DateTime.now()).toUtc();
  final bike = saved.bike;
  return '''SUPERDUPER CH DEBUG LOG
Generated: ${generated.toIso8601String()}
App: ${metadata.appVersion} (${metadata.buildNumber})
Platform: ${metadata.platform} ${metadata.operatingSystemVersion.replaceAll('\n', ' ')}
PRIVACY: This file holds the BLE identifier and the module serial of the bike. Read it before you share it.
BLE identifier: ${bike.deviceId}
Module serial: ${bike.moduleSerial ?? 'Unavailable'}
Name: ${bike.displayName}''';
}

/// The state of the live session, for the line below the header.
String describeLiveState(ActiveBikeState state, String deviceId) {
  if (state is! ActiveBikeSessionStatus ||
      state.bike.bike.deviceId != deviceId) {
    return 'Live state: no session for this bike';
  }
  final rideMode = state.rideMode;
  return 'Live state: session=${BikeSession.describeState(state.sessionState)} '
      'selection=${rideMode.selection.value} '
      'hold=${rideMode.needsBackgroundHold.value} '
      'holdsSpeedLimit=${rideMode.holdsSpeedLimit.value} '
      'parkedMinutesLeft=${rideMode.parkedMinutesLeft.value} '
      'lock=${state.session.streetLegalLocked.value}';
}

/// Builds the merged log file and opens the share sheet. Returns false when
/// sharing is unavailable.
Future<bool> shareDebugLog({
  required AppServices services,
  required SavedBike saved,
  Rect? origin,
}) async {
  final metadata = await ReportMetadata.fromPlatform();
  final file = await services.debugLogStore.exportFor(
    saved,
    header: createDebugLogHeader(saved: saved, metadata: metadata),
    liveState: describeLiveState(
      services.activeBikeCoordinator.state.value,
      saved.bike.deviceId,
    ),
  );
  final stamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp('[-:]'), '')
      .replaceAll('.', '-');
  final result = await ReportExporter.shareFile(
    file,
    filename: 'superduper-debug-log-$stamp.txt',
    subject: 'Superduper CH debug log',
    message:
        'Debug log of one bike, exported from Superduper CH. The attached '
        'text file holds the BLE identifier and the module serial of the bike.',
    sharePositionOrigin: origin,
  );
  return result.status != ShareResultStatus.unavailable;
}

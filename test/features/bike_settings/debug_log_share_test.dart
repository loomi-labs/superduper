import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/domain/bike.dart';
import 'package:superduper/src/features/bike_settings/debug_log_share.dart';
import 'package:superduper/src/platform/report_exporter.dart';

void main() {
  test('the header names the app, the privacy note and the bike', () {
    final saved = SavedBike(
      bike: Bike(
        deviceId: 'AA:BB',
        displayName: 'Commuter',
        protocol: BikeProtocolVersion.v1,
        region: BikeRegion.ch,
        color: BikeColor.values.first,
        sortOrder: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        lastConnectedAt: null,
        moduleSerial: '00112233aabbccdd',
      ),
      setOnConnect: const SetOnConnect(),
    );

    final header = createDebugLogHeader(
      saved: saved,
      metadata: const ReportMetadata(
        appVersion: '1.2.3',
        buildNumber: '45',
        platform: 'android',
        operatingSystemVersion: 'Android 15',
      ),
      generatedAt: DateTime.utc(2026, 10, 8, 12),
    );

    expect(header, startsWith('SUPERDUPER CH DEBUG LOG'));
    expect(header, contains('Generated: 2026-10-08T12:00:00.000Z'));
    expect(header, contains('App: 1.2.3 (45)'));
    expect(header, contains('BLE identifier: AA:BB'));
    expect(header, contains('Module serial: 00112233aabbccdd'));
    expect(header, contains('PRIVACY:'));
  });
}

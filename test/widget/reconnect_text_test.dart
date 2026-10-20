import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/ble/bike_session.dart';
import 'package:superduper/src/features/hardware_test/bike_hardware_test_controller.dart';
import 'package:superduper/src/widgets/bike_session_presentation.dart';

void main() {
  const failure = BikeSessionTransportFailure('The bike disconnected.');

  test('a session that waits for the bike says it connects by itself', () {
    final presentation = BikeSessionPresentation.from(
      const SessionReconnecting(
        attempt: 5,
        retryAfter: Duration(minutes: 5),
        failure: failure,
        waitsForBike: true,
      ),
    );

    expect(presentation.detail, endsWith(' Connects when the bike is on.'));
    expect(presentation.detail, isNot(contains('Trying again')));
  });

  test('a session with a direct attempt names the delay', () {
    final presentation = BikeSessionPresentation.from(
      const SessionReconnecting(
        attempt: 2,
        retryAfter: Duration(seconds: 5),
        failure: failure,
      ),
    );

    expect(presentation.detail, endsWith(' Trying again in 5 seconds.'));
  });

  test('the hardware test text follows the wait', () {
    expect(
      reconnectDetail(
        waitsForBike: true,
        retryAfter: const Duration(minutes: 5),
      ),
      'No connection yet. Connects when the bike is on.',
    );
    expect(
      reconnectDetail(
        waitsForBike: false,
        retryAfter: const Duration(seconds: 5),
      ),
      'No connection yet. Trying again in 5 seconds.',
    );
  });
}

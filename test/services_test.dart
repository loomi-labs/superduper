import 'package:flutter_test/flutter_test.dart';

import 'package:superduper/services.dart';

void main() {
  group('parseSpeedNotification', () {
    test('parses little-endian uint16 / 100 km/h', () {
      // 0x03E8 = 1000 -> 10.0 km/h
      expect(parseSpeedNotification([2, 1, 0xE8, 0x03, 0, 0]), 10.0);
      // 0x0902 = 2306 -> 23.06 km/h
      expect(parseSpeedNotification([2, 1, 0x02, 0x09]), 23.06);
    });

    test('returns null for non-speed packets', () {
      expect(parseSpeedNotification([3, 0, 0, 0, 1, 4]), null);
      expect(parseSpeedNotification([2, 2, 0x10, 0x00]), null);
    });

    test('returns null for short packets', () {
      expect(parseSpeedNotification([2, 1, 5]), null);
      expect(parseSpeedNotification([]), null);
    });
  });
}

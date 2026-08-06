import 'package:flutter_test/flutter_test.dart';

import 'package:superduper/edit_bike.dart';
import 'package:superduper/models.dart';

BikeState bike({required int mode, required BikeRegion region}) => BikeState(
    id: 'test',
    mode: mode,
    light: false,
    assist: 0,
    name: 'test',
    region: region);

/// The raw mode byte a bike in this mode would be written.
int wireOf({required int mode, required BikeRegion region}) =>
    bike(mode: mode, region: region).toWriteData()[4];

void main() {
  group('clampModeToRegion', () {
    test('keeps a mode the region still has', () {
      expect(clampModeToRegion(0, BikeRegion.ch), 0);
      expect(clampModeToRegion(2, BikeRegion.ch), 2);
      expect(clampModeToRegion(3, BikeRegion.eu), 3);
      expect(clampModeToRegion(3, BikeRegion.us), 3);
    });

    test('falls back to the last mode when the region dropped it', () {
      // EU/US mode 4 (index 3) does not exist on a 3-mode CH bike, so it lands
      // on CH mode 3 (index 2).
      expect(clampModeToRegion(3, BikeRegion.ch), 2);
    });

    test('the fallback preserves the mode the bike was actually in', () {
      // Why the *last* mode and not the first: both ends of the range are
      // off-road and write the very same wire byte, so the rider keeps the
      // mode they were riding.
      expect(wireOf(mode: 3, region: BikeRegion.eu), chWireOffroad);
      expect(wireOf(mode: clampModeToRegion(3, BikeRegion.ch), region: BikeRegion.ch),
          chWireOffroad);
    });

    test('the fallback does not land the rider in the CH dynamic mode', () {
      // Clamping to index 0 would be a CH bike's dynamic mode, which hands the
      // phone-side limiter and auto Background Lock to a mere settings save.
      final clamped = clampModeToRegion(3, BikeRegion.ch);
      expect(bike(mode: clamped, region: BikeRegion.ch).isDynamicMode, isFalse);
    });

    test('treats a region-less bike as having four modes', () {
      expect(clampModeToRegion(3, null), 3);
    });

    test('agrees with the region mode counts', () {
      for (final region in BikeRegion.values) {
        for (var mode = 0; mode < region.modeCount; mode++) {
          expect(clampModeToRegion(mode, region), mode);
        }
        expect(
            clampModeToRegion(region.modeCount, region), region.modeCount - 1,
            reason: 'an out-of-range mode falls back to the last one');
      }
    });
  });
}

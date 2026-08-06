import 'package:flutter_test/flutter_test.dart';

import 'package:superduper/models.dart';

BikeState bike({int mode = 0, BikeRegion? region}) => BikeState(
    id: 'test', mode: mode, light: false, assist: 0, name: 'test', region: region);

// Settings register data: [3, 0, assist, walk, light, mode, ...]
List<int> data({int mode = 0, int light = 0, int assist = 0}) =>
    [3, 0, assist, 0, light, mode, 0, 0, 0, 0];

void main() {
  test('CH region serializes to 202 and round-trips', () {
    final b = bike(region: BikeRegion.ch);
    final decoded = BikeState.fromJson(b.toJson());
    expect(decoded.region, BikeRegion.ch);
    expect(b.toJson()['region'], 202);
  });

  test('new bikes default to CH region', () {
    expect(BikeState.defaultState('id').region, BikeRegion.ch);
  });

  test('modeLockAuto persists, defaults to false, tolerates legacy files', () {
    expect(BikeState.defaultState('id').modeLockAuto, isFalse);
    final auto = bike().copyWith(modeLock: true, modeLockAuto: true);
    expect(BikeState.fromJson(auto.toJson()).modeLockAuto, isTrue,
        reason: 'whose lock it is must survive an app restart');
    // bikes.json written by an older build has no such key.
    final legacy = Map<String, Object?>.from(auto.toJson())
      ..remove('modeLockAuto');
    expect(BikeState.fromJson(legacy).modeLockAuto, isFalse);
  });

  test('mode count is 3 for CH, 4 otherwise', () {
    expect(BikeRegion.us.modeCount, 4);
    expect(BikeRegion.eu.modeCount, 4);
    expect(BikeRegion.ch.modeCount, 3);
    expect(bike(region: BikeRegion.ch).modeCount, 3);
    expect(bike(region: null).modeCount, 4);
  });

  test('nextMode wraps at the region mode count', () {
    expect(bike(mode: 2, region: BikeRegion.ch).nextMode, 0);
    expect(bike(mode: 1, region: BikeRegion.ch).nextMode, 2);
    expect(bike(mode: 3, region: BikeRegion.eu).nextMode, 0);
    expect(bike(mode: 3, region: null).nextMode, 0);
  });

  group('toWriteData wire bytes', () {
    int wireOf(BikeState b, {bool belowThreshold = true}) =>
        b.toWriteData(belowThreshold: belowThreshold)[4];

    test('US writes raw mode', () {
      expect(wireOf(bike(mode: 2, region: BikeRegion.us)), 2);
    });

    test('EU writes mode + 4', () {
      expect(wireOf(bike(mode: 2, region: BikeRegion.eu)), 6);
    });

    test('CH mode 2 writes US Class 2 (wire 1)', () {
      expect(wireOf(bike(mode: 1, region: BikeRegion.ch)), 1);
    });

    test('CH mode 3 writes EU off-road (wire 7)', () {
      expect(wireOf(bike(mode: 2, region: BikeRegion.ch)), 7);
    });

    test('CH dynamic mode writes wire 1 below threshold, wire 4 above', () {
      final dynamicBike = bike(mode: 0, region: BikeRegion.ch);
      expect(wireOf(dynamicBike, belowThreshold: true), 1);
      expect(wireOf(dynamicBike, belowThreshold: false), 4);
    });
  });

  group('updateFromData read-back', () {
    test('CH: wire 4 (EPAC) maps to dynamic mode', () {
      expect(
          bike(mode: 1, region: BikeRegion.ch).updateFromData(data(mode: 4)).mode,
          0);
    });

    test('CH: wire 7 and wire 3 map to off-road', () {
      expect(
          bike(mode: 0, region: BikeRegion.ch).updateFromData(data(mode: 7)).mode,
          2);
      expect(
          bike(mode: 0, region: BikeRegion.ch).updateFromData(data(mode: 3)).mode,
          2);
    });

    test('CH: wire 1 is sticky — stays dynamic when dynamic is active', () {
      expect(
          bike(mode: 0, region: BikeRegion.ch).updateFromData(data(mode: 1)).mode,
          0);
    });

    test('CH: wire 1 maps to mode 2 when dynamic is not active', () {
      expect(
          bike(mode: 1, region: BikeRegion.ch).updateFromData(data(mode: 1)).mode,
          1);
      expect(
          bike(mode: 2, region: BikeRegion.ch).updateFromData(data(mode: 1)).mode,
          1);
    });

    test('CH: unknown wire byte keeps the current mode', () {
      expect(
          bike(mode: 2, region: BikeRegion.ch).updateFromData(data(mode: 5)).mode,
          2);
    });

    test('CH: region is kept, not re-guessed', () {
      expect(
          bike(mode: 0, region: BikeRegion.ch)
              .updateFromData(data(mode: 1))
              .region,
          BikeRegion.ch);
    });

    test('legacy null region still guesses from wire byte', () {
      final fromEu = bike(region: null).updateFromData(data(mode: 5));
      expect(fromEu.region, BikeRegion.eu);
      expect(fromEu.mode, 1);
      final fromUs = bike(region: null).updateFromData(data(mode: 2));
      expect(fromUs.region, BikeRegion.us);
      expect(fromUs.mode, 2);
    });
  });

  group('chMapsToMode', () {
    test('maps exactly the wire bytes the CH read-back understands', () {
      for (var wire in [
        chWireLow,
        chWireUsOffroad,
        chWireHigh,
        chWireOffroad
      ]) {
        expect(chMapsToMode(wire), isTrue, reason: 'wire $wire is a CH mode');
      }
      // 5 (35 km/h) and 6 (45 km/h) are reachable with the bike's own mode
      // button but have no CH mode, so the app has to re-assert its own.
      for (var wire in [0, 2, 5, 6, 8]) {
        expect(chMapsToMode(wire), isFalse, reason: 'wire $wire is unmapped');
      }
    });

    test('agrees with what updateFromData can see', () {
      for (var wire = 0; wire < 8; wire++) {
        final before = bike(mode: 2, region: BikeRegion.ch);
        final unchanged = before.updateFromData(data(mode: wire)).mode == 2 &&
            wire != chWireUsOffroad &&
            wire != chWireOffroad;
        expect(chMapsToMode(wire), !unchanged,
            reason: 'wire $wire: a byte that leaves the mode untouched is '
                'exactly a byte the read-back cannot map');
      }
    });
  });

  group('isSettingsPacket', () {
    test('accepts a settings register read-back', () {
      expect(isSettingsPacket(data(mode: 4, light: 1, assist: 2)), isTrue);
    });

    test('rejects ride data frames and truncated reads', () {
      // Ride data: [2, 1, speed_lo, speed_hi, ...].
      expect(isSettingsPacket([2, 1, 4, 0, 1, 3, 0, 0, 0, 0]), isFalse);
      expect(isSettingsPacket([2, 3, 0, 0, 0, 0, 0, 0, 0, 0]), isFalse);
      // Right header, but not enough bytes to hold a mode.
      expect(isSettingsPacket([3, 0, 0, 0, 0]), isFalse);
      expect(isSettingsPacket([]), isFalse);
    });
  });

  group('chDynamicWire', () {
    test('keeps current wire when stopped', () {
      expect(chDynamicWire(0, chWireHigh), chWireHigh);
      expect(chDynamicWire(-1, chWireLow), chWireLow);
    });

    test('below/at threshold rides US Class 2', () {
      expect(chDynamicWire(10, chWireHigh), chWireLow);
      expect(chDynamicWire(chSpeedThresholdKmh, chWireHigh), chWireLow);
    });

    test('above threshold rides EPAC', () {
      expect(chDynamicWire(23.1, chWireLow), chWireHigh);
      expect(chDynamicWire(40, chWireLow), chWireHigh);
    });
  });

  test('isDynamicMode only for CH mode 1', () {
    expect(bike(mode: 0, region: BikeRegion.ch).isDynamicMode, true);
    expect(bike(mode: 1, region: BikeRegion.ch).isDynamicMode, false);
    expect(bike(mode: 0, region: BikeRegion.eu).isDynamicMode, false);
    expect(bike(mode: 0, region: null).isDynamicMode, false);
  });
}

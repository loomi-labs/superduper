import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/domain/bike.dart';
import 'package:superduper/src/domain/ride_modes.dart';

void main() {
  const twentyFiveThrottle = CustomMode(
    id: 'a',
    name: '25',
    limitKmh: 25,
    throttle: true,
  );
  const thirtyTwoThrottle = CustomMode(
    id: 'b',
    name: '32',
    limitKmh: 32,
    throttle: true,
  );
  const fortyFive = CustomMode(id: 'c', name: '45', limitKmh: 45);
  const thirtyFiveThrottle = CustomMode(
    id: 'd',
    name: '35t',
    limitKmh: 35,
    throttle: true,
  );

  group('profile table', () {
    test('wire is the index', () {
      for (var wire = 0; wire <= 7; wire++) {
        expect(firmwareProfiles[wire].wire, wire);
      }
    });

    test('labels use mph for US and km/h elsewhere', () {
      expect(profileByWire(1).label(BikeRegion.us), '20 mph + throttle');
      expect(profileByWire(4).label(BikeRegion.ch), '25 km/h');
      expect(profileByWire(7).label(BikeRegion.eu), 'OFFROAD');
    });

    test('native wires per region', () {
      expect(nativeWiresFor(BikeRegion.us), [0, 1, 2, 3]);
      expect(nativeWiresFor(BikeRegion.eu), [4, 5, 6, 7]);
      expect(nativeWiresFor(BikeRegion.ch), [7]);
    });
  });

  group('base and cap', () {
    test('25 km/h with throttle rides TOUR below and EPAC above', () {
      expect(wirePairFor(twentyFiveThrottle, BikeRegion.ch), (base: 1, cap: 4));
    });

    test('32 km/h with throttle is an exact match', () {
      expect(wirePairFor(thirtyTwoThrottle, BikeRegion.ch), (base: 1, cap: 1));
      expect(isStaticCustomMode(thirtyTwoThrottle, BikeRegion.ch), isTrue);
    });

    test('45 km/h without throttle prefers the own bank', () {
      expect(wirePairFor(fortyFive, BikeRegion.eu), (base: 6, cap: 6));
      expect(wirePairFor(fortyFive, BikeRegion.us), (base: 2, cap: 2));
    });

    test('throttle above 32 km/h rides offroad below and caps at MODE 2', () {
      expect(wirePairFor(thirtyFiveThrottle, BikeRegion.ch), (base: 7, cap: 5));
      expect(entryWireFor(thirtyFiveThrottle, BikeRegion.ch), 5);
      expect(unwatchedWireFor(thirtyFiveThrottle, BikeRegion.ch), 5);
      expect(unwatchedWireFor(twentyFiveThrottle, BikeRegion.ch), isNull);
    });

    test('limit is clamped to the slider range', () {
      const tooLow = CustomMode(id: 'e', name: 'x', limitKmh: 10);
      expect(tooLow.effectiveLimitKmh, customLimitMin);
    });
  });

  group('dynamicWireFor', () {
    test('holds the current wire while stopped', () {
      expect(dynamicWireFor(twentyFiveThrottle, 0, 4, BikeRegion.ch), 4);
      expect(dynamicWireFor(twentyFiveThrottle, 0, 1, BikeRegion.ch), 1);
    });

    test('switches up above the limit, not at it', () {
      expect(dynamicWireFor(twentyFiveThrottle, 25, 1, BikeRegion.ch), 1);
      expect(dynamicWireFor(twentyFiveThrottle, 25.1, 1, BikeRegion.ch), 4);
    });

    test('switches down only below the hysteresis band', () {
      expect(dynamicWireFor(twentyFiveThrottle, 23.5, 4, BikeRegion.ch), 4);
      expect(dynamicWireFor(twentyFiveThrottle, 22.9, 4, BikeRegion.ch), 1);
    });

    test('a foreign current wire reads as the entry wire', () {
      expect(dynamicWireFor(twentyFiveThrottle, 10, 7, BikeRegion.ch), 1);
    });

    test('a static mode always answers its single wire', () {
      expect(dynamicWireFor(thirtyTwoThrottle, 40, 1, BikeRegion.ch), 1);
    });
  });

  group('selection', () {
    test('CH lists custom modes first, then OFFROAD', () {
      final modes = selectableRideModes(
        region: BikeRegion.ch,
        customModes: const [twentyFiveThrottle],
      );
      expect(modes, [
        const CustomRideMode(twentyFiveThrottle),
        const NativeRideMode(7),
      ]);
    });

    test('initial wire and assertsWire', () {
      expect(initialWireFor(const NativeRideMode(2), BikeRegion.us), 2);
      expect(
        initialWireFor(const CustomRideMode(thirtyFiveThrottle), BikeRegion.ch),
        5,
      );
      expect(
        assertsWire(const CustomRideMode(twentyFiveThrottle), 4, BikeRegion.ch),
        isTrue,
      );
      expect(
        assertsWire(const CustomRideMode(twentyFiveThrottle), 7, BikeRegion.ch),
        isFalse,
      );
    });

    test('names and units', () {
      expect(customModeNameFor(25, BikeRegion.ch), '25 km/h');
      expect(customModeNameFor(32, BikeRegion.us), '20 mph');
      expect(mphFromKmh(45), 28);
      expect(kmhFromMph(16), 26);
    });
  });

  group('set on connect resolution', () {
    final bike = SavedBike(
      bike: Bike(
        deviceId: 'd',
        displayName: 'n',
        protocol: BikeProtocolVersion.v1,
        region: BikeRegion.ch,
        color: BikeColor.royalHorizon,
        sortOrder: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        lastConnectedAt: null,
      ),
      setOnConnect: const SetOnConnect(
        mode: CustomModeRef(seededChModeId),
        assist: 2,
      ),
      customModes: const [seededChMode],
    );

    test('custom ref resolves to the entry wire and the mode', () {
      final resolved = resolveSetOnConnect(bike);
      expect(resolved.patch, const BikeControlPatch(mode: 1, assist: 2));
      expect(resolved.rideMode, seededChMode);
    });

    test('dangling custom ref leaves mode unset', () {
      final resolved = resolveSetOnConnect(
        SavedBike(
          bike: bike.bike,
          setOnConnect: const SetOnConnect(mode: CustomModeRef('gone')),
        ),
      );
      expect(resolved.patch.mode, isNull);
      expect(resolved.rideMode, isNull);
    });

    test('native ref resolves to its wire', () {
      final resolved = resolveSetOnConnect(
        SavedBike(
          bike: bike.bike,
          setOnConnect: const SetOnConnect(mode: NativeModeRef(7)),
        ),
      );
      expect(resolved.patch, const BikeControlPatch(mode: 7));
    });
  });
}

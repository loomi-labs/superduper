import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/domain/bike.dart';

void main() {
  group('BikeControlValues', () {
    test('defines the supported control values per protocol', () {
      expect(BikeControlValues.modesFor(BikeProtocolVersion.v1), [
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      ]);
      expect(BikeControlValues.modesFor(BikeProtocolVersion.v2), [0, 1, 2, 3]);
      expect(BikeControlValues.assistLevels, [0, 1, 2, 3, 4]);
    });

    test('recognizes valid modes and assist levels', () {
      const v1 = BikeProtocolVersion.v1;
      const v2 = BikeProtocolVersion.v2;
      expect(BikeControlValues.isValidMode(0, v1), isTrue);
      expect(BikeControlValues.isValidMode(7, v1), isTrue);
      expect(BikeControlValues.isValidMode(-1, v1), isFalse);
      expect(BikeControlValues.isValidMode(8, v1), isFalse);
      expect(BikeControlValues.isValidMode(3, v2), isTrue);
      expect(BikeControlValues.isValidMode(4, v2), isFalse);

      expect(BikeControlValues.isValidAssist(0), isTrue);
      expect(BikeControlValues.isValidAssist(4), isTrue);
      expect(BikeControlValues.isValidAssist(-1), isFalse);
      expect(BikeControlValues.isValidAssist(5), isFalse);
    });

    test('rejects values outside the supported ranges', () {
      expect(
        () => BikeControlValues.validateMode(-1, BikeProtocolVersion.v1),
        throwsRangeError,
      );
      expect(
        () => BikeControlValues.validateMode(8, BikeProtocolVersion.v1),
        throwsRangeError,
      );
      expect(
        () => BikeControlValues.validateMode(4, BikeProtocolVersion.v2),
        throwsRangeError,
      );
      expect(() => BikeControlValues.validateAssist(-1), throwsRangeError);
      expect(() => BikeControlValues.validateAssist(5), throwsRangeError);
    });
  });
  group('stock mode', () {
    SavedBike saved({
      BikeProtocolVersion protocol = BikeProtocolVersion.v1,
      BikeRegion? region = BikeRegion.ch,
      int? stockMode,
    }) {
      return SavedBike(
        bike: Bike(
          deviceId: 'bike',
          displayName: 'Bike',
          protocol: protocol,
          region: region,
          color: BikeColor.royalHorizon,
          sortOrder: 0,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          lastConnectedAt: null,
        ),
        setOnConnect: const SetOnConnect(),
        streetLegalStockMode: stockMode,
      );
    }

    test('the default follows the region and the protocol', () {
      expect(defaultStockMode(BikeRegion.eu, BikeProtocolVersion.v1), 4);
      expect(defaultStockMode(BikeRegion.ch, BikeProtocolVersion.v1), 4);
      expect(defaultStockMode(BikeRegion.us, BikeProtocolVersion.v1), 0);
      expect(defaultStockMode(null, BikeProtocolVersion.v1), 0);
      expect(defaultStockMode(null, BikeProtocolVersion.v2), 0);
    });

    test('a stored stock mode wins over the default', () {
      expect(resolveStockMode(saved(stockMode: 5)), 5);
      expect(resolveStockMode(saved()), 4);
      expect(resolveStockMode(saved(region: BikeRegion.us)), 0);
    });

    test('a stored wire that the protocol does not offer gives the default', () {
      expect(
        resolveStockMode(
          saved(protocol: BikeProtocolVersion.v2, region: null, stockMode: 6),
        ),
        0,
      );
    });
  });
}

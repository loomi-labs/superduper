import 'package:flutter_test/flutter_test.dart';

import 'package:superduper/models.dart';

BikeState bike(
        {int mode = 0,
        BikeRegion? region,
        String modeId = '',
        List<CustomMode> customModes = const []}) =>
    BikeState(
        id: 'test',
        legacyMode: mode,
        modeId: modeId,
        customModes: customModes,
        light: false,
        assist: 0,
        name: 'test',
        region: region);

// Settings register data: [3, 0, assist, walk, light, mode, ...]
List<int> data({int mode = 0, int light = 0, int assist = 0}) =>
    [3, 0, assist, 0, light, mode, 0, 0, 0, 0];

/// Bikes.json as an older build wrote it: an integer mode, no selection.
Map<String, Object?> legacyJson({int? mode = 0, int? region}) => {
      'id': 'test',
      'mode': ?mode,
      'modeLocked': false,
      'light': false,
      'lightLocked': false,
      'assist': 0,
      'assistLocked': false,
      'name': 'test',
      'region': ?region,
      'modeLock': false,
      'modeLockAuto': false,
      'color': 0,
    };

const tour30 =
    CustomMode(id: 'c1', name: 'Tour 30', limitKmh: 30, throttle: true);
// An exact firmware match (US Class 3 / EU MODE 3): base == cap, never switches.
const sport45 = CustomMode(id: 'c2', name: 'Sport 45', limitKmh: 45);
// Base wire 2, cap wire 5 — a pair that shares no wire with tour30's.
const fast40 = CustomMode(id: 'c3', name: 'Fast 40', limitKmh: 40);

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

  test('a saved Background Lock is dropped, not refused', () {
    // The rider who had it on gets the service back wherever it was doing
    // something, because it now follows the locks and the switching modes. A
    // file that still names it must decode all the same: _readBikes drops a
    // bike it cannot read, and the next save deletes it from the file for good.
    final json = legacyJson()
      ..['modeLock'] = true
      ..['modeLockAuto'] = true;
    final b = BikeState.fromJson(json);
    expect(b.id, 'test');
    expect(b.toJson().containsKey('modeLock'), isFalse,
        reason: 'the field goes with the feature');
    expect(b.toJson().containsKey('modeLockAuto'), isFalse);
  });

  group('toWriteData', () {
    test('carries the wire byte the caller asks for', () {
      final b = bike(region: BikeRegion.ch).copyWith(light: true, assist: 3);
      expect(b.toWriteData(wire: chWireHigh),
          [0, 209, 1, 3, chWireHigh, 0, 0, 0, 0, 0]);
    });

    test('does not offset the wire by the region any more', () {
      // The app owns the mode: which profile a selection rides — and which half
      // of a switching mode's pair — is the controller's to say, not a region
      // table's.
      for (final region in [BikeRegion.us, BikeRegion.eu, BikeRegion.ch, null]) {
        for (var wire = 0; wire < 8; wire++) {
          expect(bike(region: region).toWriteData(wire: wire)[4], wire,
              reason: '$region wire $wire');
        }
      }
    });
  });

  group('updateFromData', () {
    test('adopts the rider-owned fields', () {
      final after = bike(region: BikeRegion.ch)
          .updateFromData(data(mode: 5, light: 1, assist: 3));
      expect(after.light, isTrue);
      expect(after.assist, 3);
    });

    test('never touches the selection of a bike that has a region', () {
      // A wire byte stopped being 1:1 with a mode: what the reported byte means
      // is wireVerdict's answer, and only the controller can ask it.
      for (final region in BikeRegion.values) {
        final b = bike(
                region: region,
                modeId: nativeModeId(chWireOffroad),
                customModes: [tour30])
            .copyWith(legacyMode: 2);
        for (var wire = 0; wire < 8; wire++) {
          final after = b.updateFromData(data(mode: wire));
          expect(after.modeId, b.modeId, reason: '$region wire $wire');
          expect(after.legacyMode, b.legacyMode, reason: '$region wire $wire');
          expect(after.region, region, reason: '$region is kept, not re-guessed');
        }
      }
    });

    test('a legacy bike guesses its region from the wire byte', () {
      expect(
          bike(region: null).updateFromData(data(mode: 5)).region, BikeRegion.eu);
      expect(
          bike(region: null).updateFromData(data(mode: 2)).region, BikeRegion.us);
    });

    test('a guessed region takes the selection into its own bank', () {
      // Until the guess, selectableModes answered with the US bank, so the
      // stored id can be one the guessed region cannot select at all.
      final eu = bike(region: null)
          .withSelectedMode('native:2')
          .updateFromData(data(mode: 5));
      expect(eu.region, BikeRegion.eu);
      expect(eu.selectedMode.id, 'native:6',
          reason: 'the same place in the new bank');
      expect(eu.legacyMode, 2, reason: 'and the legacy projection follows');
      final offroad = bike(region: null)
          .withSelectedMode('native:3')
          .updateFromData(data(mode: 5));
      expect(offroad.selectedMode.id, 'native:7');
      final us = bike(region: null)
          .withSelectedMode('native:3')
          .updateFromData(data(mode: 2));
      expect(us.region, BikeRegion.us);
      expect(us.selectedMode.id, 'native:3',
          reason: 'the US bank is where it already was');
    });

    test('a guessed region keeps a custom selection', () {
      final b = bike(region: null, customModes: [tour30])
          .withSelectedMode(tour30.id)
          .updateFromData(data(mode: 5));
      expect(b.region, BikeRegion.eu);
      expect(b.selectedMode.id, tour30.id,
          reason: 'a custom mode means the same thing in every region');
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

  group('CustomMode', () {
    test('round-trips through json', () {
      expect(CustomMode.fromJson(tour30.toJson()), tour30);
      expect(tour30.toJson(),
          {'id': 'c1', 'name': 'Tour 30', 'limitKmh': 30, 'throttle': true});
    });

    test('an absent throttle key reads as false', () {
      final m = CustomMode.fromJson(
          const {'id': 'c1', 'name': 'Tour 30', 'limitKmh': 30});
      expect(m.throttle, isFalse);
    });

    test('effectiveLimitKmh clamps to the slider range', () {
      expect(tour30.copyWith(limitKmh: 24).effectiveLimitKmh, customLimitMin);
      expect(tour30.copyWith(limitKmh: 46, throttle: false).effectiveLimitKmh,
          customLimitMax);
    });

    test('a throttle mode keeps a limit above 32 km/h', () {
      // Above 32 every profile with a throttle is unlimited, so the mode rides
      // an unlimited base and the app holds the limit. The limit itself stands.
      expect(tour30.copyWith(limitKmh: 40).effectiveLimitKmh, 40);
      expect(tour30.copyWith(limitKmh: 45).effectiveLimitKmh, customLimitMax);
      expect(tour30.copyWith(limitKmh: 46).effectiveLimitKmh, customLimitMax);
    });

    test('ids are unique', () {
      expect(newCustomModeId(), isNot(newCustomModeId()));
      expect(nativeWireOf(newCustomModeId()), isNull);
    });
  });

  group('native mode ids', () {
    test('address a mode by its wire byte', () {
      expect(nativeModeId(5), 'native:5');
      expect(nativeWireOf('native:5'), 5);
      expect(nativeWireOf('c1abc'), isNull);
      expect(nativeWireOf('native:x'), isNull);
    });
  });

  group('migrateBikeJson', () {
    test('CH dynamic mode becomes the seeded custom mode', () {
      final out = migrateBikeJson(legacyJson(mode: 0, region: 202));
      expect(out['modeId'], seededChModeId);
      expect(out['customModes'], [seededChMode.toJson()]);
      expect(seededChMode.limitKmh, 25);
      expect(seededChMode.throttle, isTrue);
    });

    test('the removed CH static mode maps to the same seeded mode', () {
      expect(migrateBikeJson(legacyJson(mode: 1, region: 202))['modeId'],
          seededChModeId);
    });

    test('CH off-road maps to the native off-road mode', () {
      expect(migrateBikeJson(legacyJson(mode: 2, region: 202))['modeId'],
          nativeModeId(chWireOffroad));
    });

    test('US modes map to their own wire byte', () {
      expect(migrateBikeJson(legacyJson(mode: 2, region: 200))['modeId'],
          nativeModeId(2));
    });

    test('EU modes map to the wire byte + 4', () {
      expect(migrateBikeJson(legacyJson(mode: 3, region: 201))['modeId'],
          nativeModeId(7));
    });

    test('a bike without a region migrates like a US one', () {
      expect(migrateBikeJson(legacyJson(mode: 1))['modeId'], nativeModeId(1));
    });

    test('an ancient file without a mode key migrates as mode 0', () {
      final out = migrateBikeJson(legacyJson(mode: null));
      expect(out['modeId'], nativeModeId(0));
      expect(out['mode'], 0, reason: 'an old build needs the key to parse');
      expect(migrateBikeJson(legacyJson(mode: null, region: 202))['modeId'],
          seededChModeId);
    });

    test('keeps a legacy mode int a downgrade can ride', () {
      expect(migrateBikeJson(legacyJson(mode: 1, region: 202))['mode'], 1);
    });

    test('clamps an out-of-range legacy mode in the output map', () {
      // An old build asserts mode <= 3 inside fromJson, and its _readBikes has
      // no per-entry catch: an unclamped 7 costs it every bike in the file.
      final out = migrateBikeJson(legacyJson(mode: 7, region: 200));
      expect(out['mode'], 3);
      expect(out['modeId'], nativeModeId(3));
      expect(BikeState.fromJson(legacyJson(mode: 7, region: 200)).legacyMode, 3);
    });

    test('is idempotent and never duplicates the seeded mode', () {
      final once = migrateBikeJson(legacyJson(mode: 0, region: 202));
      expect(migrateBikeJson(once), once);
      expect((migrateBikeJson(once)['customModes'] as List), hasLength(1));
    });

    test('does not re-seed an old CH file that already has the seeded mode',
        () {
      final out = migrateBikeJson({
        ...legacyJson(mode: 0, region: 202),
        'customModes': [seededChMode.toJson(), tour30.toJson()],
      });
      expect(out['customModes'], [seededChMode.toJson(), tour30.toJson()]);
      expect(out['modeId'], seededChModeId);
    });

    test('seeds a CH file whose custom modes are someone else\'s', () {
      final out = migrateBikeJson({
        ...legacyJson(mode: 0, region: 202),
        'customModes': [tour30.toJson()],
      });
      expect(out['customModes'], [seededChMode.toJson(), tour30.toJson()]);
    });

    test('passes a map that already has a selection through untouched', () {
      final already = {
        ...legacyJson(mode: 2, region: 200),
        'modeId': tour30.id,
        'customModes': [tour30.toJson()],
      };
      expect(migrateBikeJson(already), already);
    });

    test('seeds a CH bike that already has a selection', () {
      // Not only the old-shape path: a CH file whose custom modes were all
      // deleted has a dangling selection, and the bike has to land on a limit.
      final emptied = migrateBikeJson({
        ...legacyJson(mode: 0, region: 202),
        'modeId': seededChModeId,
        'customModes': <Object?>[],
      });
      expect(emptied['customModes'], [seededChMode.toJson()]);
      expect(emptied['modeId'], seededChModeId, reason: 'selection is kept');
      // Same for a map that has no customModes key at all.
      final noKey = migrateBikeJson(
          {...legacyJson(mode: 0, region: 202), 'modeId': 'c9'});
      expect(noKey['customModes'], [seededChMode.toJson()]);
      expect(noKey['modeId'], 'c9');
      // Once, not on every load.
      expect(migrateBikeJson(emptied), emptied);
    });

    test('a CH bike that has modes of its own keeps the built-in one deleted',
        () {
      // Deleting the built-in 25 km/h mode is legal as soon as the rider has a
      // mode of their own, and the sheet lets them. Re-seeding it here would
      // undo that on every single app start — and at index 0, which is what
      // fallbackMode picks, so it would quietly become the fallback too.
      final own = {
        ...legacyJson(mode: 0, region: 202),
        'modeId': tour30.id,
        'customModes': [tour30.toJson()],
      };
      expect(migrateBikeJson(own), own, reason: 'nothing to migrate');
      final b = BikeState.fromJson(own);
      expect(b.customModes, [tour30]);
      expect(b.fallbackMode, const CustomSelection(tour30));
    });

    test('leaves the custom modes of a non-CH bike alone', () {
      final us = migrateBikeJson({
        ...legacyJson(mode: 0, region: 200),
        'modeId': 'native:0',
        'customModes': <Object?>[],
      });
      expect(us['customModes'], isEmpty);
    });

    test('a CH bike loaded with no custom modes gets the seeded one', () {
      final b = BikeState.fromJson(
          {...legacyJson(mode: 0, region: 202), 'modeId': seededChModeId});
      expect(b.customModes, [seededChMode]);
      expect(b.selectedMode, const CustomSelection(seededChMode));
    });

    test('recovers a bike whose keys have the wrong type', () {
      // Anything but the expected type throws out of fromJson, and _readBikes
      // then drops the bike — the next save deletes it from the file for good.
      final b = BikeState.fromJson({
        ...legacyJson(mode: 0, region: 200),
        'mode': '1',
        'modeId': 5,
        'customModes': <String, Object?>{},
      });
      expect(b.id, 'test');
      expect(b.legacyMode, 0);
      expect(b.modeId, nativeModeId(0));
      expect(b.customModes, isEmpty);
    });

    test('seeds a CH bike whose custom modes are not a list', () {
      final out = migrateBikeJson(
          {...legacyJson(mode: 0, region: 202), 'customModes': 'nonsense'});
      expect(out['customModes'], [seededChMode.toJson()]);
    });

    test('seeds into a copy, not into the caller\'s typed list', () {
      final out = migrateBikeJson({
        ...legacyJson(mode: 0, region: 202),
        'customModes': <Map<String, String>>[],
      });
      expect(out['customModes'], [seededChMode.toJson()]);
    });

    test('runs on the way in, from an old bikes.json', () {
      final b = BikeState.fromJson(legacyJson(mode: 0, region: 202));
      expect(b.selectedMode.id, seededChModeId);
      expect(b.customModes, [seededChMode]);
    });
  });

  group('stale modeId reconciliation', () {
    Map<String, Object?> migrated(
            {required int? mode, int? region, required String modeId}) =>
        migrateBikeJson(
            {...legacyJson(mode: mode, region: region), 'modeId': modeId});

    test('a native id the legacy mode disagrees with is re-derived', () {
      // An interim build moved the legacy int on its own — cycling a mode,
      // following a read-back, saving the Edit sheet — while modeId stood
      // still. Trusting the id here would put the bike back into a mode the
      // rider left: an unlimited one, in the worst case.
      final out = migrated(
          mode: 1, region: 202, modeId: nativeModeId(chWireOffroad));
      expect(out['modeId'], seededChModeId,
          reason: 'the legacy int is what the rider was actually riding');
    });

    test('re-derives in every region', () {
      for (final (region, staleId, mode, want) in <(int?, String, int, String)>[
        (200, 'native:3', 1, 'native:1'),
        (200, 'native:0', 2, 'native:2'),
        (201, 'native:7', 0, 'native:4'),
        (201, 'native:4', 3, 'native:7'),
        (null, 'native:3', 0, 'native:0'),
        (202, 'native:7', 0, seededChModeId),
      ]) {
        expect(migrated(mode: mode, region: region, modeId: staleId)['modeId'],
            want,
            reason: 'region $region, $staleId with mode $mode');
      }
    });

    test('leaves a native id the legacy mode agrees with alone', () {
      for (final (region, id, mode) in <(int?, String, int)>[
        (200, 'native:2', 2),
        (201, 'native:6', 2),
        (202, 'native:7', 2),
        (null, 'native:1', 1),
        // Out of its own bank: the id dangles onto the region's fallback, whose
        // projection is 0 — so mode 0 is agreement, not divergence.
        (200, 'native:5', 0),
        (202, 'native:3', 0),
      ]) {
        expect(migrated(mode: mode, region: region, modeId: id)['modeId'], id,
            reason: 'region $region, $id with mode $mode');
      }
    });

    test('trusts a custom id whatever the legacy mode says', () {
      // Every custom selection projects onto the same mildest legacy mode, so
      // a disagreement there carries no information — a CH custom diverges by
      // design.
      final out = migrateBikeJson({
        ...legacyJson(mode: 2, region: 200),
        'modeId': tour30.id,
        'customModes': [tour30.toJson()],
      });
      expect(out['modeId'], tour30.id);
      expect(
          migrated(mode: 2, region: 202, modeId: seededChModeId)['modeId'],
          seededChModeId);
    });

    test('does not invent a selection without a legacy mode to derive from', () {
      // Both sides have to exist before they can disagree.
      expect(migrated(mode: null, region: 200, modeId: 'native:2')['modeId'],
          'native:2');
      expect(
          migrateBikeJson({
            ...legacyJson(mode: null, region: 200),
            'mode': 'nonsense',
            'modeId': 'native:2',
          })['modeId'],
          'native:2');
    });

    test('is idempotent', () {
      final once = migrated(mode: 1, region: 200, modeId: 'native:3');
      expect(migrateBikeJson(once), once);
      final ch = migrated(mode: 1, region: 202, modeId: 'native:7');
      expect(migrateBikeJson(ch), ch);
    });

    test('survives a full load', () {
      final b = BikeState.fromJson(
          {...legacyJson(mode: 1, region: 202), 'modeId': 'native:7'});
      expect(b.selectedMode, const CustomSelection(seededChMode),
          reason: 'not the off-road mode the stale id named');
      expect(b.needsSpeedSwitching, isTrue);
      final us = BikeState.fromJson(
          {...legacyJson(mode: 1, region: 200), 'modeId': 'native:3'});
      expect(us.selectedMode.id, 'native:1');
      expect(us.legacyMode, 1);
    });
  });

  group('json shape', () {
    test('keeps every key a downgraded build needs', () {
      final json = BikeState.defaultState('id').toJson();
      for (final key in ['id', 'mode', 'light', 'assist', 'name']) {
        expect(json.containsKey(key), isTrue, reason: '$key is required');
      }
      expect(json['mode'], isA<int>());
    });

    test('projects every selection onto a legacy mode a downgrade can ride',
        () {
      int legacyOf(BikeState b) => b.toJson()['mode']! as int;
      expect(
          legacyOf(bike(region: BikeRegion.ch, customModes: [seededChMode])
              .withSelectedMode(seededChModeId)),
          0);
      expect(
          legacyOf(bike(region: BikeRegion.ch)
              .withSelectedMode(nativeModeId(chWireOffroad))),
          2);
      expect(legacyOf(bike(region: BikeRegion.eu).withSelectedMode('native:6')),
          2);
      expect(
          legacyOf(bike(region: BikeRegion.us, customModes: [tour30])
              .withSelectedMode(tour30.id)),
          0);
    });

    test('a bike with custom modes round-trips', () {
      final b = bike(region: BikeRegion.ch, customModes: [seededChMode, tour30])
          .withSelectedMode(tour30.id);
      expect(BikeState.fromJson(b.toJson()), b);
    });
  });

  group('pin state', () {
    // A bike whose selection round-trips on its own, so a failure here is
    // about the pins and not about the mode migration.
    BikeState saved() =>
        bike(region: BikeRegion.ch, customModes: [seededChMode])
            .withSelectedMode(seededChModeId);

    test('a fresh bike pins nothing and has seen nothing', () {
      final b = BikeState.defaultState('id');
      expect(b.pinLight, PinState.open);
      expect(b.pinMode, PinState.open);
      expect(b.pinAssist, PinState.open);
      expect(b.startupLight, isNull);
      expect(b.startupModeId, isNull);
      expect(b.startupAssist, isNull);
      expect(b.lastSeen, isNull);
    });

    test('a saved padlock boolean becomes a locked pin', () {
      final json = legacyJson()
        ..['modeLocked'] = true
        ..['lightLocked'] = false
        ..['assistLocked'] = true;
      final b = BikeState.fromJson(json);
      expect(b.pinMode, PinState.locked, reason: 'a saved lock must survive');
      expect(b.pinLight, PinState.open);
      expect(b.pinAssist, PinState.locked);
    });

    test('a file with no padlock keys and no last read decodes to the defaults',
        () {
      final json = legacyJson()
        ..remove('modeLocked')
        ..remove('lightLocked')
        ..remove('assistLocked');
      expect(json.containsKey('lastSeen'), isFalse);
      final b = BikeState.fromJson(json);
      expect(b.pinMode, PinState.open);
      expect(b.pinLight, PinState.open);
      expect(b.pinAssist, PinState.open);
      expect(b.lastSeen, isNull);
    });

    test('every pin state survives a save', () {
      for (final pin in PinState.values) {
        final b =
            saved().copyWith(pinMode: pin, pinLight: pin, pinAssist: pin);
        final decoded = BikeState.fromJson(b.toJson());
        expect(decoded.pinMode, pin, reason: '$pin must survive a save');
        expect(decoded.pinLight, pin);
        expect(decoded.pinAssist, pin);
      }
    });

    test('an open or locked pin saves as a boolean, so a downgrade reads it',
        () {
      expect(saved().copyWith(pinMode: PinState.locked).toJson()['modeLocked'],
          isTrue);
      expect(saved().copyWith(pinMode: PinState.open).toJson()['modeLocked'],
          isFalse);
    });

    test('the pinned values and the last read survive a save', () {
      final b = saved().copyWith(
          startupLight: true,
          startupModeId: nativeModeId(2),
          startupAssist: 3,
          lastSeen: const LastSeen(assist: 1, light: false, wire: 4));
      expect(BikeState.fromJson(b.toJson()), b);
    });
  });

  group('boot signature', () {
    // A bike whose selection round-trips on its own, so a failure here is
    // about the signature and not about the mode migration.
    BikeState saved() =>
        bike(region: BikeRegion.ch, customModes: [seededChMode])
            .withSelectedMode(seededChModeId);

    test('a bike the app never calibrated has no boot signature', () {
      final json = legacyJson();
      expect(json.containsKey('bootSignature'), isFalse,
          reason: 'an old bikes.json has no such key');
      expect(BikeState.fromJson(json).bootSignature, isNull);
      expect(BikeState.defaultState('id').bootSignature, isNull);
    });

    test('a measured boot signature survives a save', () {
      final b = saved().copyWith(
          bootSignature: BootSignature(
              measuredAt: DateTime.utc(2026, 8, 11, 9, 30, 15),
              bootWire: 4,
              bootAssist: 0,
              preOffWire: 7,
              preOffAssist: 3));
      expect(BikeState.fromJson(b.toJson()), b);
    });

    test('a byte that came back persisted saves as none', () {
      // Null is the measurement the 2026-08-11 logs produced for assist: the
      // register reported the pre-off value, so the byte carries no boot news.
      final b = saved().copyWith(
          bootSignature: BootSignature(
              measuredAt: DateTime.utc(2026, 8, 11, 9, 30),
              bootWire: 4,
              bootAssist: null,
              preOffWire: 7,
              preOffAssist: 3));
      final decoded = BikeState.fromJson(b.toJson());
      expect(decoded, b);
      expect(decoded.bootSignature!.bootAssist, isNull);
      expect(decoded.bootSignature!.preOffAssist, 3,
          reason: 'the staged value stays for a re-audit');
    });

    test('a bike the app never calibrated has no boot light either', () {
      final json = legacyJson();
      expect(json.containsKey('bootLight'), isFalse,
          reason: 'an old bikes.json has no such key');
      expect(BikeState.fromJson(json).bootSignature, isNull);
    });

    test('a measured light byte survives a save', () {
      final b = saved().copyWith(
          bootSignature: BootSignature(
              measuredAt: DateTime.utc(2026, 8, 11, 9, 30, 15),
              bootWire: 4,
              bootAssist: 0,
              bootLight: true,
              preOffWire: 7,
              preOffAssist: 3));
      expect(BikeState.fromJson(b.toJson()), b);
    });

    test('an old signature with no light key decodes to a null one', () {
      // A signature saved before bootLight existed: the json has bootWire and
      // bootAssist but no bootLight key at all.
      final oldSignature = {
        'measuredAt': DateTime.utc(2026, 8, 11, 9, 30).toIso8601String(),
        'bootWire': 4,
        'bootAssist': 0,
        'preOffWire': 7,
        'preOffAssist': 3,
      };
      final json = Map<String, Object?>.from(saved().toJson())
        ..['bootSignature'] = oldSignature;
      final decoded = BikeState.fromJson(json);
      expect(decoded.bootSignature!.bootLight, isNull);
      expect(decoded.bootSignature!.bootWire, 4,
          reason: 'the other measured bytes are unaffected');
    });
  });

  group('BikeCapabilities', () {
    test('a bike the app never probed has no capabilities', () {
      final json = legacyJson();
      expect(json.containsKey('capabilities'), isFalse,
          reason: 'an old bikes.json has no such key');
      expect(BikeState.fromJson(json).capabilities, isNull);
      expect(BikeState.defaultState('id').capabilities, isNull);
    });

    test('a measured capability set survives a save', () {
      // withSelectedMode resolves modeId, exactly like the boot-signature
      // group's own saved() helper above: a failure here has to be about the
      // capabilities, not about the mode migration.
      final b = bike(region: BikeRegion.eu).withSelectedMode(nativeModeId(4)).copyWith(
          capabilities: BikeCapabilities(
              measuredAt: DateTime.utc(2026, 8, 11, 9, 30),
              acceptedWires: const [4, 5, 6, 7],
              acceptedAssist: const [0, 1, 2, 3, 4],
              lightWritable: true));
      expect(BikeState.fromJson(b.toJson()), b);
    });

    test('modeWritable and assistWritable need more than one accepted value',
        () {
      final one = BikeCapabilities(
          measuredAt: DateTime.utc(2026, 8, 11),
          acceptedWires: const [5],
          acceptedAssist: const [2],
          lightWritable: false);
      expect(one.modeWritable, isFalse);
      expect(one.assistWritable, isFalse);

      final many = one.copyWith(
          acceptedWires: const [4, 5], acceptedAssist: const [0, 2]);
      expect(many.modeWritable, isTrue);
      expect(many.assistWritable, isTrue);
    });

    test('detectedRegion reads a clean US or EU set', () {
      BikeCapabilities caps(List<int> wires) => BikeCapabilities(
          measuredAt: DateTime.utc(2026, 8, 11),
          acceptedWires: wires,
          acceptedAssist: const [],
          lightWritable: false);

      expect(caps([0, 1, 2, 3]).detectedRegion, BikeRegion.us);
      expect(caps([4, 5, 6, 7]).detectedRegion, BikeRegion.eu);
      expect(caps([]).detectedRegion, isNull, reason: 'nothing accepted');
      expect(caps([0, 1, 4]).detectedRegion, isNull, reason: 'mixed banks');
      expect(caps([0, 1, 2]).detectedRegion, isNull, reason: 'partial bank');
      expect(caps([0, 1, 2, 3, 4]).detectedRegion, isNull,
          reason: 'a full bank plus a stray wire is still not clean');
      expect(caps([7]).detectedRegion, isNot(BikeRegion.ch),
          reason: 'CH has no firmware bank of its own');
    });
  });

  group('mode selection', () {
    test('withSelectedMode keeps the legacy projection in sync', () {
      expect(
          bike(region: BikeRegion.us).withSelectedMode('native:2').legacyMode,
          2);
      expect(
          bike(region: BikeRegion.eu).withSelectedMode('native:6').legacyMode,
          2);
      expect(
          bike(region: BikeRegion.eu).withSelectedMode('native:4').legacyMode,
          0);
      expect(
          bike(region: BikeRegion.ch).withSelectedMode('native:7').legacyMode,
          2);
      expect(
          bike(region: BikeRegion.ch).withSelectedMode('native:3').legacyMode,
          0,
          reason: 'CH cannot select the US off-road mode, so this one dangles '
              'onto the seeded mode rather than onto an unlimited one');
      expect(bike(region: null).withSelectedMode('native:2').legacyMode, 2);
      for (final region in [BikeRegion.ch, BikeRegion.eu, BikeRegion.us]) {
        expect(
            bike(region: region, customModes: [tour30])
                .withSelectedMode(tour30.id)
                .legacyMode,
            0,
            reason: 'a custom mode projects onto the region mildest mode');
      }
    });

    test('the legacy projection covers the top of every bank', () {
      expect(
          bike(region: BikeRegion.us).withSelectedMode('native:3').legacyMode,
          3);
      expect(
          bike(region: BikeRegion.eu).withSelectedMode('native:7').legacyMode,
          3);
      expect(bike(region: null).withSelectedMode('native:3').legacyMode, 3);
    });

    test('an out-of-bank id projects onto the mode it resolves to', () {
      // Wire 5 is an EU mode: a US bike cannot select it, so it rides the
      // fallback — and the legacy int has to say the same thing, or a
      // downgraded build ends up on a different mode than this one.
      final us = bike(region: BikeRegion.us).withSelectedMode('native:5');
      expect(us.selectedMode.id, 'native:0');
      expect(us.legacyMode, 0);
      final eu = bike(region: BikeRegion.eu).withSelectedMode('native:2');
      expect(eu.selectedMode.id, 'native:4');
      expect(eu.legacyMode, 0);
      final ch = bike(region: BikeRegion.ch).withSelectedMode('gone');
      expect(ch.selectedMode.id, seededChModeId);
      expect(ch.legacyMode, 0, reason: 'a custom mode is the old dynamic mode');
    });

    test('selections compare by value, not by identity', () {
      // selectableModes allocates a fresh instance on every call.
      final us = bike(region: BikeRegion.us);
      expect(us.selectedMode, us.selectedMode);
      expect(NativeSelection(profileByWire(2)), NativeSelection(profileByWire(2)));
      expect(NativeSelection(profileByWire(2)),
          isNot(NativeSelection(profileByWire(3))));
      expect({NativeSelection(profileByWire(2)), NativeSelection(profileByWire(2))},
          hasLength(1));
      final custom = bike(region: BikeRegion.us, customModes: [tour30])
          .withSelectedMode(tour30.id);
      expect(custom.selectedMode, custom.selectedMode);
      expect(const CustomSelection(tour30), const CustomSelection(tour30));
      expect(const CustomSelection(tour30),
          isNot(const CustomSelection(seededChMode)));
      expect(const CustomSelection(tour30),
          isNot(NativeSelection(profileByWire(2))));
    });

    test('selectableModes are the region natives plus the customs', () {
      List<String> idsOf(BikeState b) =>
          b.selectableModes.map((m) => m.id).toList();
      expect(idsOf(bike(region: BikeRegion.us)),
          ['native:0', 'native:1', 'native:2', 'native:3']);
      expect(idsOf(bike(region: BikeRegion.eu)),
          ['native:4', 'native:5', 'native:6', 'native:7']);
      expect(idsOf(bike(region: null)), idsOf(bike(region: BikeRegion.us)),
          reason: 'a bike without a region behaves like a US one');
      expect(idsOf(bike(region: BikeRegion.us, customModes: [tour30])).last,
          tour30.id);
    });

    test('CH lists its own modes first and off-road last', () {
      // CH's only native mode is unlimited. Leading with it would put a fresh
      // CH bike one step from off-road in the cycling card, and would make the
      // limited mode render as the accented one — the reverse of the old card.
      final ch = bike(
          region: BikeRegion.ch, customModes: [seededChMode, tour30]);
      expect(ch.selectableModes.map((m) => m.id).toList(),
          [seededChModeId, tour30.id, 'native:7']);
      expect(ch.selectableModes.first, const CustomSelection(seededChMode),
          reason: 'a fresh CH bike sits at index 0, as its mode 0 always did');
      // Every other region still leads with its natives, mildest first.
      for (final region in [BikeRegion.us, BikeRegion.eu, null]) {
        expect(
            bike(region: region, customModes: [tour30]).selectableModes.first,
            isA<NativeSelection>(),
            reason: '$region');
      }
    });

    test('a dangling selection falls back per region', () {
      expect(bike(region: BikeRegion.us, modeId: 'gone').selectedMode.id,
          'native:0');
      expect(bike(region: BikeRegion.eu, modeId: 'gone').selectedMode.id,
          'native:4');
      expect(bike(region: null, modeId: 'gone').selectedMode.id, 'native:0');
      expect(
          bike(region: BikeRegion.ch,
                  modeId: 'gone',
                  customModes: [seededChMode, tour30])
              .selectedMode
              .id,
          seededChModeId,
          reason: 'CH has no limited native to fall back to');
      expect(bike(region: BikeRegion.ch, modeId: 'gone').selectedMode.id,
          seededChModeId,
          reason: 'a bike that lost its modes still has a limit');
    });

    test('a lost selection never grants a faster cap', () {
      // A CH bike with no custom mode left has no limited native to fall back
      // to, and off-road would be a silent upgrade to unlimited: the seeded
      // mode stands in instead. Off-road is only ever reached by picking it.
      final b = bike(region: BikeRegion.ch, modeId: 'dangling');
      expect(b.customModes, isEmpty);
      expect(b.selectedMode, const CustomSelection(seededChMode));
      expect(initialWireFor(b.selectedMode), chWireLow);
      expect(b.needsSpeedSwitching, isTrue);
    });

    test('an empty selection falls back too', () {
      expect(bike(region: BikeRegion.eu).modeId, isEmpty);
      expect(bike(region: BikeRegion.eu).selectedMode.id, 'native:4');
    });

    test('a selection that exists is resolved', () {
      final b = bike(region: BikeRegion.us, customModes: [tour30])
          .withSelectedMode(tour30.id);
      expect(b.selectedMode, isA<CustomSelection>());
      expect(b.selectedMode.name, 'Tour 30');
      expect(
          bike(region: BikeRegion.eu)
              .withSelectedMode('native:5')
              .selectedMode
              .name,
          'MODE 2');
    });

    test('label() renders the speed, not the firmware name', () {
      expect(
          bike(region: BikeRegion.eu).withSelectedMode('native:5').selectedMode
              .label(BikeRegion.eu),
          '35 km/h');
    });

    test('a custom selection labels itself with its own name, region unused',
        () {
      final selected =
          bike(region: BikeRegion.us, customModes: [tour30])
              .withSelectedMode(tour30.id)
              .selectedMode;
      expect(selected.label(BikeRegion.us), 'Tour 30');
      expect(selected.label(BikeRegion.eu), 'Tour 30');
      expect(selected.label(null), 'Tour 30');
    });
  });

  group('firmware profiles', () {
    test('are indexed by their wire byte', () {
      for (var wire = 0; wire < 8; wire++) {
        expect(profileByWire(wire).wire, wire);
      }
    });

    test('know their cap and whether they have a throttle', () {
      expect(profileByWire(chWireLow).capKmh, 32);
      expect(profileByWire(chWireLow).throttle, isTrue);
      expect(profileByWire(chWireHigh).capKmh, 25);
      expect(profileByWire(chWireHigh).throttle, isFalse);
      expect(profileByWire(chWireOffroad).unlimited, isTrue);
      expect(profileByWire(chWireUsOffroad).unlimited, isTrue);
    });
  });

  group('FirmwareProfile.label', () {
    test('EU natives read their km/h cap', () {
      expect(profileByWire(4).label(BikeRegion.eu), '25 km/h'); // EPAC
      expect(profileByWire(5).label(BikeRegion.eu), '35 km/h'); // MODE 2
      expect(profileByWire(6).label(BikeRegion.eu), '45 km/h'); // MODE 3
    });

    test('the EU off-road wire reads OFFROAD, not a speed', () {
      expect(profileByWire(7).label(BikeRegion.eu), 'OFFROAD');
    });

    test('US natives read their mph class limit, not a km/h conversion', () {
      expect(profileByWire(0).label(BikeRegion.us), '20 mph'); // ECO
      expect(profileByWire(1).label(BikeRegion.us), '20 mph + throttle'); // TOUR
      expect(profileByWire(2).label(BikeRegion.us), '28 mph'); // SPORT
    });

    test('the US off-road wire reads OFFROAD too', () {
      expect(profileByWire(3).label(BikeRegion.us), 'OFFROAD');
    });

    test('CH reads the EU bank in km/h', () {
      expect(profileByWire(4).label(BikeRegion.ch), '25 km/h');
      expect(profileByWire(7).label(BikeRegion.ch), 'OFFROAD');
    });

    test('a null region defaults to mph, matching selectableModes', () {
      expect(profileByWire(0).label(null), '20 mph');
    });
  });

  test('new bikes are seeded with the 25 km/h mode', () {
    final b = BikeState.defaultState('id');
    expect(b.region, BikeRegion.ch);
    expect(b.customModes, [seededChMode]);
    expect(b.selectedMode.id, seededChModeId);
    expect(b.legacyMode, 0);
  });

  test('autoReconnect persists, defaults to true, tolerates legacy files', () {
    expect(BikeState.defaultState('id').autoReconnect, isTrue);
    final off = bike(region: BikeRegion.ch).copyWith(autoReconnect: false);
    expect(BikeState.fromJson(off.toJson()).autoReconnect, isFalse);
    // bikes.json written by an older build has no such key.
    final legacy = Map<String, Object?>.from(off.toJson())
      ..remove('autoReconnect');
    expect(BikeState.fromJson(legacy).autoReconnect, isTrue);
  });

  group('profile lookup', () {
    // (limit, throttle, base wire, cap wire). Both functions clamp their input
    // the way effectiveLimitKmh does, so an out-of-range limit resolves like
    // the nearest one the UI can produce instead of onto an unlimited profile.
    const cases = <(int, bool, int, int)>[
      (30, true, 1, 4), // "Tour 30 + throttle": <=30 US Class 2, >30 EPAC
      (40, false, 2, 5), // "Fast 40": <=40 US Class 3 / EU3, >40 MODE 2
      (25, false, 4, 4),
      (25, true, 1, 4), // the seeded CH mode: the old wire pair
      (32, false, 0, 0),
      (32, true, 1, 1),
      (35, false, 5, 5),
      (35, true, 3, 5), // no capped throttle holds 35: US off-road below
      (45, false, 2, 2),
      (45, true, 3, 2),
      (26, false, 0, 4),
      (31, true, 1, 4),
      (33, false, 5, 0),
      (33, true, 3, 1), // over 32 with a throttle: off-road below, TOUR above
      (100, true, 3, 2), // clamped to 45, still off-road below
      (46, false, 2, 2),
      (24, false, 4, 4), // clamped up to the slider floor
    ];

    test('resolve a limit onto a base and a cap profile', () {
      for (final (limit, throttle, base, cap) in cases) {
        expect(baseProfileFor(limit, throttle).wire, base,
            reason: 'base of $limit km/h, throttle $throttle');
        expect(capProfileFor(limit, throttle: throttle).wire, cap,
            reason: 'cap of $limit km/h, throttle $throttle');
      }
    });

    test('the base holds the limit, the cap is at or below it', () {
      for (final (limit, throttle, _, _) in cases) {
        final wanted = limit.clamp(customLimitMin, customLimitMax);
        final base = baseProfileFor(limit, throttle);
        expect(base.capKmh ?? 1000, greaterThanOrEqualTo(wanted),
            reason: 'base of $limit must not limit below the limit');
        expect(capProfileFor(limit, throttle: throttle).capKmh!,
            lessThanOrEqualTo(limit.clamp(customLimitMin, customLimitMax)),
            reason: 'cap of $limit must not exceed the limit');
      }
    });

    test('the cap profile is never unlimited, in any region', () {
      // The cap is what a mode falls back to — the profile that holds the limit
      // when the app cannot. It must always carry a limiter.
      for (var limit = 0; limit <= 100; limit++) {
        for (final throttle in [true, false]) {
          for (final region in [null, ...BikeRegion.values]) {
            expect(
                capProfileFor(limit, throttle: throttle, region: region)
                    .unlimited,
                isFalse,
                reason: 'cap of $limit km/h, throttle $throttle, $region');
          }
        }
      }
    });

    test('a base is unlimited only for a throttle above 32 km/h', () {
      // The one case the table cannot serve: no profile pairs a throttle with a
      // cap over 32. Everywhere else asking for a limit still gets a limiter.
      for (var limit = 0; limit <= 100; limit++) {
        for (final throttle in [true, false]) {
          for (final region in [null, ...BikeRegion.values]) {
            final base = baseProfileFor(limit, throttle, region: region);
            final effective = limit.clamp(customLimitMin, customLimitMax);
            expect(base.unlimited, throttle && effective > 32,
                reason: 'base of $limit km/h, throttle $throttle, $region');
            expect(base.throttle, throttle,
                reason: 'base of $limit km/h must not change the throttle');
          }
        }
      }
    });

    test('a base with a throttle keeps the throttle', () {
      for (final limit in [25, 26, 30, 32]) {
        expect(baseProfileFor(limit, true).throttle, isTrue);
        expect(baseProfileFor(limit, false).throttle, isFalse);
      }
    });

    test('ties break to the lowest wire of the bank', () {
      // Wires 2 and 6 both cap at 45; the US bank is the default.
      expect(capProfileFor(45, throttle: false).wire, 2);
      expect(baseProfileFor(45, false).wire, 2);
      expect(baseProfileFor(41, false).wire, 2);
      expect(capProfileFor(45, throttle: false, region: BikeRegion.eu).wire, 6);
    });

    test('an equal cap prefers the matching throttle', () {
      // Wires 0 and 1 both cap at 32; only wire 1 has a throttle.
      expect(capProfileFor(32, throttle: true).wire, 1);
      expect(capProfileFor(32, throttle: false).wire, 0);
      expect(capProfileFor(34, throttle: true).wire, 1);
    });
  });

  // Named so the brief's `--name "ProfileFor"` run selects it.
  group('baseProfileFor above the throttle ceiling', () {
    test('a throttle mode over 32 rides the off-road profile of its bank', () {
      // No capped profile in the table pairs a throttle with a cap over 32, so
      // an unlimited base is the only way to build this mode.
      expect(baseProfileFor(40, true, region: BikeRegion.eu).wire,
          chWireOffroad);
      expect(baseProfileFor(40, true, region: BikeRegion.ch).wire,
          chWireOffroad);
      expect(baseProfileFor(40, true, region: BikeRegion.us).wire,
          chWireUsOffroad);
      for (final region in BikeRegion.values) {
        expect(baseProfileFor(40, true, region: region).unlimited, isTrue);
        expect(baseProfileFor(40, true, region: region).throttle, isTrue);
      }
    });

    test('a throttle mode at 40 switches, and keeps the limit it asked for',
        () {
      const throttle40 =
          CustomMode(id: 'c40', name: 'T40', limitKmh: 40, throttle: true);
      expect(throttle40.effectiveLimitKmh, 40,
          reason: 'the 32 km/h throttle ceiling is gone');
      expect(isStaticCustomMode(throttle40, region: BikeRegion.ch), isFalse,
          reason: 'base 7 and cap 5 differ, so the app has to switch');
      final b = bike(region: BikeRegion.ch, customModes: const [throttle40])
          .withSelectedMode(throttle40.id);
      expect(b.needsSpeedSwitching, isTrue);
    });
  });

  group('the region breaks a tie in baseProfileFor', () {
    test('an EU or CH bike takes the EU-bank profile where two caps tie', () {
      // Wires 2 and 6 both cap at 45, so limits 36-45 tie.
      for (final limit in [36, 40, 45]) {
        expect(baseProfileFor(limit, false, region: BikeRegion.eu).wire, 6,
            reason: '$limit km/h on EU');
        expect(baseProfileFor(limit, false, region: BikeRegion.ch).wire, 6,
            reason: '$limit km/h on CH');
        expect(baseProfileFor(limit, false, region: BikeRegion.us).wire, 2,
            reason: '$limit km/h on US');
      }
    });

    test('the smallest cap wins before the region does', () {
      // 25 km/h is EPAC alone: no tie, so no bank preference applies.
      expect(baseProfileFor(25, false).wire, 4);
      expect(baseProfileFor(25, false, region: BikeRegion.us).wire, 4);
      expect(baseProfileFor(35, false, region: BikeRegion.us).wire, 5);
    });

    test('a bank with no matching profile leaves the choice alone', () {
      // The seeded CH mode rides wire 1, a US-bank profile: the EU bank has no
      // throttle profile at all, so there is nothing to tie against.
      expect(baseProfileFor(25, true, region: BikeRegion.ch).wire, chWireLow);
      expect(baseProfileFor(30, true, region: BikeRegion.eu).wire, chWireLow);
      expect(capProfileFor(25, throttle: true, region: BikeRegion.ch).wire,
          chWireHigh);
    });

    test('the US bank is the default, so a missed call site cannot move', () {
      expect(baseProfileFor(30, false).wire, 0);
      expect(baseProfileFor(30, true).wire, 1);
      expect(baseProfileFor(45, false).wire, 2);
      expect(capProfileFor(45, throttle: false).wire, 2);
    });
  });

  group('isStaticCustomMode', () {
    CustomMode m(int limit, {bool throttle = false}) =>
        CustomMode(id: 'x', name: 'x', limitKmh: limit, throttle: throttle);

    test('an exact firmware match needs no switching', () {
      const exact = <(int, bool, int)>[
        (32, true, 1),
        (32, false, 0),
        (25, false, 4),
        (35, false, 5),
        (45, false, 2),
      ];
      for (final (limit, throttle, wire) in exact) {
        final mode = m(limit, throttle: throttle);
        expect(isStaticCustomMode(mode), isTrue,
            reason: '$limit km/h, throttle $throttle is wire $wire');
        expect(baseProfileFor(limit, throttle).wire, wire);
      }
    });

    test('a limit between two profiles switches', () {
      expect(isStaticCustomMode(seededChMode), isFalse,
          reason: 'the seeded mode is the old CH dynamic pair');
      expect(isStaticCustomMode(tour30), isFalse);
      for (final limit in [26, 30, 33, 40, 44]) {
        expect(isStaticCustomMode(m(limit)), isFalse, reason: '$limit km/h');
      }
    });

    test('a throttle mode above 32 always switches', () {
      // Its base is unlimited and its cap is not, so the two can never be the
      // same profile — there is no exact firmware match to be had.
      for (final limit in [33, 40, 45]) {
        for (final region in [null, ...BikeRegion.values]) {
          expect(isStaticCustomMode(m(limit, throttle: true), region: region),
              isFalse,
              reason: '$limit km/h with a throttle in $region');
        }
      }
    });
  });

  group('dynamicWireFor', () {
    // Tour 30: base wire 1 (32 + throttle), cap wire 4 (EPAC 25).
    const base = 1;
    const cap = 4;

    test('a stopped bike keeps the wire it has', () {
      expect(dynamicWireFor(tour30, 0, base), base);
      expect(dynamicWireFor(tour30, 0, cap), cap);
      expect(dynamicWireFor(tour30, -1, cap), cap);
    });

    test('riding at the limit still rides the base profile', () {
      expect(dynamicWireFor(tour30, 29, base), base);
      expect(dynamicWireFor(tour30, 30, base), base);
    });

    test('exceeding the limit engages the cap profile', () {
      expect(dynamicWireFor(tour30, 30.1, base), cap);
      expect(dynamicWireFor(tour30, 60, base), cap);
    });

    test('switches back only below the hysteresis band', () {
      // The cap profile pins the speed near the limit, so the way down needs a
      // band or the two profiles trade writes.
      expect(dynamicWireFor(tour30, 29, cap), cap);
      expect(dynamicWireFor(tour30, 28.1, cap), cap);
      expect(dynamicWireFor(tour30, 30 - dynamicHysteresisKmh, cap), cap,
          reason: 'the band is closed at its bottom');
      expect(dynamicWireFor(tour30, 27.9, cap), base);
      expect(dynamicHysteresisKmh, 2.0);
    });

    test('the seeded mode reproduces the old CH thresholds', () {
      // Up at >25 (was >23, the slider floor is 25), down at <23 as before.
      expect(dynamicWireFor(seededChMode, 25, chWireLow), chWireLow);
      expect(dynamicWireFor(seededChMode, 25.1, chWireLow), chWireHigh);
      expect(dynamicWireFor(seededChMode, 23, chWireHigh), chWireHigh);
      expect(dynamicWireFor(seededChMode, 22.9, chWireHigh), chWireLow);
    });

    test('a static mode stays on its one wire', () {
      for (final speed in [0.0, 10.0, 45.0, 100.0]) {
        expect(dynamicWireFor(sport45, speed, 2), 2);
        expect(dynamicWireFor(sport45, speed, 4), 2,
            reason: 'even asked from another wire');
      }
    });

    test('a wire outside the mode own pair counts as the base', () {
      // The mode was edited, or the bike came back on someone else's wire: a
      // stopped bike must not be held on an unlimited wire, and the hysteresis
      // memory must not read a foreign wire as "the cap".
      for (final foreign in [chWireOffroad, 2, 99]) {
        expect(dynamicWireFor(tour30, 0, foreign), base,
            reason: 'stopped on wire $foreign');
        expect(dynamicWireFor(tour30, 10, foreign), base);
        expect(dynamicWireFor(tour30, 29, foreign), base,
            reason: 'wire $foreign is not the cap, so no band applies');
        expect(dynamicWireFor(tour30, 40, foreign), cap);
      }
    });
  });

  group('assertsWire', () {
    test('a native mode asserts only its own wire', () {
      final sel = NativeSelection(profileByWire(5));
      expect(assertsWire(sel, 5), isTrue);
      for (final wire in [0, 1, 4, 6, 7, 9]) {
        expect(assertsWire(sel, wire), isFalse, reason: 'wire $wire');
      }
    });

    test('a switching mode asserts exactly its base and cap', () {
      // Tour 30 rides wires 1 and 4.
      for (final wire in [1, 4]) {
        expect(assertsWire(const CustomSelection(tour30), wire), isTrue,
            reason: 'wire $wire');
      }
      for (final wire in [0, 2, 3, 5, 6, 7, 99]) {
        expect(assertsWire(const CustomSelection(tour30), wire), isFalse,
            reason: 'wire $wire');
      }
    });

    test('a static mode asserts its single wire', () {
      expect(assertsWire(const CustomSelection(sport45), 2), isTrue);
      expect(assertsWire(const CustomSelection(sport45), 6), isFalse,
          reason: 'wire 6 caps at 45 too, but this mode never writes it');
    });

    test('agrees with what wireVerdict expects', () {
      // The two must never disagree: a heal write is chosen with assertsWire
      // and asked for by wireVerdict.
      const throttle40 =
          CustomMode(id: 'c40', name: 'T40', limitKmh: 40, throttle: true);
      for (final region in [null, ...BikeRegion.values]) {
        for (final sel in <SelectedMode>[
          NativeSelection(profileByWire(2)),
          const CustomSelection(tour30),
          const CustomSelection(sport45),
          const CustomSelection(fast40),
          const CustomSelection(throttle40),
        ]) {
          for (var wire = 0; wire < 8; wire++) {
            final verdict = wireVerdict(
                region: region,
                selected: sel,
                reportedWire: 99,
                assertedWire: wire);
            final chosen = assertsWire(sel, wire, region: region)
                ? wire
                : initialWireFor(sel, region: region);
            expect((verdict as WireHeal).expectedWire, chosen,
                reason: '$sel with asserted wire $wire in $region');
          }
        }
      }
    });
  });

  group('initialWireFor', () {
    test('a native mode asserts its own wire', () {
      for (var wire = 0; wire < 8; wire++) {
        expect(initialWireFor(NativeSelection(profileByWire(wire))), wire);
      }
    });

    test('a switching mode enters on its base profile', () {
      expect(initialWireFor(const CustomSelection(tour30)), 1);
      expect(initialWireFor(const CustomSelection(seededChMode)), chWireLow);
    });

    test('a static mode asserts its single wire', () {
      expect(initialWireFor(const CustomSelection(sport45)), 2);
    });

    test('a mode with an unlimited base enters on its cap', () {
      // The fail-safe of Task 16: entering on the base would hand the rider
      // off-road the moment they pick the mode, with no speed sample yet.
      const throttle40 =
          CustomMode(id: 'c40', name: 'T40', limitKmh: 40, throttle: true);
      const sel = CustomSelection(throttle40);
      for (final region in [BikeRegion.eu, BikeRegion.ch]) {
        expect(baseProfileFor(40, true, region: region).wire, chWireOffroad);
        expect(initialWireFor(sel, region: region), 5,
            reason: 'MODE 2, the cap profile — not the off-road base');
      }
      expect(initialWireFor(sel, region: BikeRegion.us), 5);
      expect(entryWireFor(throttle40, BikeRegion.ch), 5);
    });

    test('a foreign asserted wire reads as the cap, not the unlimited base',
        () {
      // _pairWireFor's fallback and initialWireFor must stay the same wire, or
      // a heal write and the verdict that asked for it disagree.
      const throttle40 =
          CustomMode(id: 'c40', name: 'T40', limitKmh: 40, throttle: true);
      const sel = CustomSelection(throttle40);
      for (final foreign in [0, 1, 2, 4, 6, 99]) {
        expect(
            wireForWrite(
                sel: sel,
                modeChanged: false,
                nowSwitching: true,
                assertedWire: foreign,
                region: BikeRegion.ch),
            5,
            reason: 'wire $foreign is no memory of anything');
      }
      expect(
          wireForWrite(
              sel: sel,
              modeChanged: false,
              nowSwitching: true,
              assertedWire: chWireOffroad,
              region: BikeRegion.ch),
          chWireOffroad,
          reason: 'the base is its own, once a speed sample has put it there');
    });

    test('follows what a bike resolves its selection to', () {
      final b = bike(region: BikeRegion.eu, customModes: [tour30])
          .withSelectedMode(tour30.id);
      expect(initialWireFor(b.selectedMode), 1);
      expect(
          initialWireFor(bike(region: BikeRegion.ch).selectedMode), chWireLow,
          reason: 'a CH bike without customs falls back to the seeded mode');
    });
  });

  group('wireForWrite', () {
    // Base wire 1 (32 km/h + throttle), cap wire 4 (EPAC 25).
    const w30 = CustomMode(id: 'w1', name: 'W30', limitKmh: 30, throttle: true);

    test('an unchanged switching mode carries the wire asserted now', () {
      expect(
          wireForWrite(
              sel: const CustomSelection(w30),
              modeChanged: false,
              nowSwitching: true,
              assertedWire: 4),
          4);
      expect(
          wireForWrite(
              sel: const CustomSelection(w30),
              modeChanged: false,
              nowSwitching: true,
              assertedWire: 1),
          1);
    });

    test('a mode change enters on the initial wire', () {
      expect(
          wireForWrite(
              sel: const CustomSelection(w30),
              modeChanged: true,
              nowSwitching: true,
              assertedWire: 4),
          1,
          reason: 'a mode is entered on its base profile');
    });

    test('a mode that never switches carries its own wire', () {
      expect(
          wireForWrite(
              sel: NativeSelection(profileByWire(2)),
              modeChanged: false,
              nowSwitching: false,
              assertedWire: 4),
          2);
    });

    test('a foreign asserted wire falls back to the initial wire', () {
      expect(
          wireForWrite(
              sel: const CustomSelection(w30),
              modeChanged: false,
              nowSwitching: true,
              assertedWire: 9),
          1,
          reason: 'a wire the mode never asserts is no memory of anything');
    });
  });

  group('unwatchedWireFor', () {
    const throttle40 =
        CustomMode(id: 'c40', name: 'T40', limitKmh: 40, throttle: true);

    test('names the cap of a mode whose base is unlimited', () {
      expect(unwatchedWireFor(const CustomSelection(throttle40), BikeRegion.ch),
          5);
      expect(unwatchedWireFor(const CustomSelection(throttle40), BikeRegion.us),
          5);
    });

    test('says nothing for a mode the firmware still limits', () {
      // Their base profile carries a limiter, so an app that cannot see the
      // speed still leaves a limited bike: there is nothing to fall back from.
      for (final region in [null, ...BikeRegion.values]) {
        expect(unwatchedWireFor(const CustomSelection(tour30), region), isNull);
        expect(unwatchedWireFor(const CustomSelection(sport45), region), isNull);
        expect(unwatchedWireFor(const CustomSelection(seededChMode), region),
            isNull);
        expect(unwatchedWireFor(NativeSelection(profileByWire(7)), region),
            isNull,
            reason: 'off-road picked on purpose is not the app losing sight');
      }
    });
  });

  group('wireVerdict', () {
    // One row per region and selection: what every reported wire 0..9 means.
    // '.' in sync, 'h' heal to the expected wire, a digit follows native:<digit>.
    // The asserted wire is deliberately wrong (6) wherever it must be ignored.
    final rows = <(String, BikeRegion?, SelectedMode, int, int, String)>[
      ('US native:2', BikeRegion.us, NativeSelection(profileByWire(2)), 6, 2,
          '01.3hhh3hh'),
      ('no region, native:2', null, NativeSelection(profileByWire(2)), 6, 2,
          '01.3hhh3hh'),
      ('EU native:5', BikeRegion.eu, NativeSelection(profileByWire(5)), 6, 5,
          'hhh74.67hh'),
      ('CH native:7', BikeRegion.ch, NativeSelection(profileByWire(7)), 6, 7,
          'hhh7hhh.hh'),
      ('US static custom', BikeRegion.us, const CustomSelection(sport45), 6, 2,
          'hh.3hhh3hh'),
      // 45 km/h without a throttle is an exact match in both banks: wire 2 on
      // US, wire 6 on EU and CH. The bike's own bank is what the mode rides.
      ('EU static custom', BikeRegion.eu, const CustomSelection(sport45), 6, 6,
          'hhh7hh.7hh'),
      ('CH static custom', BikeRegion.ch, const CustomSelection(sport45), 6, 6,
          'hhh7hh.7hh'),
      ('no region, static custom', null, const CustomSelection(sport45), 6, 2,
          'hh.3hhh3hh'),
      ('US switching custom on base', BikeRegion.us,
          const CustomSelection(tour30), 1, 1, 'h.h3hhh3hh'),
      ('EU switching custom on base', BikeRegion.eu,
          const CustomSelection(tour30), 1, 1, 'h.h7hhh7hh'),
      ('CH switching custom on base', BikeRegion.ch,
          const CustomSelection(tour30), 1, 1, 'h.h7hhh7hh'),
      ('no region, switching custom on base', null,
          const CustomSelection(tour30), 1, 1, 'h.h3hhh3hh'),
      ('US switching custom on cap', BikeRegion.us,
          const CustomSelection(tour30), 4, 4, 'hhh3.hh3hh'),
      ('CH switching custom on cap', BikeRegion.ch,
          const CustomSelection(tour30), 4, 4, 'hhh7.hh7hh'),
    ];

    for (final (label, region, selected, asserted, expected, codes) in rows) {
      test(label, () {
        for (var reported = 0; reported < codes.length; reported++) {
          final code = codes[reported];
          final want = switch (code) {
            '.' => const WireInSync(),
            'h' => WireHeal(expected),
            _ => WireFollow(nativeModeId(int.parse(code))),
          };
          expect(
              wireVerdict(
                  region: region,
                  selected: selected,
                  reportedWire: reported,
                  assertedWire: asserted),
              want,
              reason: '$label: reported wire $reported');
        }
        // A byte outside the table is a mis-sequenced read, never a mode.
        expect(
            wireVerdict(
                region: region,
                selected: selected,
                reportedWire: -1,
                assertedWire: asserted),
            WireHeal(expected),
            reason: '$label: a negative wire byte');
      });
    }

    test('an asserted wire outside the mode own pair reads as the base', () {
      // Fast 40 rides wires 2 and 5; wire 4 is another mode's, left behind by
      // an edit of the selected mode. Believing it would call a foreign byte
      // in sync, or heal the bike onto a wire this mode never asserts.
      WireVerdict verdictOf(int reported, int asserted) => wireVerdict(
          region: BikeRegion.us,
          selected: const CustomSelection(fast40),
          reportedWire: reported,
          assertedWire: asserted);
      for (final stale in [4, chWireOffroad, 99]) {
        expect(verdictOf(2, stale), const WireInSync(),
            reason: 'stale asserted wire $stale');
        expect(verdictOf(5, stale), const WireHeal(2));
        expect(verdictOf(4, stale), const WireHeal(2));
      }
      // A wire the mode really does assert is still believed.
      expect(verdictOf(5, 5), const WireInSync());
      expect(verdictOf(2, 5), const WireHeal(5));
      // Off-road is still followed, whatever the asserted wire was.
      expect(verdictOf(chWireUsOffroad, 99),
          WireFollow(nativeModeId(chWireUsOffroad)));
    });

    test('a mode that rides off-road is not read as the rider going off-road',
        () {
      // The off-road escape hatch would drop the mode for good: one lost cap
      // write, and the app converts a throttle-40 selection to OFFROAD and
      // stops limiting. Wire 7 here is the app's own base, so it heals.
      const throttle40 =
          CustomMode(id: 'c40', name: 'T40', limitKmh: 40, throttle: true);
      const sel = CustomSelection(throttle40);
      for (final region in [BikeRegion.eu, BikeRegion.ch]) {
        expect(
            wireVerdict(
                region: region,
                selected: sel,
                reportedWire: chWireOffroad,
                assertedWire: 5),
            const WireHeal(5),
            reason: '$region: the cap write was lost, so put the cap back');
        expect(
            wireVerdict(
                region: region,
                selected: sel,
                reportedWire: chWireOffroad,
                assertedWire: chWireOffroad),
            const WireInSync(),
            reason: '$region: a speed sample put the mode on its base');
        expect(
            wireVerdict(
                region: region,
                selected: sel,
                reportedWire: chWireUsOffroad,
                assertedWire: 5),
            WireFollow(nativeModeId(chWireOffroad)),
            reason: '$region: wire 3 is not one this mode ever asserts');
      }
      // US: the same mode rides wire 3, so it is wire 7 that is foreign there.
      expect(
          wireVerdict(
              region: BikeRegion.us,
              selected: sel,
              reportedWire: chWireUsOffroad,
              assertedWire: 5),
          const WireHeal(5));
      expect(
          wireVerdict(
              region: BikeRegion.us,
              selected: sel,
              reportedWire: chWireOffroad,
              assertedWire: 5),
          WireFollow(nativeModeId(chWireUsOffroad)));
    });

    test('an EU custom mode is judged in the EU bank', () {
      // The seeded CH mode rides the same pair {1, 4} under the US default, so
      // a call site that forgot its region passes every CH test and still
      // heals an EU bike onto wire 2.
      const eu40 = CustomMode(id: 'c41', name: 'EU40', limitKmh: 40);
      const sel = CustomSelection(eu40);
      // Base wire 6 on EU (wire 2 on US), cap wire 5 in both banks.
      expect(
          wireVerdict(
              region: BikeRegion.eu,
              selected: sel,
              reportedWire: 6,
              assertedWire: 6),
          const WireInSync());
      expect(
          wireVerdict(
              region: BikeRegion.eu,
              selected: sel,
              reportedWire: 2,
              assertedWire: 99),
          const WireHeal(6),
          reason: 'wire 2 caps at 45 too, but an EU bike never rides it here');
    });

    test('verdicts compare by value', () {
      expect(const WireInSync(), const WireInSync());
      expect(const WireFollow('native:3'), const WireFollow('native:3'));
      expect(const WireFollow('native:3'), isNot(const WireFollow('native:7')));
      expect(const WireHeal(2), const WireHeal(2));
      expect(const WireHeal(2), isNot(const WireHeal(3)));
      expect(const WireHeal(2), isNot(const WireInSync()));
      // One of each pair is built at runtime: const canonicalisation would
      // make the set collapse without ever calling ==/hashCode.
      expect({WireHeal(int.parse('2')), const WireHeal(2)}, hasLength(1));
      expect({WireFollow(nativeModeId(3)), const WireFollow('native:3')},
          hasLength(1));
    });
  });

  group('needsSpeedSwitching', () {
    test('a native mode never switches', () {
      for (final (region, id) in <(BikeRegion?, String)>[
        (BikeRegion.us, 'native:2'),
        (BikeRegion.us, 'native:3'), // off-road
        (BikeRegion.eu, 'native:5'),
        (BikeRegion.ch, 'native:7'),
        (null, 'native:1'),
      ]) {
        expect(bike(region: region).withSelectedMode(id).needsSpeedSwitching,
            isFalse,
            reason: '$region $id');
      }
    });

    test('a static custom mode never switches', () {
      expect(
          bike(region: BikeRegion.us, customModes: [sport45])
              .withSelectedMode(sport45.id)
              .needsSpeedSwitching,
          isFalse);
    });

    test('a custom mode between two profiles switches', () {
      expect(
          bike(region: BikeRegion.us, customModes: [tour30])
              .withSelectedMode(tour30.id)
              .needsSpeedSwitching,
          isTrue);
      expect(BikeState.defaultState('id').needsSpeedSwitching, isTrue,
          reason: 'a fresh CH bike rides the seeded mode');
    });

    test('a dangling selection is answered for what it falls back to', () {
      expect(
          bike(region: BikeRegion.ch, modeId: 'gone', customModes: [
            seededChMode
          ]).needsSpeedSwitching,
          isTrue,
          reason: 'CH falls back to its first custom mode');
      expect(bike(region: BikeRegion.ch, modeId: 'gone').needsSpeedSwitching,
          isTrue,
          reason: 'with no custom left, CH falls back to the seeded mode');
      expect(
          bike(region: BikeRegion.us, modeId: 'gone', customModes: [tour30])
              .needsSpeedSwitching,
          isFalse,
          reason: 'US falls back to a native mode');
    });

    test('a bike that refuses the mode never switches, measured or not', () {
      final switching = bike(region: BikeRegion.us, customModes: [tour30])
          .withSelectedMode(tour30.id);
      expect(switching.needsSpeedSwitching, isTrue,
          reason: 'baseline: this mode would switch on its own');

      final refused = switching.copyWith(
          capabilities: BikeCapabilities(
              measuredAt: DateTime(2024),
              acceptedWires: const [0],
              acceptedAssist: const [0, 1, 2, 3, 4],
              lightWritable: true));
      expect(refused.needsSpeedSwitching, isFalse,
          reason: 'the bike has proven it ignores a mode write');

      final unmeasured = switching.copyWith(capabilities: null);
      expect(unmeasured.needsSpeedSwitching, isTrue,
          reason: 'a bike never probed keeps today\'s behaviour');
    });
  });

  group('remapModeForRegion', () {
    String remappedId(BikeState b, BikeRegion? to) =>
        remapModeForRegion(b, to).selectedMode.id;

    test('a native mode keeps its place in the new bank', () {
      for (final (from, id, to, want) in <(BikeRegion?, String, BikeRegion, String)>[
        (BikeRegion.us, 'native:0', BikeRegion.eu, 'native:4'),
        (BikeRegion.us, 'native:2', BikeRegion.eu, 'native:6'),
        (BikeRegion.eu, 'native:4', BikeRegion.us, 'native:0'),
        (BikeRegion.eu, 'native:6', BikeRegion.us, 'native:2'),
        (null, 'native:2', BikeRegion.eu, 'native:6'),
      ]) {
        expect(remappedId(bike(region: from).withSelectedMode(id), to), want,
            reason: '$from $id -> $to');
      }
    });

    test('off-road stays off-road, both ways', () {
      final us = bike(region: BikeRegion.us).withSelectedMode('native:3');
      expect(remappedId(us, BikeRegion.eu), 'native:7');
      expect(remappedId(us, BikeRegion.ch), 'native:7');
      final eu = bike(region: BikeRegion.eu).withSelectedMode('native:7');
      expect(remappedId(eu, BikeRegion.us), 'native:3');
      // Round-trip.
      expect(remapModeForRegion(remapModeForRegion(us, BikeRegion.eu),
              BikeRegion.us)
          .selectedMode
          .id,
          'native:3');
    });

    test('a bike without a region remaps like a US one', () {
      final eu = bike(region: BikeRegion.eu).withSelectedMode('native:6');
      expect(remappedId(eu, null), 'native:2');
      expect(remappedId(bike(region: BikeRegion.eu).withSelectedMode('native:7'),
          null),
          'native:3');
    });

    test('into CH a limited native becomes the seeded mode', () {
      // CH has no limited native of its own, and a region change must never
      // turn a limited mode into an unlimited one: the seeded 25 km/h mode is
      // the closest thing CH has to a limit. Off-road is the only native left.
      for (final id in ['native:0', 'native:1', 'native:2']) {
        final moved = remapModeForRegion(
            bike(region: BikeRegion.us).withSelectedMode(id), BikeRegion.ch);
        expect(moved.selectedMode.id, seededChModeId, reason: id);
        expect(moved.selectedMode, const CustomSelection(seededChMode));
        expect(moved.needsSpeedSwitching, isTrue);
      }
      for (final id in ['native:4', 'native:5', 'native:6']) {
        expect(
            remappedId(
                bike(region: BikeRegion.eu).withSelectedMode(id), BikeRegion.ch),
            seededChModeId,
            reason: id);
      }
    });

    test('the seeded mode follows the bike back out of CH', () {
      final us = bike(region: BikeRegion.us).withSelectedMode('native:2');
      final ch = remapModeForRegion(us, BikeRegion.ch);
      final back = remapModeForRegion(ch, BikeRegion.us);
      expect(back.selectedMode.id, seededChModeId,
          reason: 'a custom mode means the same thing in every region');
      expect(back.customModes, [seededChMode]);
    });

    test('entering CH seeds the seeded mode, exactly once', () {
      final b = bike(region: BikeRegion.us).withSelectedMode('native:2');
      final ch = remapModeForRegion(b, BikeRegion.ch);
      expect(ch.customModes, [seededChMode]);
      expect(ch.selectedMode.id, seededChModeId);
      expect(remapModeForRegion(ch, BikeRegion.ch).customModes, [seededChMode],
          reason: 'seeding is idempotent');
      expect(remapModeForRegion(ch, BikeRegion.ch), ch,
          reason: 'so is the whole remap');
      // The seed goes first, as it does in a fresh bike and in migration.
      final withOwn = bike(region: BikeRegion.us, customModes: [tour30])
          .withSelectedMode('native:2');
      expect(remapModeForRegion(withOwn, BikeRegion.ch).customModes,
          [seededChMode, tour30]);
    });

    test('only CH gets seeded', () {
      final b = bike(region: BikeRegion.ch).withSelectedMode('native:7');
      expect(remapModeForRegion(b, BikeRegion.us).customModes, isEmpty);
      expect(remapModeForRegion(b, BikeRegion.eu).customModes, isEmpty);
    });

    test('a custom mode survives every region change', () {
      final b = bike(region: BikeRegion.us, customModes: [tour30])
          .withSelectedMode(tour30.id);
      for (final to in [BikeRegion.eu, BikeRegion.ch, BikeRegion.us, null]) {
        final moved = remapModeForRegion(b, to);
        expect(moved.selectedMode.id, tour30.id, reason: 'to $to');
        expect(moved.customModes.contains(tour30), isTrue);
        expect(moved.region, to);
      }
    });

    test('a dangling selection remaps through the old fallback', () {
      // EU falls back to EPAC (wire 4), which is bank index 0 in US.
      expect(remappedId(bike(region: BikeRegion.eu, modeId: 'gone'),
          BikeRegion.us),
          'native:0');
      expect(remappedId(bike(region: BikeRegion.us, modeId: 'gone'),
          BikeRegion.eu),
          'native:4');
    });

    test('keeps the legacy projection in sync', () {
      int legacyOf(BikeState b, BikeRegion? to) =>
          remapModeForRegion(b, to).legacyMode;
      final us = bike(region: BikeRegion.us).withSelectedMode('native:2');
      expect(legacyOf(us, BikeRegion.eu), 2);
      expect(legacyOf(us, BikeRegion.ch), 0,
          reason: 'the seeded mode is the old CH dynamic mode');
      expect(
          legacyOf(bike(region: BikeRegion.us).withSelectedMode('native:3'),
              BikeRegion.ch),
          2,
          reason: 'CH off-road is mode 2');
      expect(legacyOf(bike(region: BikeRegion.eu).withSelectedMode('native:7'),
          BikeRegion.us),
          3);
      final custom = bike(region: BikeRegion.us, customModes: [tour30])
          .withSelectedMode(tour30.id);
      for (final to in [BikeRegion.eu, BikeRegion.ch, null]) {
        expect(legacyOf(custom, to), 0, reason: 'to $to');
      }
      // The projection is what the remapped bike itself would compute.
      for (final to in [BikeRegion.eu, BikeRegion.ch, BikeRegion.us, null]) {
        final moved = remapModeForRegion(us, to);
        expect(moved.legacyMode, moved.withSelectedMode(moved.modeId).legacyMode,
            reason: 'to $to');
      }
    });
  });
}

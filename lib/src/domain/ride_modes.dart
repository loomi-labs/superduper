import 'dart:math';

enum BikeRegion {
  us('US'),
  eu('EU'),
  ch('CH');

  new(this.label);

  final String label;

  static const v1BankSize = 4;

  /// The bank a V1 wire byte belongs to. CH is never inferred.
  static BikeRegion fromV1Wire(int wire) =>
      wire >= v1BankSize ? BikeRegion.eu : BikeRegion.us;
}

/// A firmware profile of a V1 bike, addressed by the wire byte the control
/// packet carries. Wires 0 to 7 are contiguous, so the wire is the table index.
final class FirmwareProfile {
  const new(
    this.wire,
    this.name,
    this.capKmh,
    this.capMph,
    this.note, {
    required this.throttle,
  });

  final int wire;
  final String name;
  final int? capKmh;
  final int? capMph;
  final String note;
  final bool throttle;

  bool get unlimited => capKmh == null;

  /// The chip label: the speed limit in the region's unit. An unlimited
  /// profile keeps the firmware name, which matches the bike's display.
  String label(BikeRegion? region) {
    if (capKmh == null) {
      return 'OFFROAD';
    }
    final useMph = region == BikeRegion.us || region == null;
    final cap = useMph ? capMph : capKmh;
    final unit = useMph ? 'mph' : 'km/h';
    final base = '$cap $unit';
    return throttle ? '$base + throttle' : base;
  }
}

const firmwareProfiles = <FirmwareProfile>[
  FirmwareProfile(
    0,
    'ECO',
    32,
    20,
    'US Class 1, pedal assist only',
    throttle: false,
  ),
  FirmwareProfile(1, 'TOUR', 32, 20, 'US Class 2, throttle', throttle: true),
  FirmwareProfile(
    2,
    'SPORT',
    45,
    28,
    'US Class 3, pedal assist only',
    throttle: false,
  ),
  FirmwareProfile(
    3,
    'OFFROAD',
    null,
    null,
    'US off-road, no limit, throttle',
    throttle: true,
  ),
  FirmwareProfile(4, 'EPAC', 25, 16, 'EU, pedal assist only', throttle: false),
  FirmwareProfile(
    5,
    'MODE 2',
    35,
    22,
    'EU, pedal assist only',
    throttle: false,
  ),
  FirmwareProfile(
    6,
    'MODE 3',
    45,
    28,
    'EU, pedal assist only',
    throttle: false,
  ),
  FirmwareProfile(
    7,
    'OFFROAD',
    null,
    null,
    'EU off-road, no limit, throttle',
    throttle: true,
  ),
];

FirmwareProfile profileByWire(int wire) => firmwareProfiles[wire];

const usOffroadWire = 3;
const euOffroadWire = 7;

int offroadWireFor(BikeRegion? region) =>
    region == BikeRegion.us || region == null ? usOffroadWire : euOffroadWire;

/// The native wires a region offers. CH offers only OFFROAD; every limit on
/// a CH bike is a custom mode.
List<int> nativeWiresFor(BikeRegion region) => switch (region) {
  BikeRegion.us => const [0, 1, 2, 3],
  BikeRegion.eu => const [4, 5, 6, 7],
  BikeRegion.ch => const [7],
};

bool _inBankOf(int wire, BikeRegion? region) =>
    (region == BikeRegion.eu || region == BikeRegion.ch) ==
    (wire >= BikeRegion.v1BankSize);

const customLimitMin = 25;
const customLimitMax = 45;
const dynamicHysteresisKmh = 2.0;
const customModeNameMaxLength = 12;

final class CustomMode {
  const new({
    required this.id,
    required this.name,
    required this.limitKmh,
    this.throttle = false,
  });

  final String id;
  final String name;
  final int limitKmh;
  final bool throttle;

  /// The limit the engine enforces: clamped to the slider range.
  int get effectiveLimitKmh => limitKmh.clamp(customLimitMin, customLimitMax);

  CustomMode copyWith({
    String? id,
    String? name,
    int? limitKmh,
    bool? throttle,
  }) {
    return CustomMode(
      id: id ?? this.id,
      name: name ?? this.name,
      limitKmh: limitKmh ?? this.limitKmh,
      throttle: throttle ?? this.throttle,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomMode &&
      id == other.id &&
      name == other.name &&
      limitKmh == other.limitKmh &&
      throttle == other.throttle;

  @override
  int get hashCode => Object.hash(id, name, limitKmh, throttle);
}

const seededChModeId = 'seed-ch-25';
const seededChMode = CustomMode(
  id: seededChModeId,
  name: '25 km/h',
  limitKmh: 25,
  throttle: true,
);

String newCustomModeId() =>
    'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 20).toRadixString(36)}';

/// The profile a custom mode rides below its limit: the smallest finite cap
/// at or above the limit with a matching throttle. A tie goes to the region's
/// own bank, then to the lowest wire. Unlimited only when no capped profile
/// with the requested throttle can hold the limit (throttle above 32 km/h).
FirmwareProfile baseProfileFor(
  int limitKmh, {
  required bool throttle,
  BikeRegion? region,
}) {
  final limit = limitKmh.clamp(customLimitMin, customLimitMax);
  FirmwareProfile? best;
  for (final p in firmwareProfiles) {
    if (p.unlimited || p.throttle != throttle || p.capKmh! < limit) {
      continue;
    }
    final smaller = best == null || p.capKmh! < best.capKmh!;
    final ownBank =
        best != null &&
        p.capKmh == best.capKmh &&
        _inBankOf(p.wire, region) &&
        !_inBankOf(best.wire, region);
    if (smaller || ownBank) {
      best = p;
    }
  }
  return best ?? profileByWire(offroadWireFor(region));
}

/// The profile a custom mode rides above its limit: the fastest cap at or
/// below the limit, of any throttle. Ties prefer a matching throttle, then the
/// own bank, then the lowest wire. Never unlimited.
FirmwareProfile capProfileFor(
  int limitKmh, {
  required bool throttle,
  BikeRegion? region,
}) {
  final limit = limitKmh.clamp(customLimitMin, customLimitMax);
  FirmwareProfile? best;
  for (final p in firmwareProfiles) {
    if (p.unlimited || p.capKmh! > limit) {
      continue;
    }
    final faster = best == null || p.capKmh! > best.capKmh!;
    final tie = best != null && p.capKmh == best.capKmh;
    final betterTie =
        tie &&
        (p.throttle != best.throttle
            ? p.throttle == throttle
            : _inBankOf(p.wire, region) && !_inBankOf(best.wire, region));
    if (faster || betterTie) {
      best = p;
    }
  }
  return best!;
}

({int base, int cap}) wirePairFor(CustomMode mode, BikeRegion? region) {
  final limit = mode.effectiveLimitKmh;
  return (
    base: baseProfileFor(limit, throttle: mode.throttle, region: region).wire,
    cap: capProfileFor(limit, throttle: mode.throttle, region: region).wire,
  );
}

/// The wire a custom mode is put on with no speed information: its base,
/// unless the base is unlimited, then its cap.
int entryWireFor(CustomMode mode, BikeRegion? region) {
  final (:base, :cap) = wirePairFor(mode, region);
  return profileByWire(base).unlimited ? cap : base;
}

/// The wire to fall back to when the app loses sight of the speed, or null
/// when the firmware already holds the limit on the base.
int? unwatchedWireFor(CustomMode mode, BikeRegion? region) {
  final (:base, :cap) = wirePairFor(mode, region);
  return profileByWire(base).unlimited ? cap : null;
}

bool isStaticCustomMode(CustomMode mode, BikeRegion? region) {
  final pair = wirePairFor(mode, region);
  return pair.base == pair.cap;
}

int _pairWireFor(CustomMode mode, int wire, BikeRegion? region) {
  final pair = wirePairFor(mode, region);
  return wire == pair.base || wire == pair.cap
      ? wire
      : entryWireFor(mode, region);
}

/// The wire a switching custom mode asserts at [speedKmh]. [currentWire]
/// carries the stopped-speed hold and the hysteresis memory.
int dynamicWireFor(
  CustomMode mode,
  double speedKmh,
  int currentWire,
  BikeRegion? region,
) {
  final limit = mode.effectiveLimitKmh;
  final (:base, :cap) = wirePairFor(mode, region);
  if (base == cap) {
    return base;
  }
  final current = _pairWireFor(mode, currentWire, region);
  if (speedKmh <= 0) {
    return current;
  }
  if (current == cap) {
    return speedKmh < limit - dynamicHysteresisKmh ? base : cap;
  }
  return speedKmh > limit ? cap : base;
}

sealed class RideModeSelection {
  const new();

  String get name;
  String label(BikeRegion? region);
}

final class NativeRideMode extends RideModeSelection {
  const new(this.wire);

  final int wire;

  FirmwareProfile get profile => profileByWire(wire);

  @override
  String get name => profile.name;

  @override
  String label(BikeRegion? region) => profile.label(region);

  @override
  bool operator ==(Object other) =>
      other is NativeRideMode && other.wire == wire;

  @override
  int get hashCode => Object.hash(NativeRideMode, wire);
}

final class CustomRideMode extends RideModeSelection {
  const new(this.mode);

  final CustomMode mode;

  @override
  String get name => mode.name;

  @override
  String label(BikeRegion? region) => mode.name;

  @override
  bool operator ==(Object other) =>
      other is CustomRideMode && other.mode == mode;

  @override
  int get hashCode => Object.hash(CustomRideMode, mode);
}

int initialWireFor(RideModeSelection selection, BikeRegion? region) =>
    switch (selection) {
      NativeRideMode(:final wire) => wire,
      CustomRideMode(:final mode) => entryWireFor(mode, region),
    };

/// Whether [wire] is one the selection ever asserts.
bool assertsWire(RideModeSelection selection, int wire, BikeRegion? region) {
  switch (selection) {
    case NativeRideMode(wire: final own):
      return own == wire;
    case CustomRideMode(:final mode):
      final pair = wirePairFor(mode, region);
      return wire == pair.base || wire == pair.cap;
  }
}

bool isDynamicSelection(RideModeSelection selection, BikeRegion? region) =>
    switch (selection) {
      NativeRideMode() => false,
      CustomRideMode(:final mode) => !isStaticCustomMode(mode, region),
    };

/// The modes the selector offers: custom modes first, then the region's
/// native wires.
List<RideModeSelection> selectableRideModes({
  required BikeRegion region,
  required List<CustomMode> customModes,
}) {
  return List.unmodifiable([
    for (final mode in customModes) CustomRideMode(mode),
    for (final wire in nativeWiresFor(region)) NativeRideMode(wire),
  ]);
}

String customModeNameFor(int limitKmh, BikeRegion? region) =>
    region == BikeRegion.us ? '${mphFromKmh(limitKmh)} mph' : '$limitKmh km/h';

int mphFromKmh(int kmh) => (kmh / 1.609344).round();

int kmhFromMph(int mph) => (mph * 1.609344).round();

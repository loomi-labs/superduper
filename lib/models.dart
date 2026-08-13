import 'dart:math';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:superduper/names.dart';

part 'models.freezed.dart';
part 'models.g.dart';

// Declaration order is what the region dropdown renders; @JsonValue pins
// persistence, so reordering is safe.
enum BikeRegion {
  // Switzerland: mode 1 is a virtual mode, throttle up to ~25 km/h (see README)
  @JsonValue(202)
  ch('CH'),
  // S2
  @JsonValue(201)
  eu('EU'),
  // R,RX
  @JsonValue(200)
  us('US');

  const BikeRegion(this.value);
  final String value;
}

// Documented aliases for the wire bytes the seeded CH mode rides, kept because
// they name what the bytes mean rather than where they sit in the table.
const chWireLow = 1; // US Class 2: PAS + throttle, 20 mph
const chWireHigh = 4; // EPAC: PAS only, 25 km/h
const chWireUsOffroad = 3; // US off-road: PAS + throttle, no limit
const chWireOffroad = 7; // EU off-road: PAS + throttle, no limit

/// True for a settings register read-back, `[3, 0, assist, walk, light, mode,
/// ...]`.
///
/// The register characteristic is shared with the ride data register, so a
/// mis-sequenced read can come back with a ride data frame (`[2, 1, speed_lo,
/// speed_high, ...]`) instead. Parsed as settings that puts a speed byte into
/// assist and a speed byte into the mode — and the control loop writes what it
/// parsed straight back to the bike, which can mean off-road.
bool isSettingsPacket(List<int> data) =>
    data.length >= 6 && data[0] == 3 && data[1] == 0;

/// A firmware profile of the bike, addressed by the raw wire byte the settings
/// packet carries. Wires 0-7 are contiguous, so the wire is the table index.
class FirmwareProfile {
  const FirmwareProfile(this.wire, this.name, this.capKmh, this.capMph,
      this.note,
      {required this.throttle});
  final int wire;
  final String name;

  /// null = no limiter (off-road).
  final int? capKmh;

  /// The legal class limit in mph, written out per wire rather than
  /// converted from [capKmh]: a US class limit is defined in mph, and 32
  /// km/h is 19.88 mph, not the 20 mph the class actually allows. Null
  /// exactly where [capKmh] is null.
  final int? capMph;

  /// The tooltip tail shown beside [label], e.g. `'US Class 1, pedal assist
  /// only'`.
  final String note;
  final bool throttle;

  bool get unlimited => capKmh == null;

  /// The row/chip label a rider sees: the speed limit in [region]'s unit,
  /// not the firmware name — a firmware name like `MODE 2` says nothing
  /// about what the mode does. The one exception is an unlimited profile,
  /// which has no speed to print and keeps the firmware name `OFFROAD`,
  /// matching the bike's own display.
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
  FirmwareProfile(0, 'ECO', 32, 20, 'US Class 1, pedal assist only',
      throttle: false), // US Class 1
  FirmwareProfile(1, 'TOUR', 32, 20, 'US Class 2, throttle',
      throttle: true), // US Class 2
  FirmwareProfile(2, 'SPORT', 45, 28, 'US Class 3, pedal assist only',
      throttle: false), // US Class 3
  FirmwareProfile(3, 'OFFROAD', null, null, 'US off-road · no limit, throttle',
      throttle: true), // US off-road
  FirmwareProfile(4, 'EPAC', 25, 16, 'EU, pedal assist only',
      throttle: false),
  FirmwareProfile(5, 'MODE 2', 35, 22, 'EU, pedal assist only',
      throttle: false),
  FirmwareProfile(6, 'MODE 3', 45, 28, 'EU, pedal assist only',
      throttle: false),
  FirmwareProfile(7, 'OFFROAD', null, null, 'EU off-road · no limit, throttle',
      throttle: true), // EU off-road
];

FirmwareProfile profileByWire(int wire) => firmwareProfiles[wire];

/// The off-road profile of [region]'s own bank. Both are unlimited and both
/// carry a throttle; only the wire byte differs.
int offroadWireFor(BikeRegion? region) =>
    region == BikeRegion.us || region == null ? chWireUsOffroad : chWireOffroad;

/// Whether [wire] belongs to the bank [region]'s firmware addresses. CH rides
/// the EU bank: a CH bike is an EU bike whose only native mode is off-road.
///
/// A bank is a tie-break, never a filter: the seeded CH mode rides wire 1, a
/// US-bank profile, because the EU bank has no profile with a throttle at all.
bool _inBankOf(int wire, BikeRegion? region) =>
    (region == BikeRegion.eu || region == BikeRegion.ch) == (wire >= 4);

/// The profile a custom mode rides *below* its limit: the closest profile at or
/// above [limitKmh] with a matching [throttle], i.e. the smallest finite cap
/// that still holds the limit. A tie goes to [region]'s own bank, then to the
/// lowest wire.
///
/// The result is unlimited only when no capped profile of the requested
/// throttle can hold the limit at all — a throttle above 32 km/h, where the
/// table pairs a throttle with no limiter. Such a mode rides off-road below its
/// limit and the APP holds the limit, not the firmware: see [initialWireFor],
/// which enters it on its cap rather than on this base.
///
/// [limitKmh] is clamped exactly as [CustomMode.effectiveLimitKmh] clamps it,
/// so the answer is total.
FirmwareProfile baseProfileFor(int limitKmh, bool throttle,
    {BikeRegion? region}) {
  final limit = limitKmh.clamp(customLimitMin, customLimitMax).toInt();
  FirmwareProfile? best;
  for (final p in firmwareProfiles) {
    if (p.unlimited || p.throttle != throttle || p.capKmh! < limit) {
      continue;
    }
    // Strictly smaller, so a tie keeps the profile found first — which the
    // bank rule may then take, and otherwise the lower wire keeps.
    final smaller = best == null || p.capKmh! < best.capKmh!;
    final ownBank = best != null &&
        p.capKmh == best.capKmh &&
        _inBankOf(p.wire, region) &&
        !_inBankOf(best.wire, region);
    if (smaller || ownBank) {
      best = p;
    }
  }
  // No limiter in the table holds this limit with a throttle. Off-road is the
  // only profile that can carry the mode; the caller holds the limit itself.
  return best ?? profileByWire(offroadWireFor(region));
}

/// The profile a custom mode rides *above* its limit: the fastest profile whose
/// cap is at or below [limitKmh], of any throttle — the limit is what the rider
/// asked for, and no profile in the table pairs a throttle with a low cap.
///
/// [throttle] is a tie-break only: among equal caps the matching-throttle
/// profile wins, then [region]'s own bank, then the lowest wire. That is what
/// makes an exact firmware match fall out as `base == cap` (e.g. {32, throttle}
/// ties wires 0 and 1 at cap 32, and the tie-break picks 1 — the base).
///
/// A cap profile is not required to have a throttle, so the throttle says
/// nothing about how high it may cap. The slider floor is the slowest profile's
/// cap, so the answer always exists and is never unlimited: this is the profile
/// a mode falls back to, and it must always hold a limit.
FirmwareProfile capProfileFor(int limitKmh,
    {required bool throttle, BikeRegion? region}) {
  final limit = limitKmh.clamp(customLimitMin, customLimitMax).toInt();
  FirmwareProfile? best;
  for (final p in firmwareProfiles) {
    if (p.unlimited || p.capKmh! > limit) {
      continue;
    }
    final faster = best == null || p.capKmh! > best.capKmh!;
    final tie = best != null && p.capKmh == best.capKmh;
    // The throttle answers first; the bank only decides where it cannot.
    final betterTie = tie &&
        (p.throttle != best.throttle
            ? p.throttle == throttle
            : _inBankOf(p.wire, region) && !_inBankOf(best.wire, region));
    if (faster || betterTie) {
      best = p;
    }
  }
  return best!;
}

/// The two wires a custom mode ever asserts: below its limit and above it.
({int base, int cap}) _wirePairFor(CustomMode m, BikeRegion? region) {
  final limit = m.effectiveLimitKmh;
  return (
    base: baseProfileFor(limit, m.throttle, region: region).wire,
    cap: capProfileFor(limit, throttle: m.throttle, region: region).wire
  );
}

/// The wire a custom mode is put on with no speed information: its base
/// profile, unless that base is unlimited — then its cap.
///
/// Inverted for an unlimited base on purpose. Such a mode has no firmware
/// limiter below its limit, so entering it on its base would hand the rider
/// off-road the moment they pick it, before a single speed sample proves the
/// app is watching. It enters capped, and [dynamicWireFor] drops it to the base
/// on the first sample below the limit. The rider loses full assistance for a
/// moment; in exchange the unlimited profile is only ever on the bike while the
/// app receives speed.
int entryWireFor(CustomMode m, BikeRegion? region) {
  final (:base, :cap) = _wirePairFor(m, region);
  return profileByWire(base).unlimited ? cap : base;
}

/// The wire a switching mode has to fall back to when the app loses sight of
/// the speed, or null when there is nothing to fall back from.
///
/// Only a mode whose base is unlimited has: on every other mode the firmware
/// holds the limit on the base profile, so a blind app still leaves a limited
/// bike. The controller's speed-stream watchdog is what asks.
int? unwatchedWireFor(SelectedMode sel, BikeRegion? region) => switch (sel) {
      NativeSelection() => null,
      CustomSelection(:final mode) =>
        baseProfileFor(mode.effectiveLimitKmh, mode.throttle, region: region)
                .unlimited
            ? _wirePairFor(mode, region).cap
            : null,
    };

/// A wire read as a position in [m]'s own pair. A wire the mode never asserts —
/// left over from an edit of the mode, or another app's — means nothing to it
/// and is read as [entryWireFor]: the mode must never be believed to be riding
/// a wire it cannot have written, and never an unlimited one on no evidence.
int _pairWireFor(CustomMode m, int wire, BikeRegion? region) {
  final pair = _wirePairFor(m, region);
  return wire == pair.base || wire == pair.cap
      ? wire
      : entryWireFor(m, region);
}

/// Whether a custom mode is an exact firmware match: one profile does the whole
/// job, so there is nothing to switch and no speed stream to keep up.
bool isStaticCustomMode(CustomMode m, {BikeRegion? region}) {
  final pair = _wirePairFor(m, region);
  return pair.base == pair.cap;
}

/// Down-switch band. Asymmetric on purpose: the up-switch engages the limiter
/// and is the safety function, so it fires the moment the limit is exceeded;
/// the down-switch is where oscillation lives, because the cap profile's own
/// limiter pins the speed at about the limit. 2 km/h reproduces the 23 -> 25
/// gap the old CH dynamic mode rode on.
const dynamicHysteresisKmh = 2.0;

/// The wire a switching custom mode should assert at [speedKmh]. [currentWire]
/// carries both the stopped-speed hold and the hysteresis memory.
int dynamicWireFor(CustomMode m, double speedKmh, int currentWire,
    {BikeRegion? region}) {
  final limit = m.effectiveLimitKmh;
  final (:base, :cap) = _wirePairFor(m, region);
  if (base == cap) {
    return base; // static — callers gate on needsSpeedSwitching anyway
  }
  // A wire this mode never asserts carries no hysteresis memory and no hold.
  final current = _pairWireFor(m, currentWire, region);
  if (speedKmh <= 0) {
    return current; // stopped: a parked bike keeps the wire it has
  }
  if (current == cap) {
    return speedKmh < limit - dynamicHysteresisKmh ? base : cap;
  }
  // Riding *at* the limit still rides the base profile.
  return speedKmh > limit ? cap : base;
}

// Slider range of a custom mode. One range for every mode: above 32 km/h a
// throttle mode rides an unlimited base and the app holds the limit, which is
// a cost the editor states rather than a reason to refuse the mode.
const customLimitMin = 25;
const customLimitMax = 45;

@freezed
abstract class CustomMode with _$CustomMode {
  const CustomMode._();

  const factory CustomMode({
    required String id,
    required String name,
    required int limitKmh,
    @Default(false) bool throttle,
  }) = _CustomMode;

  factory CustomMode.fromJson(Map<String, Object?> json) =>
      _$CustomModeFromJson(json);

  /// The limit the engine actually enforces: clamped to the slider range, so a
  /// hand-edited or future-version json rides a limit the app can hold.
  int get effectiveLimitKmh =>
      limitKmh.clamp(customLimitMin, customLimitMax).toInt();
}

/// Id for a user created mode: time + random suffix, no uuid dependency.
String newCustomModeId() =>
    'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
    '${Random().nextInt(1 << 20).toRadixString(36)}';

// Native modes are addressed by their wire byte, which is absolute: the id of a
// mode does not change when the bike's region does.
const _nativePrefix = 'native:';

String nativeModeId(int wire) => '$_nativePrefix$wire';

int? nativeWireOf(String modeId) => modeId.startsWith(_nativePrefix)
    ? int.tryParse(modeId.substring(_nativePrefix.length))
    : null;

/// A resolved [BikeState.modeId]. Never persisted — the id is.
sealed class SelectedMode {
  String get id;
  String get name;

  /// The row/chip label: the speed limit for a native mode, the rider's own
  /// name for a custom one. See [FirmwareProfile.label].
  String label(BikeRegion? region);

  /// The tooltip tail for a native mode's [FirmwareProfile.note], null for a
  /// custom mode — it has no firmware profile to look up.
  String? get note;
}

// Both are values, not identities: [BikeState.selectableModes] allocates a
// fresh instance on every call, so comparing selections has to compare modes.
class NativeSelection implements SelectedMode {
  const NativeSelection(this.profile);
  final FirmwareProfile profile;

  @override
  String get id => nativeModeId(profile.wire);

  @override
  String get name => profile.name;

  @override
  String label(BikeRegion? region) => profile.label(region);

  @override
  String? get note => profile.note;

  @override
  bool operator ==(Object other) =>
      other is NativeSelection && other.profile.wire == profile.wire;

  @override
  int get hashCode => Object.hash(NativeSelection, profile.wire);
}

class CustomSelection implements SelectedMode {
  const CustomSelection(this.mode);
  final CustomMode mode;

  @override
  String get id => mode.id;

  @override
  String get name => mode.name;

  // The rider already named this mode; region carries no firmware profile to
  // look a speed up in, so the custom name is the whole label. mph display
  // for a custom mode on a US bike is a separate change (see PLAN2).
  @override
  String label(BikeRegion? region) => mode.name;

  @override
  String? get note => null;

  @override
  bool operator ==(Object other) =>
      other is CustomSelection && other.mode == mode;

  @override
  int get hashCode => Object.hash(CustomSelection, mode);
}

/// The wire a selection asserts with no speed information: entering the mode,
/// reconnecting, or a mode that never switches. A switching custom mode enters
/// on [entryWireFor] — its base profile, or its cap where that base is
/// unlimited — and lets the next speed sample move it.
int initialWireFor(SelectedMode sel, {BikeRegion? region}) => switch (sel) {
      NativeSelection(:final profile) => profile.wire,
      CustomSelection(:final mode) => entryWireFor(mode, region),
    };

/// The wire byte a settings write must carry, given the wire the app asserts
/// at this moment. A mode change and a non-switching mode enter on the
/// selection's initial wire; an unchanged switching mode keeps the asserted
/// wire, normalised through [assertsWire] exactly as [wireVerdict] normalises
/// it.
///
/// Callers evaluate this at the head of the register queue, never at compose
/// time: a write composed before a speed transition must not put the
/// pre-transition wire back on the bike.
int wireForWrite({
  required SelectedMode sel,
  required bool modeChanged,
  required bool nowSwitching,
  required int assertedWire,
  BikeRegion? region,
}) {
  if (modeChanged || !nowSwitching) {
    return initialWireFor(sel, region: region);
  }
  return assertsWire(sel, assertedWire, region: region)
      ? assertedWire
      : initialWireFor(sel, region: region);
}

/// Whether [wire] is one [sel] ever asserts: a native mode's single wire, or
/// one of a custom mode's base/cap pair.
///
/// A wire that fails this is no memory of anything — left behind by an edit
/// that moved the mode's profile pair, or written by another app. Both
/// [wireVerdict] and the controller's own wire choice fall back to
/// [initialWireFor] on it, so the two can never disagree.
bool assertsWire(SelectedMode sel, int wire, {BikeRegion? region}) =>
    switch (sel) {
      NativeSelection(:final profile) => wire == profile.wire,
      CustomSelection(:final mode) => _pairWireFor(mode, wire, region) == wire,
    };

/// What to do about a wire byte the bike reports. Replaces the byte-to-mode
/// table: the app compares the reported wire with the one it asserts.
sealed class WireVerdict {
  const WireVerdict();
}

/// The bike is riding what the app selected.
class WireInSync extends WireVerdict {
  const WireInSync();

  @override
  bool operator ==(Object other) => other is WireInSync;

  @override
  int get hashCode => (WireInSync).hashCode;

  @override
  String toString() => 'WireInSync()';
}

/// Someone else moved the bike to a mode this app can name: adopt it.
class WireFollow extends WireVerdict {
  const WireFollow(this.modeId);
  final String modeId;

  @override
  bool operator ==(Object other) => other is WireFollow && other.modeId == modeId;

  @override
  int get hashCode => Object.hash(WireFollow, modeId);

  @override
  String toString() => 'WireFollow($modeId)';
}

/// The bike is somewhere the selection does not describe: write the selection
/// back.
class WireHeal extends WireVerdict {
  const WireHeal(this.expectedWire);
  final int expectedWire;

  @override
  bool operator ==(Object other) =>
      other is WireHeal && other.expectedWire == expectedWire;

  @override
  int get hashCode => Object.hash(WireHeal, expectedWire);

  @override
  String toString() => 'WireHeal($expectedWire)';
}

/// Compares the wire the bike reports with the one the app asserts.
///
/// [assertedWire] is the controller's own last written wire: for a switching
/// custom mode it is the only thing that knows which half of the pair the mode
/// is on. A bike whose mode pin is locked turns a [WireFollow] into a heal —
/// that is the caller's job, not this function's.
WireVerdict wireVerdict({
  required BikeRegion? region,
  required SelectedMode selected,
  required int reportedWire,
  required int assertedWire,
}) {
  final expected = switch (selected) {
    NativeSelection(:final profile) => profile.wire,
    // An asserted wire the mode does not own — stale after an edit of the mode,
    // or never written — would make a foreign byte read as in sync, or heal the
    // bike onto a wire this mode never asserts.
    CustomSelection(:final mode) => isStaticCustomMode(mode, region: region)
        ? initialWireFor(selected, region: region)
        : _pairWireFor(mode, assertedWire, region),
  };
  if (reportedWire == expected) {
    return const WireInSync();
  }
  // A byte outside the table is a mis-sequenced read or a firmware the app does
  // not know: never follow it.
  if (reportedWire < 0 || reportedWire >= firmwareProfiles.length) {
    return WireHeal(expected);
  }
  final bank = switch (region) {
    BikeRegion.eu => const [4, 5, 6, 7],
    BikeRegion.ch => const [chWireOffroad],
    _ => const [0, 1, 2, 3],
  };
  // A native selection follows any other native of its own region: the rider
  // picked it in another app, or the controller powered up in it.
  if (selected is NativeSelection && bank.contains(reportedWire)) {
    return WireFollow(nativeModeId(reportedWire));
  }
  // Off-road escape hatch, every region and every selection type: 3 and 7 are
  // both unlimited with a throttle, so the bike really is off-road and the app
  // has to say so rather than pull it back into a limit.
  //
  // Not for a mode that asserts the reported wire itself. A throttle mode above
  // 32 km/h rides off-road below its limit, so its own base wire would read as
  // "the rider went off-road": one lost cap write would drop the mode for good
  // and take both fail-safes with it. That wire is the app's own, and the heal
  // below puts the cap back.
  if ((reportedWire == chWireUsOffroad || reportedWire == chWireOffroad) &&
      !assertsWire(selected, reportedWire, region: region)) {
    return WireFollow(nativeModeId(offroadWireFor(region)));
  }
  // Custom modes are the app's own composition: wires stop being 1:1 with
  // modes, so anything else is a lost write or another app, and gets healed.
  return WireHeal(expected);
}

/// How hard a padlock holds the value it pins.
///
/// Persistence does not go through the enum's own json mapping: the same key
/// held a bool before, so [_pinFromJson] and [_pinToJson] are the wire format.
/// Declaration order is therefore free, and it is what the control cycles
/// through.
enum PinState {
  /// Follow the bike. Nothing is pinned.
  open,

  /// Apply the pinned value once, when a ride starts.
  startup,

  /// Hold the pinned value always. This is what a lock did before.
  locked,
}

/// Where a padlock tap moves the pin: open, startup, locked, open again.
///
/// One cycle for the whole app, so the control and the notifier can never
/// disagree about what a tap does.
PinState nextPin(PinState pin) => switch (pin) {
      PinState.open => PinState.startup,
      PinState.startup => PinState.locked,
      PinState.locked => PinState.open,
    };

/// Reads a padlock out of json, in the old shape and the new one.
///
/// A build before three-state padlocks wrote a bool under the same key, so
/// `true` is a lock, and anything that build could write means open.
PinState _pinFromJson(Object? json) => switch (json) {
      true => PinState.locked,
      'locked' => PinState.locked,
      'startup' => PinState.startup,
      _ => PinState.open,
    };

/// Writes a padlock as the bool an older build can still read, wherever there
/// is a bool that means the same thing.
///
/// Only a startup pin has none. That bike is dropped by a downgraded build,
/// which is the price of a state the old model cannot express — and an older
/// build could not act on the pin anyway.
Object _pinToJson(PinState pin) => switch (pin) {
      PinState.locked => true,
      PinState.open => false,
      PinState.startup => 'startup',
    };

/// What the bike itself last reported.
///
/// Bike truth, never app intent: only a read may write it. A write lost to a
/// disconnect makes intent differ from reality with no power cycle involved,
/// so intent cannot answer the question this record exists for — whether the
/// bike kept its settings across an outage. Nothing in the UI shows it.
@freezed
abstract class LastSeen with _$LastSeen {
  const factory LastSeen({
    required int assist,
    required bool light,
    required int wire,
  }) = _LastSeen;

  factory LastSeen.fromJson(Map<String, Object?> json) =>
      _$LastSeenFromJson(json);
}

/// What this bike's settings register really reports after a power-on.
///
/// Measured once, per bike: the firmware decides which bytes reset and which
/// come back unchanged, and that answer differs by region and by version. A
/// null byte here is a byte that came back unchanged during calibration —
/// it carries no boot news, so detection must ignore it. The staged pre-off
/// values stay so a later audit can tell what the measurement compared
/// against.
///
/// [bootLight] stays null from the old one-boot guide (`classifyBootSignature`
/// in `bike.dart`): that flow never moves light on purpose, so a single boot
/// read of it proves nothing, and its register value is untrustworthy on its
/// own. The newer two-boot capability probe (`classifyCapabilityBoot`)
/// deliberately drives light away from its boot value before the second
/// boot, which makes a real measurement possible — [bootLight] is populated
/// only by that path.
@freezed
abstract class BootSignature with _$BootSignature {
  const factory BootSignature({
    required DateTime measuredAt,
    int? bootWire,
    int? bootAssist,
    bool? bootLight,
    required int preOffWire,
    required int preOffAssist,
  }) = _BootSignature;

  factory BootSignature.fromJson(Map<String, Object?> json) =>
      _$BootSignatureFromJson(json);
}

/// What a bike accepts, measured by writing every wire, every assist level
/// and the light and reading back what stuck.
///
/// The app used to assume every bike accepts every write it sends. Some
/// firmwares refuse a mode change outright, or answer only a narrower bank
/// than the region table offers — on such a bike the mode picker did
/// nothing, silently. A bike this has never measured has `capabilities ==
/// null` on its [BikeState]; the setup flow that produces this record is the
/// gate the rest of the app checks before it trusts a mode/assist/light
/// control to do anything.
@freezed
abstract class BikeCapabilities with _$BikeCapabilities {
  const BikeCapabilities._();

  const factory BikeCapabilities({
    required DateTime measuredAt,
    required List<int> acceptedWires,
    required List<int> acceptedAssist,
    required bool lightWritable,
  }) = _BikeCapabilities;

  factory BikeCapabilities.fromJson(Map<String, Object?> json) =>
      _$BikeCapabilitiesFromJson(json);

  /// Whether there is more than one wire to choose between. A bike that only
  /// ever echoes back the wire it already sat on has nothing else a mode
  /// picker could offer.
  bool get modeWritable => acceptedWires.length > 1;

  /// Whether there is more than one assist level to choose between, for the
  /// same reason as [modeWritable].
  bool get assistWritable => acceptedAssist.length > 1;

  /// The region [acceptedWires] names, or null when it does not name one
  /// cleanly: nothing accepted, a mix of both banks, or only part of one.
  ///
  /// [BikeRegion.ch] is never returned. It has no firmware bank of its own —
  /// its only native wire is off-road, riding the EU bank — so the probe can
  /// never see it as a distinct accepted set.
  BikeRegion? get detectedRegion {
    const usWires = {0, 1, 2, 3};
    const euWires = {4, 5, 6, 7};
    final accepted = acceptedWires.toSet();
    if (usWires.every(accepted.contains) &&
        euWires.every((w) => !accepted.contains(w))) {
      return BikeRegion.us;
    }
    if (euWires.every(accepted.contains) &&
        usWires.every((w) => !accepted.contains(w))) {
      return BikeRegion.eu;
    }
    return null;
  }
}

/// The mode a CH bike is seeded with: what the old CH dynamic mode was, as a
/// custom mode. Its id is fixed so migration can recognise it.
const seededChModeId = 'seed-ch-25';
const seededChMode = CustomMode(
    id: seededChModeId, name: '25 km/h', limitKmh: 25, throttle: true);

@freezed
abstract class BikeState with _$BikeState {
  const BikeState._();
  @Assert('assist >= 0')
  @Assert('assist <= 4')
  @Assert('color >= 0')
  const factory BikeState(
      {required String id,
      // LEGACY, write only: the projection of [modeId] into the pre custom
      // modes integer. Kept in json so a downgraded build's `required int mode`
      // still parses bikes.json instead of wiping it — _readBikes drops a bike
      // it cannot read, and the next save overwrites the file.
      @JsonKey(name: 'mode') @Default(0) int legacyMode,
      // '' only pre-migration and in tests; resolution falls back.
      @Default('') String modeId,
      @Default(<CustomMode>[]) List<CustomMode> customModes,
      // The three padlocks. They keep the key names the two-state booleans
      // wrote, so the locks in an existing bikes.json survive the upgrade.
      @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson)
      @Default(PinState.open)
      PinState pinMode,
      required bool light,
      @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson)
      @Default(PinState.open)
      PinState pinLight,
      required int assist,
      @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson)
      @Default(PinState.open)
      PinState pinAssist,
      // The value each padlock pins, captured when the pin is armed. Held
      // apart from the live value, which the bike keeps moving.
      bool? startupLight,
      String? startupModeId,
      int? startupAssist,
      // Null as a group: a bike the app has never read has nothing to compare
      // a fresh read against.
      LastSeen? lastSeen,
      // Null until the rider calibrates this bike, which every existing bike
      // is: detection has nothing measured to compare a fresh read against.
      BootSignature? bootSignature,
      // Null until the rider runs the setup probe, which every existing
      // bike is: an old bikes.json has no such key, and decodes to null for
      // free — exactly like [bootSignature] above.
      BikeCapabilities? capabilities,
      required String name,
      BikeRegion? region,
      // Whether the app keeps trying to reconnect to this bike on its own.
      @Default(true) bool autoReconnect,
      @Default(0) int color}) = _BikeState;

  factory BikeState.fromJson(Map<String, Object?> json) =>
      _$BikeStateFromJson(migrateBikeJson(json));

  factory BikeState.defaultState(String id) {
    return BikeState(
        id: id,
        legacyMode: 0,
        light: false,
        assist: 0,
        name: getName(seed: id),
        region: BikeRegion.ch,
        customModes: const [seededChMode],
        modeId: seededChModeId);
  }

  /// The region's native modes plus this bike's custom ones. CH has no native
  /// mode but off-road: its limits are the app's own composition.
  ///
  /// CH lists its custom modes FIRST. Its only native mode is unlimited, and
  /// putting that at the head would make a fresh CH bike one step from
  /// off-road in the cycling mode card — and would render the limited mode as
  /// the accented one and off-road as the neutral default, the reverse of what
  /// the card has always shown. Every other region leads with its natives,
  /// whose first entry is the mildest mode.
  List<SelectedMode> get selectableModes {
    final wires = switch (region) {
      BikeRegion.eu => const [4, 5, 6, 7],
      BikeRegion.ch => const [chWireOffroad],
      // us, and a legacy bike whose region was never guessed.
      _ => const [0, 1, 2, 3],
    };
    final natives = [
      for (final w in wires) NativeSelection(profileByWire(w))
    ];
    final customs = [for (final m in customModes) CustomSelection(m)];
    return region == BikeRegion.ch
        ? [...customs, ...natives]
        : [...natives, ...customs];
  }

  /// Resolves [modeId]. A dangling or empty id resolves to [fallbackMode], so
  /// deleting a mode or downgrading a file can never leave the bike modeless.
  SelectedMode get selectedMode =>
      selectableModes.firstWhere((m) => m.id == modeId,
          orElse: () => fallbackMode);

  /// Where selection lands when the selected mode is gone: the region's slowest
  /// limited native — except CH, which has no limited native, so the first
  /// remaining custom, else the seeded one.
  ///
  /// A lost selection never grants a faster cap. CH off-road would do exactly
  /// that: deleting a mode, or loading a file whose modes are gone, would take
  /// the limiter off. Off-road is reached by picking it, never by falling back.
  SelectedMode get fallbackMode => switch (region) {
        BikeRegion.eu => NativeSelection(profileByWire(4)), // EPAC 25
        BikeRegion.ch => CustomSelection(
            customModes.isNotEmpty ? customModes.first : seededChMode),
        _ => NativeSelection(profileByWire(0)), // US Class 1, 32
      };

  /// The single choke point for selection changes: keeps [modeId] and its
  /// legacy projection in sync. Nothing else may `copyWith(modeId:)`.
  BikeState withSelectedMode(String newModeId) {
    final next = copyWith(modeId: newModeId);
    // Projected from what the id actually resolves to, not from the id itself:
    // an id this region cannot select rides [fallbackMode], and the legacy int
    // has to name the same mode or a downgrade lands somewhere else.
    return next.copyWith(legacyMode: next._legacyModeFor(next.selectedMode));
  }

  int _legacyModeFor(SelectedMode selected) {
    final wire = switch (selected) {
      NativeSelection(:final profile) => profile.wire,
      CustomSelection() => null,
    };
    return switch (region) {
      // A custom mode projects to the old dynamic mode: behaviourally closest.
      BikeRegion.ch => wire == chWireUsOffroad || wire == chWireOffroad ? 2 : 0,
      BikeRegion.eu => wire == null ? 0 : (wire - 4).clamp(0, 3).toInt(),
      _ => wire == null ? 0 : wire.clamp(0, 3).toInt(),
    };
  }

  /// Adopts the rider-owned fields of a settings read-back.
  ///
  /// The mode is deliberately NOT inferred here any more: a wire byte stopped
  /// being 1:1 with a mode when custom modes arrived, so what the reported byte
  /// means is [wireVerdict]'s job, and only the controller — which knows which
  /// half of a switching mode's pair it asserted — can ask it.
  BikeState updateFromData(List<int> data) {
    const lightIdx = 4;
    const modeIdx = 5;
    const assistIdx = 2;
    final next = copyWith(light: data[lightIdx] == 1, assist: data[assistIdx]);
    if (region != null) {
      return next;
    }
    // A legacy bike whose region was never guessed: the guess also decides
    // which bank the selection lives in, so it has to be remapped into it —
    // [selectableModes] answered with the US bank until a moment ago.
    return remapModeForRegion(next, _guessRegion(data[modeIdx]));
  }

  BikeRegion _guessRegion(int mode) {
    if (region != null) {
      return region!;
    }
    if (mode > 3) {
      return BikeRegion.eu;
    }
    return BikeRegion.us;
  }

  /// Whether any padlock holds its value against the bike.
  ///
  /// A startup pin is deliberately not one of them: it acts on one moment, so
  /// between those moments there is nothing to hold.
  bool get anyPinLocked =>
      pinMode == PinState.locked ||
      pinLight == PinState.locked ||
      pinAssist == PinState.locked;

  /// Whether this bike needs the speed stream: only a custom mode whose base
  /// and cap profiles differ has anything to switch. An exact-match custom mode
  /// is as static as a native one — no stream, no keepAlive, no auto lock.
  bool get needsSpeedSwitching => switch (selectedMode) {
        CustomSelection(:final mode) =>
          !isStaticCustomMode(mode, region: region),
        NativeSelection() => false,
      };

  /// The settings write packet, `[0, 209, light, assist, wire, 0...]`.
  ///
  /// The [wire] byte is the caller's: the app owns the mode, and which of a
  /// switching mode's two profiles is asserted right now is knowledge only the
  /// controller has.
  List<int> toWriteData({required int wire}) {
    return [0, 209, light ? 1 : 0, assist, wire, 0, 0, 0, 0, 0];
  }
}

/// Applies [newRegion] to [bike] and makes its selection valid for it.
///
/// A custom mode is the app's own composition and means the same thing in every
/// region, so it is kept. A native one moves to the same index of the new
/// region's bank (us <-> eu), and off-road stays off-road. Into CH, whose only
/// native mode is off-road, everything else falls to off-road as well: the old
/// clamp's rationale, that a region change must never hand the rider a speed
/// limiter they did not ask for. Entering CH also seeds the seeded custom mode
/// if it is gone, so a converted bike looks like a fresh one.
BikeState remapModeForRegion(BikeState bike, BikeRegion? newRegion) {
  // Resolved in the OLD region: a dangling id rides that region's fallback and
  // is remapped from there, never left dangling into the new one.
  final selected = bike.selectedMode;
  var next = bike.copyWith(region: newRegion);
  if (newRegion == BikeRegion.ch &&
      !next.customModes.any((m) => m.id == seededChModeId)) {
    next = next.copyWith(customModes: [seededChMode, ...next.customModes]);
  }
  final newModeId = switch (selected) {
    CustomSelection(:final mode) => mode.id,
    NativeSelection(:final profile) =>
      _remappedNativeId(profile.wire, newRegion),
  };
  return next.withSelectedMode(newModeId);
}

String _remappedNativeId(int wire, BikeRegion? newRegion) {
  if (wire == chWireUsOffroad || wire == chWireOffroad) {
    return nativeModeId(offroadWireFor(newRegion));
  }
  if (newRegion == BikeRegion.ch) {
    // A limited native has to stay limited: CH has no native limit, so the
    // seeded mode — just seeded above if it was gone — stands in for it.
    return seededChModeId;
  }
  final index = wire >= 4 ? wire - 4 : wire;
  return nativeModeId((newRegion == BikeRegion.eu ? 4 : 0) + index);
}

/// Old shape bikes.json (an integer `mode`, no `modeId`) to the new shape.
/// Idempotent, and a pass-through for a map that already has a selection.
///
/// The legacy `mode` int is deliberately left as it is: it stays a valid
/// downgrade projection, and rewriting it would change what the bike does.
@visibleForTesting
Map<String, Object?> migrateBikeJson(Map<String, Object?> json) {
  final out = Map<String, Object?>.from(json);
  final region = out['region']; // 200/201/202, or null on a legacy bike
  final raw = out['modeId'];
  // Null on the old shape: an integer `mode` and no selection of its own.
  final modeId = raw is String && raw.isNotEmpty ? raw : null;
  final newShape = modeId != null;
  if (region == 202) {
    // A fresh, untyped copy: inserting the seed into the caller's list would
    // throw on a list with a narrower element type.
    final rawCustoms = out['customModes'];
    final customs = <Object?>[if (rawCustoms is List) ...rawCustoms];
    final hasSeed = customs.any((c) => c is Map && c['id'] == seededChModeId);
    // On the OLD shape the seed has to be there unconditionally: the migration
    // maps the legacy CH modes 0 and 1 onto its id, so the mode it names must
    // exist. On the NEW shape only an EMPTY list is seeded — the same guard
    // deleteCustomMode and applySheetEdits apply, and for the same reason: CH
    // needs one custom mode to fall back on, but a rider who deleted the
    // built-in one in favour of their own has already provided it. Re-seeding
    // there would undo that delete on every single load, at index 0, which is
    // also where [BikeState.fallbackMode] looks.
    if (!hasSeed && (!newShape || customs.isEmpty)) {
      customs.insert(0, seededChMode.toJson());
    }
    out['customModes'] = customs;
  }
  if (modeId != null) {
    return _reconcileStaleModeId(out, modeId, region);
  }
  // Every read below is type-guarded rather than cast: a wrong-typed value
  // would throw out of BikeState.fromJson, and _readBikes drops a bike it
  // cannot read — the next save then deletes it from the file for good.
  final rawMode = out['mode'];
  final mode = (rawMode is num ? rawMode.toInt() : 0).clamp(0, 3).toInt();
  // Written back, not just used: an old build asserts mode <= 3 inside its own
  // fromJson and has no per-entry catch, so an out-of-range int costs it every
  // bike in the file. An absent key is filled in for the same reason.
  out['mode'] = mode;
  // Normalised the same way for every region, so a wrong-typed value cannot
  // throw out of the generated parse.
  final rawCustoms = out['customModes'];
  out['customModes'] = <Object?>[if (rawCustoms is List) ...rawCustoms];
  out['modeId'] = _modeIdForLegacy(mode, region);
  return out;
}

/// Repairs a selection an interim build left behind.
///
/// Between the data model landing and the engine taking the selection over, the
/// legacy `mode` int was still the live one: cycling a mode, following a
/// read-back and saving the Edit sheet all moved it while `modeId` stood still.
/// Trusting the stale id would put the bike back into a mode the rider left —
/// an unlimited one, in the worst case. A NATIVE id that does not project onto
/// the stored `mode` is therefore re-derived from it.
///
/// A custom id is trusted instead: a custom selection diverges from the legacy
/// int by design (every one of them projects onto the same mildest mode), so
/// disagreement there says nothing.
Map<String, Object?> _reconcileStaleModeId(
    Map<String, Object?> out, String modeId, Object? region) {
  final wire = nativeWireOf(modeId);
  final rawMode = out['mode'];
  // Both sides have to exist before they can disagree: a map with no usable
  // `mode` is not an interim build's, and re-deriving would invent a selection.
  if (wire == null || rawMode is! num) {
    return out;
  }
  final mode = rawMode.toInt().clamp(0, 3).toInt();
  if (_legacyOfNativeId(wire, region) == mode) {
    return out;
  }
  out['mode'] = mode;
  out['modeId'] = _modeIdForLegacy(mode, region);
  return out;
}

/// What a native selection projects onto, exactly as [BikeState.withSelectedMode]
/// does it — resolution included: an id the region cannot select dangles onto
/// that region's fallback, which is always its mildest mode, i.e. 0.
int _legacyOfNativeId(int wire, Object? region) => switch (region) {
      202 => wire == chWireOffroad ? 2 : 0,
      201 => wire >= 4 && wire <= 7 ? wire - 4 : 0,
      _ => wire >= 0 && wire <= 3 ? wire : 0,
    };

/// The selection a legacy `mode` int names, per region.
String _modeIdForLegacy(int mode, Object? region) => switch (region) {
      // CH: 0 (dynamic) and 1 (the removed static mode) both become the seeded
      // custom mode, seeded by the caller; 2 was off-road.
      202 => mode <= 1 ? seededChModeId : nativeModeId(chWireOffroad),
      201 => nativeModeId(mode + 4),
      // US, and a legacy bike whose region was never guessed.
      _ => nativeModeId(mode),
    };

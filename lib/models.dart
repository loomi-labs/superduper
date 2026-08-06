import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:superduper/names.dart';

part 'models.freezed.dart';
part 'models.g.dart';

enum BikeRegion {
  // R,RX
  @JsonValue(200)
  us('US'),
  // S2
  @JsonValue(201)
  eu('EU'),
  // Switzerland: mode 1 is a virtual mode, throttle up to ~25 km/h (see README)
  @JsonValue(202)
  ch('CH');

  const BikeRegion(this.value);
  final String value;

  int get modeCount => this == ch ? 3 : 4;
}

// The CH dynamic mode is never a real bike mode: below the threshold we ride
// US Class 2 (throttle, 20 mph); above it we switch to EPAC (25 km/h limiter).
const chSpeedThresholdKmh = 23.0;
const chWireLow = 1; // US Class 2: PAS + throttle, 20 mph
const chWireHigh = 4; // EPAC: PAS only, 25 km/h
const chWireUsOffroad = 3; // US off-road: PAS + throttle, no limit
const chWireOffroad = 7; // EU off-road: PAS + throttle, no limit

int chDynamicWire(double speedKmh, int currentWire) {
  if (speedKmh <= 0) {
    return currentWire;
  }
  return speedKmh > chSpeedThresholdKmh ? chWireHigh : chWireLow;
}

/// Whether the CH read-back has a mode for this raw wire byte, i.e. whether
/// [BikeState.updateFromData] can tell what the bike is doing.
///
/// Only the bytes the CH region itself uses are mapped. The rest of the EU bank
/// (5 = 35 km/h, 6 = 45 km/h) is still reachable — the bike has no mode button,
/// but another app (the official one writes any of 0-7) can select them, or the
/// controller can power up in one — yet means nothing in CH terms, so the
/// read-back keeps the mode it had and the app would keep claiming a limit that
/// is not there. The controller re-asserts its own mode on those bytes instead.
bool chMapsToMode(int wire) =>
    wire == chWireLow ||
    wire == chWireHigh ||
    wire == chWireUsOffroad ||
    wire == chWireOffroad;

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

@freezed
abstract class BikeState with _$BikeState {
  const BikeState._();
  @Assert('mode <= 3')
  @Assert('mode >= 0')
  @Assert('assist >= 0')
  @Assert('assist <= 4')
  @Assert('color >= 0')
  const factory BikeState(
      {required String id,
      required int mode,
      @Default(false) bool modeLocked,
      required bool light,
      @Default(false) bool lightLocked,
      required int assist,
      @Default(false) bool assistLocked,
      required String name,
      BikeRegion? region,
      @Default(false) bool modeLock,
      // Set when [modeLock] was turned on by the CH dynamic mode rather than by
      // the rider. Persisted, so an app restart still knows whose lock it is
      // and only ever turns off its own.
      @Default(false) bool modeLockAuto,
      @Default(0) int color}) = _BikeState;

  factory BikeState.fromJson(Map<String, Object?> json) =>
      _$BikeStateFromJson(json);

  factory BikeState.defaultState(String id) {
    return BikeState(
        id: id,
        mode: 0,
        light: false,
        assist: 0,
        name: getName(seed: id),
        region: BikeRegion.ch);
  }

  BikeState updateFromData(List<int> data) {
    const lightIdx = 4;
    const modeIdx = 5;
    const assistIdx = 2;
    final region = _guessRegion(data[modeIdx]);
    final newmode = _modeFromRead(data[modeIdx], region);
    return copyWith(
        light: data[lightIdx] == 1,
        mode: newmode,
        assist: data[assistIdx],
        region: region);
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

  int _modeToWrite({required bool belowThreshold}) {
    switch (region) {
      case BikeRegion.eu:
        return mode + 4;
      case BikeRegion.ch:
        switch (mode) {
          case 0:
            return belowThreshold ? chWireLow : chWireHigh;
          case 1:
            return chWireLow;
          default:
            return chWireOffroad;
        }
      default:
        return mode;
    }
  }

  int _modeFromRead(int wire, BikeRegion region) {
    if (region == BikeRegion.ch) {
      switch (wire) {
        case chWireHigh:
          return 0;
        case chWireLow:
          // Ambiguous: dynamic mode below threshold writes the same byte as
          // mode 2. Stay in dynamic mode if it is active.
          return mode == 0 ? 0 : 1;
        case chWireUsOffroad:
        case chWireOffroad:
          return 2;
        default:
          return mode;
      }
    }
    if (wire > 3) {
      return wire - 4;
    }
    return wire;
  }

  String get viewMode {
    return "${mode + 1}";
  }

  int get modeCount {
    return region?.modeCount ?? 4;
  }

  int get nextMode {
    return (mode + 1) % modeCount;
  }

  bool get isDynamicMode {
    return region == BikeRegion.ch && mode == 0;
  }

  List<int> toWriteData({bool belowThreshold = true}) {
    return [
      0,
      209,
      light ? 1 : 0,
      assist,
      _modeToWrite(belowThreshold: belowThreshold),
      0,
      0,
      0,
      0,
      0
    ];
  }
}

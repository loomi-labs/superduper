import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:superduper/utils/logger.dart';

part 'fake_bike.g.dart';

/// Device ids of fake bikes start with this prefix. 'ke' is not valid hex, so
/// it can never collide with a real MAC address.
const fakeBikeIdPrefix = 'fa:ke:';

/// True only in debug builds, for ids created by the debug console.
bool isFakeBike(String deviceId) =>
    kDebugMode && deviceId.startsWith(fakeBikeIdPrefix);

/// In-memory stand-in for a bike's state register. Kept alive so it survives
/// the auto-dispose of ConnectionHandler.
@Riverpod(keepAlive: true)
FakeBikeStore fakeBikeStore(Ref ref) => FakeBikeStore();

class FakeBikeStore {
  /// Layout matches what the bike returns for register 3: index 2 is assist,
  /// index 4 is light, index 5 is the raw (region offset) mode.
  static const _defaultRegister = [3, 0, 0, 0, 0, 0, 0, 0, 0, 0];

  static const _assistIdx = 2;
  static const _lightIdx = 4;
  static const _modeIdx = 5;

  final Map<String, List<int>> _registers = {};

  List<int> _register(String deviceId) =>
      _registers.putIfAbsent(deviceId, () => List<int>.from(_defaultRegister));

  /// Current register contents, as a real read would return them.
  List<int> read(String deviceId) {
    final register = List<int>.unmodifiable(_register(deviceId));
    log.d(SDLogger.bluetooth, 'Fake bike $deviceId read: $register');
    return register;
  }

  /// Echoes a state write ([0, 209, light, assist, mode, 0...]) back into the
  /// register so a following read returns what was written.
  void write(String deviceId, List<int> data) {
    if (data.length < 5 || data[0] != 0 || data[1] != 209) {
      log.d(SDLogger.bluetooth, 'Fake bike $deviceId ignored write: $data');
      return;
    }
    final register = _register(deviceId);
    register[_lightIdx] = data[2];
    register[_assistIdx] = data[3];
    register[_modeIdx] = data[4];
    log.d(SDLogger.bluetooth, 'Fake bike $deviceId write: $data');
  }

  /// The rider flipped the light on the bike itself.
  void toggleLight(String deviceId) {
    final register = _register(deviceId);
    register[_lightIdx] = register[_lightIdx] == 1 ? 0 : 1;
    log.d(SDLogger.bluetooth, 'Fake bike $deviceId light: $register');
  }

  /// The rider changed the mode on the bike itself. Preserves the EU offset.
  void cycleMode(String deviceId) {
    final register = _register(deviceId);
    final raw = register[_modeIdx];
    register[_modeIdx] = raw > 3 ? 4 + ((raw - 4 + 1) % 4) : (raw + 1) % 4;
    log.d(SDLogger.bluetooth, 'Fake bike $deviceId mode: $register');
  }

  /// The rider changed the assist level on the bike itself.
  void cycleAssist(String deviceId) {
    final register = _register(deviceId);
    register[_assistIdx] = (register[_assistIdx] + 1) % 5;
    log.d(SDLogger.bluetooth, 'Fake bike $deviceId assist: $register');
  }
}

/// The off time and the bike on time across one link loss.
final class LinkGap {
  const new({
    required this.offTime,
    required this.onTime,
    required this.fromCounter,
  });

  final Duration offTime;

  /// The bike on time from the auxiliary counter, or null without counter
  /// samples on both sides of the loss.
  final Duration? onTime;
  final bool fromCounter;

  /// A restart with a true off time of 10 s or less. The window depends on
  /// the source of the measurement.
  bool get quickRestart =>
      offTime <=
      (fromCounter ? OffTimeMeter.counterWindow : OffTimeMeter.phoneWindow);
}

/// Measures how long the bike was off across one unexpected link loss.
///
/// The auxiliary counter adds 1 each second while the bike is on. The phone
/// clock measures the total time between the same two samples. The
/// difference is the off time. Without a counter sample on both sides, the
/// meter uses the phone clock from the last notification before the loss.
final class OffTimeMeter {
  new({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// The counter off time includes 3.5 to 7.5 s of shutdown and boot. A
  /// true off time of 10 s gives 18 s or less (probe of 2026-10-03).
  static const counterWindow = Duration(seconds: 18);

  /// The phone gap of a 5 s restart was up to 20.5 s in the probe.
  static const phoneWindow = Duration(seconds: 25);

  static const _counterModulo = 0x10000;
  static const _resetTolerance = Duration(seconds: 2);

  final DateTime Function() _clock;
  DateTime? _lastSeenAt;
  _CounterSample? _lastCounter;
  DateTime? _lostSeenAt;
  _CounterSample? _lostCounter;
  _CounterSample? _firstCounterAfterLoss;

  /// True when a counter sample from before the loss exists and the first
  /// sample after the reconnect did not arrive yet.
  bool get awaitsCounterSample =>
      _lostCounter != null && _firstCounterAfterLoss == null;

  /// Any notification of the bike: telemetry or counter.
  void recordNotification() {
    _lastSeenAt = _clock();
  }

  void recordCounter(int counter) {
    final sample = (value: counter, at: _clock());
    _lastSeenAt = sample.at;
    _lastCounter = sample;
    if (_lostSeenAt != null) {
      _firstCounterAfterLoss ??= sample;
    }
  }

  /// An unexpected link loss. While no gap is taken, the samples from before
  /// the first loss stay: the counter difference is right across all losses.
  /// A loss without a new sample since the last loss changes nothing.
  void linkLost() {
    if (_lastSeenAt == null) {
      return;
    }
    if (_lostSeenAt == null) {
      _lostSeenAt = _lastSeenAt;
      _lostCounter = _lastCounter;
    }
    _firstCounterAfterLoss = null;
    _lastSeenAt = null;
    _lastCounter = null;
  }

  /// A deliberate disconnect: the next connect has an unknown off time.
  void clear() {
    _lastSeenAt = null;
    _lastCounter = null;
    _lostSeenAt = null;
    _lostCounter = null;
    _firstCounterAfterLoss = null;
  }

  /// The gap of the last loss, or null when it is unknown. [readAt] is the
  /// time of the configuration read, for the phone-clock fallback. Each
  /// loss gives one gap only.
  LinkGap? takeGap(DateTime readAt) {
    final lostSeenAt = _lostSeenAt;
    final before = _lostCounter;
    final after = _firstCounterAfterLoss;
    _lostSeenAt = null;
    _lostCounter = null;
    _firstCounterAfterLoss = null;
    if (lostSeenAt == null) {
      return null;
    }
    if (before != null && after != null) {
      final phoneGap = after.at.difference(before.at);
      var onSeconds = (after.value - before.value) % _counterModulo;
      if (Duration(seconds: onSeconds) > phoneGap + _resetTolerance) {
        // The bike cannot be on for longer than the phone gap: the counter
        // started again at the bike start.
        onSeconds = after.value;
      }
      final onTime = Duration(seconds: onSeconds);
      return LinkGap(
        offTime: _notNegative(phoneGap - onTime),
        onTime: onTime,
        fromCounter: true,
      );
    }
    return LinkGap(
      offTime: _notNegative(readAt.difference(lostSeenAt)),
      onTime: null,
      fromCounter: false,
    );
  }

  static Duration _notNegative(Duration value) =>
      value.isNegative ? Duration.zero : value;
}

typedef _CounterSample = ({int value, DateTime at});

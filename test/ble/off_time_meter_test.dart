import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/ble/off_time_meter.dart';

void main() {
  late DateTime now;
  late OffTimeMeter meter;

  setUp(() {
    now = DateTime(2026, 10, 3, 12);
    meter = OffTimeMeter(clock: () => now);
  });

  void advance(Duration duration) => now = now.add(duration);

  test('the off time is the phone gap minus the counter on time', () {
    // Probe row 4: a phone gap of 20.47 s, of which the bike was on for 8 s.
    meter
      ..recordCounter(10161)
      ..linkLost();
    advance(const Duration(milliseconds: 20470));
    meter.recordCounter(10169);

    final gap = meter.takeGap(now)!;

    expect(gap.fromCounter, isTrue);
    expect(gap.onTime, const Duration(seconds: 8));
    expect(gap.offTime, const Duration(milliseconds: 12470));
    expect(gap.quickRestart, isTrue);
  });

  test('a counter off time above 18 seconds is not a quick restart', () {
    meter
      ..recordCounter(100)
      ..linkLost();
    advance(const Duration(seconds: 22));
    meter.recordCounter(103);

    final gap = meter.takeGap(now)!;

    expect(gap.offTime, const Duration(seconds: 19));
    expect(gap.quickRestart, isFalse);
  });

  test('the counter difference wraps at 65536', () {
    meter
      ..recordCounter(65534)
      ..linkLost();
    advance(const Duration(seconds: 10));
    meter.recordCounter(2);

    final gap = meter.takeGap(now)!;

    expect(gap.onTime, const Duration(seconds: 4));
    expect(gap.offTime, const Duration(seconds: 6));
  });

  test('a counter that started again gives the time since the bike start', () {
    meter
      ..recordCounter(40000)
      ..linkLost();
    advance(const Duration(seconds: 15));
    meter.recordCounter(5);

    final gap = meter.takeGap(now)!;

    expect(gap.onTime, const Duration(seconds: 5));
    expect(gap.offTime, const Duration(seconds: 10));
    expect(gap.quickRestart, isTrue);
  });

  test('a dropout gives an off time near 0', () {
    meter
      ..recordCounter(500)
      ..linkLost();
    advance(const Duration(milliseconds: 8010));
    meter.recordCounter(508);

    final gap = meter.takeGap(now)!;

    expect(gap.onTime, const Duration(seconds: 8));
    expect(gap.offTime, const Duration(milliseconds: 10));
  });

  test('the off time is never negative', () {
    meter
      ..recordCounter(500)
      ..linkLost();
    advance(const Duration(seconds: 3));
    meter.recordCounter(504);

    expect(meter.takeGap(now)!.offTime, Duration.zero);
  });

  test('without a sample before the loss the off time is unknown', () {
    meter.linkLost();
    advance(const Duration(seconds: 5));
    meter.recordCounter(10);

    expect(meter.takeGap(now), isNull);
  });

  test('without a counter sample after the loss the phone clock decides', () {
    meter.recordCounter(100);
    advance(const Duration(seconds: 1));
    meter
      ..recordNotification()
      ..linkLost();
    expect(meter.awaitsCounterSample, isTrue);
    advance(const Duration(seconds: 24));

    final gap = meter.takeGap(now)!;

    expect(gap.fromCounter, isFalse);
    expect(gap.onTime, isNull);
    expect(gap.offTime, const Duration(seconds: 24));
    expect(gap.quickRestart, isTrue);
  });

  test('without the counter the window is 25 seconds', () {
    meter
      ..recordNotification()
      ..linkLost();
    expect(meter.awaitsCounterSample, isFalse);
    advance(const Duration(seconds: 26));

    final gap = meter.takeGap(now)!;

    expect(gap.fromCounter, isFalse);
    expect(gap.quickRestart, isFalse);
  });

  test('a deliberate disconnect clears the samples', () {
    meter
      ..recordCounter(100)
      ..linkLost()
      ..clear();
    advance(const Duration(seconds: 5));
    meter.recordCounter(102);

    expect(meter.takeGap(now), isNull);
  });

  test('a second loss without a new sample keeps the first samples', () {
    meter
      ..recordCounter(100)
      ..linkLost();
    advance(const Duration(seconds: 4));
    meter.linkLost();
    advance(const Duration(seconds: 4));
    meter.recordCounter(102);

    expect(meter.takeGap(now)!.offTime, const Duration(seconds: 6));
  });

  test('each loss gives one gap only', () {
    meter
      ..recordCounter(100)
      ..linkLost();
    advance(const Duration(seconds: 5));
    meter.recordCounter(102);

    expect(meter.takeGap(now), isNotNull);
    expect(meter.takeGap(now), isNull);
  });

  test('a second loss before the decision keeps the first samples', () {
    // A slow restart of 37 s off, then a dropout before the decision.
    meter
      ..recordCounter(1000)
      ..linkLost();
    advance(const Duration(seconds: 40));
    meter
      ..recordCounter(1003)
      ..linkLost();
    advance(const Duration(seconds: 2));
    meter.recordCounter(1005);

    final gap = meter.takeGap(now)!;

    expect(gap.onTime, const Duration(seconds: 5));
    expect(gap.offTime, const Duration(seconds: 37));
    expect(gap.quickRestart, isFalse);
  });

  test('a loss after a taken gap uses the new samples', () {
    meter
      ..recordCounter(1000)
      ..linkLost();
    advance(const Duration(seconds: 5));
    meter.recordCounter(1002);
    expect(meter.takeGap(now), isNotNull);

    advance(const Duration(seconds: 30));
    meter
      ..recordCounter(1032)
      ..linkLost();
    advance(const Duration(seconds: 3));
    meter.recordCounter(1035);

    expect(meter.takeGap(now)!.offTime, Duration.zero);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/domain/ride_modes.dart';
import 'package:superduper/src/widgets/ride_mode_selector.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets(
    'shows custom modes first, labels natives by speed, taps select',
    (tester) async {
      RideModeSelection? tapped;
      await tester.pumpWidget(
        host(
          RideModeSelector(
            options: selectableRideModes(
              region: BikeRegion.ch,
              customModes: const [seededChMode],
            ),
            selected: const CustomRideMode(seededChMode),
            region: BikeRegion.ch,
            enabled: true,
            onSelected: (selection) => tapped = selection,
          ),
        ),
      );
      expect(find.text('25 km/h'), findsOneWidget);
      expect(find.text('OFFROAD'), findsOneWidget);
      await tester.tap(find.text('OFFROAD'));
      expect(tapped, const NativeRideMode(7));
    },
  );

  testWidgets('a foreign observed wire is shown as an extra selected chip', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        RideModeSelector(
          options: selectableRideModes(
            region: BikeRegion.ch,
            customModes: const [],
          ),
          selected: const NativeRideMode(1),
          region: BikeRegion.ch,
          enabled: true,
          observedWire: 1,
          onSelected: (_) {},
        ),
      ),
    );
    expect(find.text('32 km/h + throttle'), findsOneWidget);
  });

  testWidgets('disabled chips do not call back', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        RideModeSelector(
          options: selectableRideModes(
            region: BikeRegion.us,
            customModes: const [],
          ),
          selected: null,
          region: BikeRegion.us,
          enabled: false,
          onSelected: (_) => calls++,
        ),
      ),
    );
    await tester.tap(find.text('20 mph'));
    expect(calls, 0);
  });
}

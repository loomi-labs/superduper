import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/domain/ride_modes.dart';
import 'package:superduper/src/features/bike_settings/custom_mode_editor.dart';

void main() {
  Future<CustomMode?> open(
    WidgetTester tester, {
    required CustomMode mode,
    required BikeRegion region,
    bool autoName = false,
  }) async {
    CustomMode? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCustomModeEditor(
                  context,
                  mode: mode,
                  region: region,
                  autoName: autoName,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('auto name follows the limit until the rider types', (
    tester,
  ) async {
    await open(
      tester,
      mode: const CustomMode(id: 'n', name: '25 km/h', limitKmh: 25),
      region: BikeRegion.ch,
      autoName: true,
    );
    await tester.tap(find.byKey(const Key('custom-mode-plus')));
    await tester.pump();
    expect(find.widgetWithText(TextField, '26 km/h'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('custom-mode-name')),
      'Commute',
    );
    await tester.tap(find.byKey(const Key('custom-mode-plus')));
    await tester.pump();
    expect(find.widgetWithText(TextField, 'Commute'), findsOneWidget);
  });

  testWidgets('US bikes edit in mph', (tester) async {
    await open(
      tester,
      mode: const CustomMode(id: 'n', name: 'x', limitKmh: 32),
      region: BikeRegion.us,
    );
    expect(find.text('20 mph'), findsOneWidget);
  });

  testWidgets('dropout caption names the exact profile for a static mode', (
    tester,
  ) async {
    await open(
      tester,
      mode: const CustomMode(id: 'n', name: 'x', limitKmh: 32, throttle: true),
      region: BikeRegion.ch,
    );
    expect(find.textContaining('TOUR'), findsOneWidget);
  });

  testWidgets('save returns the edited mode', (tester) async {
    CustomMode? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showCustomModeEditor(
                  context,
                  mode: const CustomMode(id: 'n', name: 'x', limitKmh: 30),
                  region: BikeRegion.ch,
                  autoName: false,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('custom-mode-throttle')));
    await tester.tap(find.byKey(const Key('custom-mode-save')));
    await tester.pumpAndSettle();
    expect(
      result,
      const CustomMode(id: 'n', name: 'x', limitKmh: 30, throttle: true),
    );
  });
}

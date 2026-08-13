import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/theme.dart';
import 'package:superduper/widgets.dart';

/// [StatusPill] on a saved bike's row: solid green when the bike is already
/// linked, an animated outline when it merely answers the scan, and (tested
/// through [DiscoverCard]) nothing at all otherwise.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(backgroundColor: SDSurface.page, body: child)));

  tearDown(() {
    // Undoes accessibilityFeaturesTestValue between tests: left set, it would
    // leak reduced motion into every test that runs after it.
    TestWidgetsFlutterBinding.instance.platformDispatcher
        .clearAccessibilityFeaturesTestValue();
  });

  testWidgets('connected renders a solid pill with no ticking',
      (tester) async {
    await pump(tester, const StatusPill.connected());

    expect(find.text('Connected'), findsOneWidget);
    // No AnimationController lives here at all, so a couple of idle pumps
    // must leave nothing scheduled — the leak check below (inRange) is what
    // actually proves disposal; this just proves the static variant never
    // starts a ticker in the first place.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('inRange renders an outlined pill with the label',
      (tester) async {
    await pump(tester, const StatusPill.inRange());

    expect(find.text('In range'), findsOneWidget);
  });

  testWidgets('inRange stops animating under reduced motion', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);

    await pump(tester, const StatusPill.inRange());
    // Let any first-frame work finish; a still pill schedules nothing beyond
    // that, unlike the moving arc, which would keep asking for more frames.
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));

    expect(tester.binding.hasScheduledFrame, isFalse,
        reason: 'reduced motion must stop the controller, not just skip '
            'painting its result');
  });

  testWidgets('inRange animates when motion is not reduced', (tester) async {
    await pump(tester, const StatusPill.inRange());
    await tester.pump();

    // The repeating controller keeps asking for another frame; a frame
    // pumped partway through the cycle must still have one scheduled.
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });

  testWidgets('mounting and unmounting several inRange pills leaks nothing',
      (tester) async {
    for (var i = 0; i < 5; i++) {
      await pump(tester, StatusPill.inRange(key: ValueKey(i)));
      await tester.pump();
    }
    // Swap to a widget tree with no pill at all. flutter_test's own binding
    // fails the test automatically if any AnimationController's ticker
    // outlived the State that created it.
    await pump(tester, const SizedBox.shrink());
    await tester.pump();
  });

  group('DiscoverCard.trailing', () {
    Future<void> pumpCard(WidgetTester tester, {Widget? trailing}) => pump(
        tester,
        DiscoverCard(
          title: 'Fast Otter',
          subtitle: 'AA:BB:CC:DD:EE:FF',
          titleIcon: Icons.directions_bike,
          trailing: trailing,
        ));

    testWidgets('with trailing: null renders exactly as before',
        (tester) async {
      await pumpCard(tester);

      expect(find.text('Fast Otter'), findsOneWidget);
      expect(find.text('AA:BB:CC:DD:EE:FF'), findsOneWidget);
      expect(find.byType(StatusPill), findsNothing);
      expect(find.text('Connected'), findsNothing);
      expect(find.text('In range'), findsNothing);
    });

    testWidgets('with a StatusPill.connected shows the pill',
        (tester) async {
      await pumpCard(tester, trailing: const StatusPill.connected());

      expect(find.text('Fast Otter'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('with a StatusPill.inRange shows the pill', (tester) async {
      await pumpCard(tester, trailing: const StatusPill.inRange());

      expect(find.text('Fast Otter'), findsOneWidget);
      expect(find.text('In range'), findsOneWidget);
    });
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/db.dart';
import 'package:superduper/debug.dart';

/// The debug page's "simulate a power cycle" button ([_simulatePowerCycle] in
/// debug.dart) fires a bare 400 ms [Timer] to flip a fake bike back to
/// connected. If the page — and the provider container behind it — go away
/// inside that window (a hot restart, the developer navigating off the
/// page), the timer must not throw trying to touch a torn-down provider: it
/// is dev-only tooling with no user-facing surface to report an error to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const id = 'fa:ke:aa:bb:cc:dd';

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_debug_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  testWidgets(
      'a torn-down debug page does not throw when the power-cycle timer '
      'fires', (tester) async {
    final container = ProviderContainer();
    container
        .read(bikesDBProvider.notifier)
        .saveBike(BikeState.defaultState(id));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DebugPage()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Simulate a power cycle'));
    await tester.pump();

    // Tear the page and its container down while the 400 ms timer is still
    // pending — standing in for a hot restart or the developer navigating
    // away mid-simulation.
    await tester.pumpWidget(const SizedBox());
    container.dispose();

    // Advancing past the timer must not throw: an unguarded callback here
    // fails this test on its own via an unhandled error in the fire-and-
    // forget Timer callback, with nothing else needed to assert.
    await tester.pump(const Duration(milliseconds: 500));
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/diagnostics/debug_log.dart';
import 'package:superduper/src/domain/bike.dart';
import 'package:superduper/src/features/bike_settings/debug_log_section.dart';

void main() {
  late Directory directory;
  late DebugLogStore store;

  SavedBike bike({bool enabled = false}) => SavedBike(
    bike: Bike(
      deviceId: 'aa:bb',
      displayName: 'B',
      protocol: BikeProtocolVersion.v1,
      region: BikeRegion.ch,
      color: BikeColor.values.first,
      sortOrder: 0,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      lastConnectedAt: null,
    ),
    setOnConnect: const SetOnConnect(),
    debugLogEnabled: enabled,
  );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('debug_log_section');
    store = DebugLogStore(directory: directory);
  });

  tearDown(() {
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester, {
    SavedBike? saved,
    Future<void> Function(bool)? onToggle,
    Future<void> Function(Rect?)? shareLog,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DebugLogSection(
              saved: saved ?? bike(),
              store: store,
              onToggle: onToggle ?? (_) async {},
              shareLog: shareLog ?? (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  void writeLog() {
    File('${directory.path}/AA_BB.log').writeAsStringSync(
      '2026-10-08 10:00:00.000+00:00 D g1  app     a\n'
      '2026-10-08 10:30:00.000+00:00 D g1  app     b\n',
    );
  }

  testWidgets('the switch calls onToggle with the new value', (tester) async {
    bool? toggled;
    await pump(tester, onToggle: (value) async => toggled = value);

    await tester.tap(find.byKey(const Key('debug-log-switch')));
    await tester.pump();

    expect(toggled, isTrue);
  });

  testWidgets('without a log the text says so and share is off', (
    tester,
  ) async {
    await pump(tester);

    expect(find.text('No log yet.'), findsOneWidget);
    final share = tester.widget<FilledButton>(
      find.byKey(const Key('debug-log-share')),
    );
    expect(share.onPressed, isNull);
  });

  testWidgets('share is on while the log is off, when files exist', (
    tester,
  ) async {
    writeLog();
    var shared = 0;
    await pump(tester, shareLog: (_) async => shared++);

    expect(find.textContaining('Log size:'), findsOneWidget);
    await tester.tap(find.byKey(const Key('debug-log-share')));
    await tester.pump();

    expect(shared, 1);
  });

  testWidgets('clear asks first, then deletes the files', (tester) async {
    writeLog();
    await pump(tester);

    await tester.tap(find.byKey(const Key('debug-log-clear')));
    await tester.pumpAndSettle();
    expect(find.text('Clear the debug log?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(File('${directory.path}/AA_BB.log').existsSync(), isTrue);

    await tester.tap(find.byKey(const Key('debug-log-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(File('${directory.path}/AA_BB.log').existsSync(), isFalse);
    expect(find.text('No log yet.'), findsOneWidget);
  });

  testWidgets('the summary follows new lines', (tester) async {
    await pump(tester);
    expect(find.text('No log yet.'), findsOneWidget);

    store
      ..setEnabled('aa:bb', enabled: true)
      ..flush();
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Log size:'), findsOneWidget);
  });
}

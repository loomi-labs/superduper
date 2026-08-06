import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/db.dart';
import 'package:superduper/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_db_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tempDir.path,
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('saveBike notifies watchers so lists rebuild', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    var notifications = 0;
    container.listen(bikesDBProvider, (previous, next) => notifications++);

    container
        .read(bikesDBProvider.notifier)
        .saveBike(BikeState.defaultState('fa:ke:01:02:03:04'));

    expect(container.read(bikesDBProvider), hasLength(1));
    expect(notifications, greaterThan(0),
        reason: 'watchers of bikesDBProvider must rebuild on save');

    // Let the fire-and-forget file IO settle before tearDown removes the dir.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('deleteBike notifies watchers so lists rebuild', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final bike = BikeState.defaultState('fa:ke:01:02:03:04');
    final db = container.read(bikesDBProvider.notifier);
    db.saveBike(bike);

    var notifications = 0;
    container.listen(bikesDBProvider, (previous, next) => notifications++);

    db.deleteBike(bike);

    expect(container.read(bikesDBProvider), isEmpty);
    expect(notifications, greaterThan(0),
        reason: 'watchers of bikesDBProvider must rebuild on delete');

    // Let the fire-and-forget file IO settle before tearDown removes the dir.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
}

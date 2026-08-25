import 'dart:convert';
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

  /// Reads bikes.json through a fresh container, after the async load settled.
  Future<List<BikeState>> readBikes() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(bikesDBProvider.notifier).ready;
    return container.read(bikesDBProvider);
  }

  test('one unreadable entry does not cost the rider the other bikes',
      () async {
    final good = BikeState.defaultState('fa:ke:01:02:03:04');
    File('${tempDir.path}/bikes.json').writeAsStringSync(jsonEncode([
      {'id': 'broken'},
      'not even a map',
      good.toJson(),
    ]));

    final bikes = await readBikes();

    expect(bikes, [good],
        reason: 'dropping every bike would let the next save overwrite them');
  });

  test('an unreadable file reads as no bikes', () async {
    File('${tempDir.path}/bikes.json').writeAsStringSync('}{ not json');
    expect(await readBikes(), isEmpty);
  });

  test('a save round-trips through the temp file and leaves none behind',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final bike = BikeState.defaultState('fa:ke:01:02:03:04');
    final db = container.read(bikesDBProvider.notifier);
    db.saveBike(bike);
    // A save made before the file has landed is replayed on the loaded list,
    // and only then written. So the write starts once the load is done.
    await db.ready;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await readBikes(), [bike]);
    expect(File('${tempDir.path}/bikes.json.tmp').existsSync(), isFalse,
        reason: 'the temp file is renamed onto the target, not left around');
  });

  test('a save goes through the temp file, leftover and all', () async {
    // What a kill mid-write leaves behind. The next save has to overwrite it
    // rather than trip over it — and consume it, which is what pins the write
    // as tmp-then-rename rather than a truncate in place.
    final tmp = File('${tempDir.path}/bikes.json.tmp');
    tmp.writeAsStringSync('[{"id":');

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final bike = BikeState.defaultState('fa:ke:01:02:03:04');
    final db = container.read(bikesDBProvider.notifier);
    db.saveBike(bike);
    await db.ready;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await readBikes(), [bike]);
    expect(tmp.existsSync(), isFalse,
        reason: 'the save has to be a rename of the temp file: a truncating '
            'write that a kill interrupts reads back as no bikes at all, and '
            'the next save would persist that over every bike');
  });

  /// Writes [bikes] to bikes.json, as a previous run left them.
  void seedBikes(List<BikeState> bikes) {
    File('${tempDir.path}/bikes.json').writeAsStringSync(jsonEncode(bikes));
  }

  test('a delete before the load keeps the other bike', () async {
    final one = BikeState.defaultState('fa:ke:01:02:03:04');
    final two = BikeState.defaultState('fa:ke:05:06:07:08');
    seedBikes([one, two]);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    // The first read starts the file read. The delete lands before the file
    // does, so the list the delete works on is still empty.
    final db = container.read(bikesDBProvider.notifier);
    expect(container.read(bikesDBProvider), isEmpty);
    db.deleteBike(one);

    await db.ready;
    expect(container.read(bikesDBProvider), [two],
        reason: 'a delete before the load must not drop the other bike');

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await readBikes(), [two],
        reason: 'the file must keep the other bike too');
  });

  test('a save before the load keeps the bike the file holds', () async {
    final stored = BikeState.defaultState('fa:ke:01:02:03:04');
    final fresh = BikeState.defaultState('fa:ke:05:06:07:08');
    seedBikes([stored]);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final db = container.read(bikesDBProvider.notifier);
    expect(container.read(bikesDBProvider), isEmpty);
    db.saveBike(fresh);

    await db.ready;
    expect(container.read(bikesDBProvider), [stored, fresh],
        reason: 'a save before the load must not drop the stored bike');

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await readBikes(), [stored, fresh],
        reason: 'the file must hold both bikes');
  });

  test('isLoaded turns true when the file lands', () async {
    seedBikes([BikeState.defaultState('fa:ke:01:02:03:04')]);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final db = container.read(bikesDBProvider.notifier);
    expect(db.isLoaded, isFalse,
        reason: 'the file read has not landed on the first read');

    await db.ready;
    expect(db.isLoaded, isTrue);
  });

  test('overlapping saves do not race each other through the temp file',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final db = container.read(bikesDBProvider.notifier);
    // Fire-and-forget, back to back: one shared temp path, so an unserialized
    // second rename would find nothing to rename.
    final first = BikeState.defaultState('fa:ke:01:02:03:04');
    final second = first.copyWith(name: 'Second');
    db.saveBike(first);
    db.saveBike(second);
    await db.ready;
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(await readBikes(), [second],
        reason: 'the last save wins, and neither of them fails');
  });
}

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:superduper/src/diagnostics/debug_log.dart';
import 'package:superduper/src/domain/bike.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('debug_log_test');
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  DebugLogStore build({
    int maxBytes = 2 * 1024 * 1024,
    DateTime Function()? now,
  }) => DebugLogStore(
    directory: directory,
    maxBytes: maxBytes,
    now: now ?? () => DateTime.utc(2026, 10, 8, 14, 3, 12, 345),
  );

  test('file id upper-cases the device id and replaces other characters', () {
    expect(debugLogFileId('aa:bb-01'), 'AA_BB_01');
  });

  test('a line has time, source, generation, area and message', () {
    final line = formatDebugLogLine(
      time: DateTime.utc(2026, 10, 8, 14, 3, 12, 345),
      source: 'D',
      area: 'lock',
      message: 'marker=0 -> lock ON',
      generation: 12,
    );
    expect(
      line,
      '2026-10-08 14:03:12.345+00:00 D g12 lock    marker=0 -> lock ON',
    );
  });

  test('a line without generation shows dashes', () {
    final line = formatDebugLogLine(
      time: DateTime.utc(2026, 10, 8),
      source: 'N',
      area: 'native',
      message: 'x',
    );
    expect(line, contains(' N --  native  x'));
  });

  test('a disabled bike writes nothing', () {
    final store = build();
    store.forBike('AA').log('app', 'hello');
    store.flush();
    expect(directory.listSync(), isEmpty);
    store.dispose();
  });

  test('an enabled bike writes after flush, not before', () {
    final store = build()..setEnabled('AA', enabled: true);
    store.forBike('AA').log('app', 'hello', generation: 1);
    final file = File('${directory.path}/AA.log');
    expect(file.existsSync() ? file.readAsStringSync() : '', isEmpty);
    store.flush();
    expect(file.readAsStringSync(), contains('D g1  app     hello'));
    store.dispose();
  });

  test('the buffer flushes after 2 seconds', () {
    fakeAsync((async) {
      final store = build()..setEnabled('AA', enabled: true);
      store.forBike('AA').log('app', 'hello');
      final file = File('${directory.path}/AA.log');
      async.elapse(const Duration(seconds: 1));
      expect(file.existsSync(), isFalse);
      async.elapse(const Duration(seconds: 2));
      expect(file.readAsStringSync(), contains('hello'));
      store.dispose();
    });
  });

  test('the buffer flushes at 50 lines', () {
    final store = build()..setEnabled('AA', enabled: true);
    final log = store.forBike('AA');
    for (var i = 0; i < 50; i++) {
      log.log('app', 'line $i');
    }
    final file = File('${directory.path}/AA.log');
    expect(file.readAsLinesSync(), hasLength(50));
    store.dispose();
  });

  test('turning off keeps the file and stops the log', () {
    final store = build()..setEnabled('AA', enabled: true);
    store.forBike('AA').log('app', 'one');
    store.setEnabled('AA', enabled: false);
    store.forBike('AA').log('app', 'two');
    store.flush();
    final text = File('${directory.path}/AA.log').readAsStringSync();
    expect(text, contains('one'));
    expect(text, contains('log stopped'));
    expect(text, isNot(contains('two')));
    store.dispose();
  });

  test('rotation moves the file to .1.log at the size limit', () {
    final store = build(maxBytes: 400)..setEnabled('AA', enabled: true);
    final log = store.forBike('AA');
    for (var i = 0; i < 20; i++) {
      log.log('app', 'line $i padding padding padding');
      store.flush();
    }
    expect(File('${directory.path}/AA.1.log').existsSync(), isTrue);
    final current = File('${directory.path}/AA.log');
    expect(current.lengthSync(), lessThan(600));
    expect(directory.listSync().whereType<File>(), hasLength(2));
    store.dispose();
  });

  test('merge orders the four files by time, stable', () {
    final store = build();
    File('${directory.path}/AA.1.log')
        .writeAsStringSync('2026-10-08 10:00:00.000+00:00 D g1 app     a\n');
    File('${directory.path}/AA.log').writeAsStringSync(
      '2026-10-08 10:00:03.000+00:00 D g1 app     c\n'
      '2026-10-08 10:00:03.000+00:00 D g1 app     d\n',
    );
    File('${directory.path}/AA.native.log')
        .writeAsStringSync('2026-10-08 10:00:02.000+00:00 N --  native  b\n');
    final merged = store.mergedLines('AA');
    expect(merged.map((l) => l.substring(l.length - 1)).toList(), [
      'a',
      'b',
      'c',
      'd',
    ]);
    store.dispose();
  });

  test('clear deletes the four files', () {
    final store = build();
    for (final name in [
      'AA.log',
      'AA.1.log',
      'AA.native.log',
      'AA.native.1.log',
    ]) {
      File('${directory.path}/$name').writeAsStringSync('x\n');
    }
    File('${directory.path}/BB.log').writeAsStringSync('x\n');
    store.clear('AA');
    expect(directory.listSync().map((e) => e.uri.pathSegments.last), [
      'BB.log',
    ]);
    store.dispose();
  });

  test('summary gives size and time span', () async {
    final store = build();
    File('${directory.path}/AA.log').writeAsStringSync(
      '2026-10-08 10:00:00.000+00:00 D g1 app     a\n'
      '2026-10-08 10:30:00.000+00:00 D g1 app     b\n',
    );
    final summary = (await store.summary('AA'))!;
    expect(summary.bytes, greaterThan(0));
    expect(summary.first, DateTime.parse('2026-10-08 10:00:00.000+00:00'));
    expect(summary.last, DateTime.parse('2026-10-08 10:30:00.000+00:00'));
    expect(await store.summary('ZZ'), isNull);
    store.dispose();
  });

  test('updateBikes starts, resumes and stops the log by preference', () {
    SavedBike bike({required bool enabled}) => SavedBike(
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
    final store = build()
      ..updateBikes([bike(enabled: false)])
      ..flush();
    expect(directory.listSync(), isEmpty);

    store
      ..updateBikes([bike(enabled: true)])
      ..updateBikes([bike(enabled: true)])
      ..updateBikes([bike(enabled: false)])
      ..flush();
    final lines = File('${directory.path}/AA_BB.log').readAsLinesSync();
    expect(lines, hasLength(3));
    expect(lines[0], endsWith('log started'));
    expect(lines[1], contains('snapshot protocol=v1 region=ch'));
    expect(lines[2], endsWith('log stopped'));
    store.dispose();
  });

  test('export writes header, bike snapshot and merged lines', () async {
    final store = build();
    File('${directory.path}/AA_BB.log')
        .writeAsStringSync('2026-10-08 10:00:03.000+00:00 D g1  app     c\n');
    File('${directory.path}/AA_BB.native.log')
        .writeAsStringSync('2026-10-08 10:00:02.000+00:00 N --  native  b\n');
    final saved = SavedBike(
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
    );

    final file = await store.exportFor(
      saved,
      header: 'HEADER',
      liveState: 'LIVE',
    );

    final lines = file.readAsLinesSync();
    expect(lines.first, 'HEADER');
    expect(lines, contains('LIVE'));
    expect(lines.indexOf('---'), greaterThan(0));
    expect(
      lines.sublist(lines.indexOf('---') + 1).map((l) => l[l.length - 1]),
      ['b', 'c'],
    );
    store.clear('aa:bb');
    expect(file.existsSync(), isFalse);
    store.dispose();
  });

  test('in the background a line reaches the file at once', () {
    final store = build()
      ..setEnabled('AA', enabled: true)
      ..flush()
      ..inBackground = true;
    store.forBike('AA').log('hold', 'service started');

    expect(
      File('${directory.path}/AA.log').readAsStringSync(),
      contains('service started'),
    );
    store.dispose();
  });

  test('an uncaught error flushes the buffer', () {
    final store = build()..setEnabled('AA', enabled: true);
    store.forBike('AA').log('link', 'before the error');
    final flutterHandler = FlutterError.onError;
    final platformHandler = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = flutterHandler;
      PlatformDispatcher.instance.onError = platformHandler;
    });
    FlutterError.onError = (_) {};
    PlatformDispatcher.instance.onError = (_, _) => true;
    installDebugLogErrorFlush(() => store);

    final file = File('${directory.path}/AA.log');
    PlatformDispatcher.instance.onError!(StateError('x'), StackTrace.empty);

    final text = file.readAsStringSync();
    expect(text, contains('before the error'));
    expect(text, contains('uncaught error: StateError: Bad state: x'));
    expect(text.contains('#0'), isFalse);
    store.dispose();
  });

  test('a message with line breaks stays one line', () {
    final line = formatDebugLogLine(
      time: DateTime.utc(2026),
      source: 'D',
      area: 'link',
      message: 'a\nb\r\nc',
    );
    expect(line, endsWith('a | b | c'));
    expect(line.contains('\n'), isFalse);
  });

  test('a forgotten bike loses its files and its enabled flag', () {
    final store = build()..setEnabled('AA', enabled: true);
    store.forBike('AA').log('app', 'x');
    store.flush();
    File('${directory.path}/AA.native.log').writeAsStringSync('n\n');

    store.forget('AA');
    store.forBike('AA').log('app', 'after');
    store.flush();

    expect(directory.listSync(), isEmpty);
    store.dispose();
  });

  test('a bike that leaves the list is no longer enabled', () {
    SavedBike bike(String id) => SavedBike(
      bike: Bike(
        deviceId: id,
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
      debugLogEnabled: true,
    );
    final store = build()..updateBikes([bike('aa')]);
    expect(store.isEnabled('aa'), isTrue);

    store.updateBikes([]);

    expect(store.isEnabled('aa'), isFalse);
    store.dispose();
  });

  test('rotation counts bytes, not characters', () {
    final store = build(maxBytes: 200)..setEnabled('AA', enabled: true);
    final log = store.forBike('AA');
    for (var i = 0; i < 4; i++) {
      log.log('app', 'äöü' * 10);
      store.flush();
    }
    expect(File('${directory.path}/AA.1.log').existsSync(), isTrue);
    store.dispose();
  });

  test('one proxy follows the preference while a session lives', () {
    final store = build();
    final proxy = store.forBike('AA')..log('app', 'dropped, log off');
    store.setEnabled('AA', enabled: true);
    proxy.log('app', 'recorded');
    store.setEnabled('AA', enabled: false);
    proxy.log('app', 'dropped again');
    store.flush();

    final text = File('${directory.path}/AA.log').readAsStringSync();
    expect(text, contains('recorded'));
    expect(text, isNot(contains('dropped')));
    store.dispose();
  });

  test('a write publishes the device id as a change', () async {
    final store = build()..setEnabled('aa:bb', enabled: true);
    final changes = <String>[];
    final sub = store.changes.listen(changes.add);
    store.forBike('aa:bb').log('app', 'x');
    store.flush();
    await Future<void>.delayed(Duration.zero);

    expect(changes, contains('AA_BB'));
    await sub.cancel();
    store.dispose();
  });
}

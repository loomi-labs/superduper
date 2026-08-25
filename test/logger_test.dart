import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:superduper/utils/logger.dart';

/// Matches any ANSI escape sequence (colors must never reach the log file).
final _ansi = RegExp(r'\x1B\[');

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('superduper_log_test');
  });

  tearDown(() async {
    // Always release the sink before the directory disappears.
    await log.detachFileSink();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  File latestFile() => File('${tempDir.path}/${SDLogger.logFileName}');

  test('attached file sink writes debug lines with tag prefix and no colors',
      () async {
    await log.attachFileSink(directory: tempDir.path);
    expect(log.fileLoggingEnabled, isTrue);

    log.d(SDLogger.bike, 'debug ride line');
    log.i(SDLogger.bluetooth, 'info ride line');
    await log.flushFileSink();

    final contents = latestFile().readAsStringSync();
    expect(contents, contains('[Bike] debug ride line'),
        reason: 'debug level must reach the file');
    expect(contents, contains('[Bluetooth] info ride line'));
    expect(contents, contains('[D]'), reason: 'level label expected');
    expect(_ansi.hasMatch(contents), isFalse,
        reason: 'file output must be plain text, no ANSI escapes');
    // Timestamp on every emitted line.
    final debugLine = contents
        .split('\n')
        .firstWhere((l) => l.contains('debug ride line'));
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}').hasMatch(debugLine),
        isTrue,
        reason: 'each line starts with a clock timestamp, got: $debugLine');
  });

  test('file sink filter keeps logging in release builds', () {
    // DevelopmentFilter (the package default) evaluates its check inside an
    // assert and therefore drops every line in a release build.
    expect(SDLogger.createFileFilter(), isA<ProductionFilter>(),
        reason: 'file sink must record debug level in release builds too');
  });

  test('console-only mode never touches the filesystem', () async {
    expect(log.fileLoggingEnabled, isFalse);
    log.d(SDLogger.bike, 'console only');
    log.e(SDLogger.bike, 'console only error', Exception('nope'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(tempDir.listSync(), isEmpty,
        reason: 'unattached logger must not write files');
  });

  test('rotation config caps file size and number of rotated files', () async {
    // Pins the total log budget (~32 MB) so it cannot balloon accidentally;
    // sized to hold several rides at BLE-debug verbosity.
    expect(SDLogger.maxFileSizeKB, lessThanOrEqualTo(2048));
    expect(SDLogger.maxRotatedFilesCount, lessThanOrEqualTo(15));

    // Pre-seed an oversized current log plus more rotated files than allowed.
    tempDir.createSync(recursive: true);
    latestFile()
        .writeAsStringSync('x' * ((SDLogger.maxFileSizeKB * 1024) + 2048));
    for (var i = 0; i < SDLogger.maxRotatedFilesCount + 2; i++) {
      File('${tempDir.path}/old-$i.log').writeAsStringSync('old $i');
    }

    await log.attachFileSink(directory: tempDir.path);
    log.d(SDLogger.bike, 'after rotation');
    await log.flushFileSink();

    final rotated = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path != latestFile().path)
        .toList();
    expect(rotated.length, lessThanOrEqualTo(SDLogger.maxRotatedFilesCount),
        reason: 'rotated files must be pruned to the configured cap');
    expect(latestFile().readAsStringSync(), contains('after rotation'));
    expect(latestFile().lengthSync(), lessThan(SDLogger.maxFileSizeKB * 1024),
        reason: 'oversized log must have been rotated away');
  });

  test('logFiles lists nothing until a sink is attached', () async {
    expect(log.logFiles(), isEmpty);
    await log.attachFileSink(directory: tempDir.path);
    log.i(SDLogger.general, 'hello');
    await log.flushFileSink();
    expect(log.logFiles().map((f) => f.path),
        contains(latestFile().path));
  });
}

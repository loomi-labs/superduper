import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:path_provider/path_provider.dart';
import 'package:superduper/src/domain/bike.dart';

/// A sink for debug log lines. The log of a bike is off by default.
abstract interface class DebugLog {
  void log(String area, String message, {int? generation});
}

/// The log of one device. App-wide parts take it as a factory.
typedef DebugLogFor = DebugLog Function(String deviceId);

DebugLog noDebugLogFor(String deviceId) => const NoopDebugLog();

final class NoopDebugLog implements DebugLog {
  const new();

  @override
  void log(String area, String message, {int? generation}) {}
}

/// The file stem of a device: upper case, other characters become `_`.
/// The Kotlin code uses the same rule.
String debugLogFileId(String deviceId) {
  return deviceId.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '_');
}

String _two(int value) => value.toString().padLeft(2, '0');

String formatDebugLogTime(DateTime time) {
  final offset = time.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  final zone = '$sign${_two(minutes ~/ 60)}:${_two(minutes % 60)}';
  return '${time.year.toString().padLeft(4, '0')}-${_two(time.month)}-'
      '${_two(time.day)} ${_two(time.hour)}:${_two(time.minute)}:'
      '${_two(time.second)}.${time.millisecond.toString().padLeft(3, '0')}'
      '$zone';
}

final _lineBreak = RegExp(r'\r\n|\r|\n');

String formatDebugLogLine({
  required DateTime time,
  required String source,
  required String area,
  required String message,
  int? generation,
}) {
  final generationText = generation == null ? '--' : 'g$generation';
  // One event is one line.
  final oneLine = message.replaceAll(_lineBreak, ' | ');
  return '${formatDebugLogTime(time)} $source ${generationText.padRight(3)} '
      '${area.padRight(7)} $oneLine';
}

final class DebugLogSummary {
  const new({required this.bytes, this.first, this.last});

  final int bytes;
  final DateTime? first;
  final DateTime? last;
}

const _logSuffixes = ['.1.log', '.log', '.native.1.log', '.native.log'];
const _mergeOrder = ['.1.log', '.log', '.native.log', '.native.1.log'];
final _timestampPattern = RegExp(
  r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d',
);

DateTime? _parseLineTime(String line) {
  final match = _timestampPattern.matchAsPrefix(line);
  return match == null ? null : DateTime.tryParse(match.group(0)!);
}

final class _BikeLogFile {
  new({
    required this.directory,
    required this.id,
    required this.maxBytes,
    required this.flushInterval,
    required this.immediate,
    required this.onWrite,
  });

  final void Function(String id) onWrite;

  static const _maxBufferedLines = 50;

  /// True while the app is in the background: no buffer.
  final bool Function() immediate;
  var _directoryReady = false;

  final Directory directory;
  final String id;
  final int maxBytes;
  final Duration flushInterval;
  final _buffer = <String>[];
  Timer? _timer;

  File get _file => File('${directory.path}/$id.log');
  File get _rotated => File('${directory.path}/$id.1.log');

  void append(String line) {
    _buffer.add(line);
    if (_buffer.length >= _maxBufferedLines || immediate()) {
      flush();
      return;
    }
    _timer ??= Timer(flushInterval, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isEmpty) {
      return;
    }
    final text = '${_buffer.join('\n')}\n';
    _buffer.clear();
    try {
      if (!_directoryReady) {
        directory.createSync(recursive: true);
        _directoryReady = true;
      }
      final file = _file;
      final bytes = utf8.encode(text).length;
      if (file.existsSync() && file.lengthSync() + bytes > maxBytes) {
        file.renameSync(_rotated.path);
      }
      file.writeAsStringSync(text, mode: FileMode.append);
      onWrite(id);
    } on FileSystemException {
      // A log failure must never break the app.
      _directoryReady = false;
    }
  }

  void dispose() {
    flush();
  }
}

/// Owns the debug log files of all bikes. One store exists for each app.
final class DebugLogStore {
  new({
    this._directory,
    this.maxBytes = 2 * 1024 * 1024,
    this.flushInterval = const Duration(seconds: 2),
    DateTime Function()? now,
    this._resolveDirectory,
  }) : _now = now ?? DateTime.now;

  /// A store for the app: the directory is `<documents>/debug_logs`, and
  /// [initialize] resolves it.
  factory app() {
    return DebugLogStore(
      resolveDirectory: () async {
        final documents = await getApplicationDocumentsDirectory();
        return Directory('${documents.path}/debug_logs');
      },
    );
  }

  Directory? _directory;
  final Future<Directory> Function()? _resolveDirectory;
  final int maxBytes;
  final Duration flushInterval;
  final DateTime Function() _now;
  final _enabled = <String>{};
  Directory? get directory => _directory;

  /// Resolves the directory. Lines before this call are dropped.
  Future<void> initialize() async {
    final resolve = _resolveDirectory;
    if (_directory == null && resolve != null) {
      _directory = await resolve();
    }
  }

  final _files = <String, _BikeLogFile>{};
  final _seen = <String>{};

  var _inBackground = false;
  final _changes = StreamController<String>.broadcast(sync: true);

  /// The file id of a bike, after a write of its Dart log.
  Stream<String> get changes => _changes.stream;

  /// Records an uncaught error in the log of each enabled bike.
  void recordUncaughtError(Object error) {
    var text = error.toString();
    if (text.length > 300) {
      text = '${text.substring(0, 300)}…';
    }
    for (final id in _enabled.toList()) {
      _write(id, 'app', 'uncaught error: ${error.runtimeType}: $text');
    }
  }

  /// While the app is in the background, lines go to the file at once: the
  /// process can end at any time.
  // ignore: avoid_setters_without_getters
  set inBackground(bool value) {
    _inBackground = value;
    if (value) {
      flush();
    }
  }

  /// A proxy that checks the enabled flag at each call.
  DebugLog forBike(String deviceId) => _BikeDebugLog(this, deviceId);

  bool isEnabled(String deviceId) =>
      _enabled.contains(debugLogFileId(deviceId));

  /// Applies the preference of every bike. A bike that is new to the store and
  /// already enabled gets a "resumed" line. A bike that turns on gets
  /// "started" and the snapshot.
  void updateBikes(List<SavedBike> bikes) {
    final present = {for (final b in bikes) debugLogFileId(b.bike.deviceId)};
    for (final id in _enabled.toList()) {
      if (!present.contains(id)) {
        // A forgotten bike: its log is off.
        _enabled.remove(id);
        _files.remove(id)?.dispose();
      }
    }
    _seen.removeWhere((id) => !present.contains(id));
    for (final bike in bikes) {
      final id = debugLogFileId(bike.bike.deviceId);
      final first = _seen.add(id);
      final was = _enabled.contains(id);
      if (bike.debugLogEnabled == was && !(first && bike.debugLogEnabled)) {
        continue;
      }
      setEnabled(
        bike.bike.deviceId,
        enabled: bike.debugLogEnabled,
        snapshot: bike,
        resumed: first,
      );
    }
  }

  void setEnabled(
    String deviceId, {
    required bool enabled,
    SavedBike? snapshot,
    bool resumed = false,
  }) {
    final id = debugLogFileId(deviceId);
    final was = _enabled.contains(id);
    if (enabled) {
      _enabled.add(id);
      if (!was || resumed) {
        _write(id, 'app', resumed ? 'log resumed' : 'log started');
        if (snapshot != null) {
          _write(id, 'app', describeBike(snapshot));
        }
      }
    } else if (was) {
      _write(id, 'app', 'log stopped');
      _enabled.remove(id);
      _files[id]?.flush();
    }
  }

  static String describeBike(SavedBike bike) {
    final modes = bike.customModes
        .map(
          (m) =>
              '${m.name}(limit=${m.limitKmh}'
              '${m.throttle ? ',throttle' : ''})',
        )
        .join(';');
    return 'snapshot protocol=${bike.bike.protocol.name} '
        'region=${bike.bike.region?.name} customModes=[$modes] '
        'setOnConnect=${bike.setOnConnect} '
        'streetLegal=${bike.streetLegalOnQuickRestart} '
        'stockMode=${bike.streetLegalStockMode} '
        'background=${bike.backgroundPreference.requested}';
  }

  void _write(String id, String area, String message, {int? generation}) {
    final line = formatDebugLogLine(
      time: _now(),
      source: 'D',
      area: area,
      message: message,
      generation: generation,
    );
    final directory = _directory;
    if (directory == null) {
      return;
    }
    (_files[id] ??= _BikeLogFile(
      directory: directory,
      id: id,
      maxBytes: maxBytes,
      flushInterval: flushInterval,
      immediate: () => _inBackground,
      onWrite: _changes.add,
    )).append(line);
  }

  void flush() {
    for (final file in _files.values) {
      file.flush();
    }
  }

  void dispose() {
    for (final file in _files.values) {
      file.dispose();
    }
    _files.clear();
    unawaited(_changes.close());
  }

  /// The lines of the four files of a device, sorted by time (stable).
  List<String> mergedLines(String deviceId) {
    flush();
    final directory = _directory;
    if (directory == null) {
      return const [];
    }
    final id = debugLogFileId(deviceId);
    final entries = <({DateTime time, int order, String line})>[];
    var order = 0;
    DateTime? previous;
    // The native file is read before its rotated file: a rotation during the
    // read does not hide lines. The sort by time fixes the order.
    for (final suffix in _mergeOrder) {
      final file = File('${directory.path}/$id$suffix');
      if (!file.existsSync()) {
        continue;
      }
      previous = null;
      for (final line in file.readAsLinesSync()) {
        if (line.isEmpty) {
          continue;
        }
        final time = _parseLineTime(line) ?? previous;
        previous = time;
        entries.add((
          time: time ?? DateTime.fromMillisecondsSinceEpoch(0),
          order: order++,
          line: line,
        ));
      }
    }
    entries.sort((a, b) {
      final byTime = a.time.compareTo(b.time);
      return byTime != 0 ? byTime : a.order.compareTo(b.order);
    });
    return [for (final entry in entries) entry.line];
  }

  /// Size and time span of the files of a device. Null when none exist. It
  /// reads only the first and the last 4 KB of each file.
  Future<DebugLogSummary?> summary(String deviceId) async {
    flush();
    final directory = _directory;
    if (directory == null) {
      return null;
    }
    final id = debugLogFileId(deviceId);
    var bytes = 0;
    var any = false;
    DateTime? first;
    DateTime? last;
    for (final suffix in _logSuffixes) {
      final file = File('${directory.path}/$id$suffix');
      try {
        if (!file.existsSync()) {
          continue;
        }
        final length = file.lengthSync();
        any = true;
        bytes += length;
        final head = _edgeTime(file, length, fromEnd: false);
        final tail = _edgeTime(file, length, fromEnd: true);
        if (head != null && (first == null || head.isBefore(first))) {
          first = head;
        }
        if (tail != null && (last == null || tail.isAfter(last))) {
          last = tail;
        }
      } on FileSystemException {
        // A file that a rotation or a clear removed is not part of the size.
      }
    }
    return any ? DebugLogSummary(bytes: bytes, first: first, last: last) : null;
  }

  static const _edgeBytes = 4096;

  /// The time of the first or the last line with a time stamp.
  static DateTime? _edgeTime(File file, int length, {required bool fromEnd}) {
    final handle = file.openSync();
    try {
      final count = length < _edgeBytes ? length : _edgeBytes;
      handle.setPositionSync(fromEnd ? length - count : 0);
      final text = utf8.decode(handle.readSync(count), allowMalformed: true);
      final lines = text.split('\n');
      for (final line in fromEnd ? lines.reversed : lines) {
        if (_parseLineTime(line) case final time?) {
          return time;
        }
      }
      return null;
    } finally {
      handle.closeSync();
    }
  }

  /// Writes the merged log with a header to a file and returns it.
  Future<File> exportFor(
    SavedBike bike, {
    required String header,
    String? liveState,
  }) async {
    final directory = _directory;
    if (directory == null) {
      throw StateError('The debug log directory is not available.');
    }
    final id = debugLogFileId(bike.bike.deviceId);
    final lines = mergedLines(bike.bike.deviceId);
    final out = File('${directory.path}/export/$id.txt');
    await out.parent.create(recursive: true);
    final buffer = StringBuffer()
      ..writeln(header)
      ..writeln(describeBike(bike));
    if (liveState != null) {
      buffer.writeln(liveState);
    }
    buffer
      ..writeln('---')
      ..writeAll(lines, '\n')
      ..writeln();
    await out.writeAsString(buffer.toString());
    return out;
  }

  /// A forgotten bike: its log is off and its files are deleted.
  void forget(String deviceId) {
    _enabled.remove(debugLogFileId(deviceId));
    _seen.remove(debugLogFileId(deviceId));
    clear(deviceId);
  }

  void clear(String deviceId) {
    final directory = _directory;
    if (directory == null) {
      return;
    }
    final id = debugLogFileId(deviceId);
    _files.remove(id)?._buffer.clear();
    for (final suffix in _logSuffixes) {
      final file = File('${directory.path}/$id$suffix');
      if (file.existsSync()) {
        file.deleteSync();
      }
    }
    _changes.add(id);
    final export = File('${directory.path}/export/$id.txt');
    if (export.existsSync()) {
      export.deleteSync();
    }
  }
}

final class _BikeDebugLog implements DebugLog {
  new(this._store, String deviceId) : _id = debugLogFileId(deviceId);

  final DebugLogStore _store;
  final String _id;

  @override
  void log(String area, String message, {int? generation}) {
    final id = _id;
    if (!_store._enabled.contains(id)) {
      return;
    }
    _store._write(id, area, message, generation: generation);
  }
}

/// Flushes the store when the app reports an uncaught error. The process can
/// end after it. Call it once. [store] gives the store that is current.
void installDebugLogErrorFlush(DebugLogStore? Function() store) {
  final previousFlutter = FlutterError.onError;
  FlutterError.onError = (details) {
    store()
      ?..recordUncaughtError(details.exception)
      ..flush();
    if (previousFlutter != null) {
      previousFlutter(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  final previousPlatform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    store()
      ?..recordUncaughtError(error)
      ..flush();
    return previousPlatform?.call(error, stack) ?? false;
  };
}

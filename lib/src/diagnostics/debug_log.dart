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

/// A file of the debug log of one bike. `rotation` is 0 for the current file.
/// A higher rotation is a newer file.
typedef DebugLogFile = ({File file, bool native, int rotation});

const Duration debugLogMaxAge = Duration(days: 30);
const int debugLogMaxBytesPerBike = 300 * 1024 * 1024;

/// All files of a bike: `<id>.log`, `<id>.<k>.log`, `<id>.native.log` and
/// `<id>.native.<k>.log`. The Dart files come first, oldest first.
List<DebugLogFile> debugLogFilesOf(Directory directory, String id) {
  if (!directory.existsSync()) {
    return const [];
  }
  final pattern = RegExp(
    '^${RegExp.escape(id)}(\\.native)?(?:\\.(\\d+))?\\.log\$',
  );
  final files = <DebugLogFile>[];
  try {
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final match = pattern.firstMatch(entity.uri.pathSegments.last);
      if (match == null) {
        continue;
      }
      files.add((
        file: entity,
        native: match.group(1) != null,
        rotation: int.tryParse(match.group(2) ?? '') ?? 0,
      ));
    }
  } on FileSystemException {
    return const [];
  }
  // Rotated files by number, then the current file; Dart before native.
  int order(DebugLogFile f) => f.rotation == 0 ? 1 << 30 : f.rotation;
  files.sort((a, b) {
    if (a.native != b.native) {
      return a.native ? 1 : -1;
    }
    return order(a).compareTo(order(b));
  });
  return files;
}

/// The number for the next rotated file of one kind: highest number plus 1.
int nextDebugLogRotation(
  Directory directory,
  String id, {
  required bool native,
}) {
  var highest = 0;
  for (final f in debugLogFilesOf(directory, id)) {
    if (f.native == native && f.rotation > highest) {
      highest = f.rotation;
    }
  }
  return highest + 1;
}

/// Deletes the rotated files that are older than [maxAge]. Then, while the
/// files of the bike are above [maxBytes], it deletes the rotated file with
/// the oldest modification time. A current file stays. A failed delete is
/// ignored.
void pruneDebugLogFiles(
  Directory directory,
  String id, {
  required DateTime now,
  Duration maxAge = debugLogMaxAge,
  int maxBytes = debugLogMaxBytesPerBike,
}) {
  try {
    final sizes = <String, int>{};
    final modified = <String, DateTime>{};
    final rotated = <DebugLogFile>[];
    var total = 0;
    for (final f in debugLogFilesOf(directory, id)) {
      final stat = f.file.statSync();
      sizes[f.file.path] = stat.size;
      modified[f.file.path] = stat.modified;
      total += stat.size;
      if (f.rotation > 0) {
        rotated.add(f);
      }
    }
    void remove(DebugLogFile f) {
      try {
        f.file.deleteSync();
        total -= sizes[f.file.path]!;
        rotated.remove(f);
      } on FileSystemException {
        // The log must never break the app.
      }
    }

    for (final f in rotated.toList()) {
      if (now.difference(modified[f.file.path]!) > maxAge) {
        remove(f);
      }
    }
    rotated.sort(
      (a, b) => modified[a.file.path]!.compareTo(modified[b.file.path]!),
    );
    for (final f in rotated.toList()) {
      if (total <= maxBytes) {
        break;
      }
      remove(f);
    }
  } on FileSystemException {
    // The log must never break the app.
  }
}

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
    required this.onRotate,
  });

  final void Function(String id) onWrite;

  /// Called after a rotation, to prune the files of the bike.
  final void Function(String id) onRotate;

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
      var rotated = false;
      if (file.existsSync() && file.lengthSync() + bytes > maxBytes) {
        final next = nextDebugLogRotation(directory, id, native: false);
        file.renameSync('${directory.path}/$id.$next.log');
        rotated = true;
      }
      file.writeAsStringSync(text, mode: FileMode.append);
      if (rotated) {
        onRotate(id);
      }
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
    _pruneAll();
  }

  /// Prunes the files of each bike that has files in the folder.
  void _pruneAll() {
    final directory = _directory;
    if (directory == null || !directory.existsSync()) {
      return;
    }
    final ids = <String>{};
    final stem = RegExp(r'^([A-Z0-9_]+?)(?:\.native)?(?:\.\d+)?\.log$');
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        if (entity is File) {
          final match = stem.firstMatch(entity.uri.pathSegments.last);
          if (match != null) {
            ids.add(match.group(1)!);
          }
        }
      }
    } on FileSystemException {
      return;
    }
    for (final id in ids) {
      pruneDebugLogFiles(directory, id, now: _now());
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
      onRotate: (id) => pruneDebugLogFiles(directory, id, now: _now()),
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

  /// The lines of all files of a device, sorted by time (stable). It reads
  /// each file line by line and holds one line of each file in memory.
  Stream<String> mergedLines(String deviceId) async* {
    flush();
    final directory = _directory;
    if (directory == null) {
      return;
    }
    // Oldest first: each file holds its lines in time order, so a merge of the
    // file streams gives the order. On a tie, the earlier file wins.
    final files = debugLogFilesOf(directory, debugLogFileId(deviceId));
    final readers = <_LineReader>[];
    try {
      for (final f in files) {
        final reader = _LineReader(f.file);
        if (await reader.advance()) {
          readers.add(reader);
        }
      }
      while (readers.isNotEmpty) {
        var best = readers.first;
        for (final reader in readers.skip(1)) {
          if (reader.time.isBefore(best.time)) {
            best = reader;
          }
        }
        yield best.line;
        if (!await best.advance()) {
          readers.remove(best);
        }
      }
    } finally {
      for (final reader in readers) {
        await reader.close();
      }
    }
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
    for (final entry in debugLogFilesOf(directory, id)) {
      final file = entry.file;
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
    final out = File('${directory.path}/export/$id.txt');
    await out.parent.create(recursive: true);
    final sink = out.openWrite()
      ..writeln(header)
      ..writeln(describeBike(bike));
    if (liveState != null) {
      sink.writeln(liveState);
    }
    sink.writeln('---');
    try {
      await sink.addStream(
        mergedLines(bike.bike.deviceId)
            .map((line) => '$line\n')
            .transform(utf8.encoder),
      );
    } finally {
      await sink.close();
    }
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
    for (final entry in debugLogFilesOf(directory, id)) {
      try {
        entry.file.deleteSync();
      } on FileSystemException {
        // A file that is gone already is not an error.
      }
    }
    _changes.add(id);
    final export = File('${directory.path}/export/$id.txt');
    if (export.existsSync()) {
      export.deleteSync();
    }
  }
}

/// Reads a log file line by line. [time] is the time of the current [line]; a
/// line without a time stamp takes the time of the line before it.
final class _LineReader {
  new(File file)
    : _iterator = StreamIterator(
        file
            .openRead()
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter()),
      );

  final StreamIterator<String> _iterator;
  String line = '';
  DateTime time = DateTime.fromMillisecondsSinceEpoch(0);

  Future<bool> advance() async {
    try {
      while (await _iterator.moveNext()) {
        final next = _iterator.current;
        if (next.isEmpty) {
          continue;
        }
        time = _parseLineTime(next) ?? time;
        line = next;
        return true;
      }
    } on FileSystemException {
      // A file that a clear removed ends here.
    }
    return false;
  }

  Future<void> close() async {
    try {
      await _iterator.cancel();
    } on Object {
      // The log must never break the app.
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

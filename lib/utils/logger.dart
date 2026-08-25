import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

/// Plain-text printer for the log file: no ANSI colors, no boxing, one
/// timestamped line per event plus optional error/stacktrace continuation
/// lines.
///
/// Example: `2026-08-07T21:04:11.412 [D] [Bike] state: ...`
class FileLogPrinter extends LogPrinter {
  static const Map<Level, String> _labels = {
    Level.trace: '[T]',
    Level.debug: '[D]',
    Level.info: '[I]',
    Level.warning: '[W]',
    Level.error: '[E]',
    Level.fatal: '[F]',
  };

  @override
  List<String> log(LogEvent event) {
    final label = _labels[event.level] ?? '[?]';
    final time = event.time.toIso8601String();
    final lines = <String>['$time $label ${event.message}'];
    if (event.error != null) {
      lines.add('  ERROR: ${event.error}');
    }
    final stack = event.stackTrace;
    if (stack != null) {
      lines.add(stack.toString().trimRight());
    }
    return lines;
  }
}

/// A professional logging service that provides consistent, formatted logs
/// with different log levels and categories.
///
/// Two sinks are fanned out from every log call:
/// * the console, with `PrettyPrinter` and the historic level policy (debug in
///   debug builds, info+ in release),
/// * an optional rotating log file that always records debug level, including
///   in release builds, so a real test ride leaves a BLE evidence trail.
///
/// The file sink is off until [attachFileSink] is called (from `main()`),
/// because the documents directory is only available asynchronously.
class SDLogger {
  static final SDLogger _instance = SDLogger._internal();
  factory SDLogger() => _instance;

  late Logger _logger;

  /// Console logger is always present; the file logger is attached later.
  Logger? _fileLogger;
  String? _logDirectory;

  // Tag constants to categorize logs
  static const String bluetooth = 'Bluetooth';
  static const String bike = 'Bike';
  static const String ui = 'UI';
  static const String db = 'Database';
  static const String general = 'App';

  /// Sub-directory of the app documents directory holding the log files.
  static const String logDirectoryName = 'logs';

  /// Name of the log file currently being written.
  static const String logFileName = 'superduper.log';

  /// Rotate to a new file once the current one passes this size.
  static const int maxFileSizeKB = 2048;

  /// How many rotated files to keep besides the current one.
  /// Together with [maxFileSizeKB] this caps the logs at ~32 MB — at BLE-debug
  /// verbosity (roughly 0.5-2 KB/s while connected) that holds several full
  /// rides before the oldest file is pruned.
  static const int maxRotatedFilesCount = 15;

  SDLogger._internal() {
    // Initialize with appropriate settings
    _logger = Logger(
      printer: PrettyPrinter(
          methodCount: 0, // Number of method calls to display
          errorMethodCount:
              5, // Number of method calls if stacktrace is provided
          lineLength: 120, // Width of the output
          colors:
              !Platform.isIOS, // Colors are handled poorly in iOS debug console
          printEmojis: false, // Print emojis
          dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
          noBoxingByDefault: true),
      level: kDebugMode
          ? Level.debug
          : Level.info, // Only show info+ logs in production
    );
  }

  /// Whether log lines are currently being written to a file.
  bool get fileLoggingEnabled => _fileLogger != null;

  /// Directory holding the log files, or null while file logging is off.
  String? get logDirectory => _logDirectory;

  /// Start writing all log lines (debug level included, in release too) to a
  /// rotating file in [directory], defaulting to `<app documents>/logs`.
  ///
  /// Never throws: if the documents directory is unavailable (e.g. tests
  /// without the path_provider plugin) file logging simply stays off.
  Future<void> attachFileSink({String? directory}) async {
    try {
      await detachFileSink();
      final dir = directory ??
          '${(await getApplicationDocumentsDirectory()).path}'
              '/$logDirectoryName';
      _fileLogger = _createFileLogger(dir);
      _logDirectory = dir;
      await _fileLogger!.init;
      i(general, 'File logging enabled: $dir/$logFileName');
    } catch (e, s) {
      _fileLogger = null;
      _logDirectory = null;
      // Console only: a missing log file must never break the app.
      _logger.w('[$general] Could not enable file logging: $e\n$s');
    }
  }

  /// Filter of the file sink. Must stay a [ProductionFilter]: the default
  /// [DevelopmentFilter] hides its check behind an `assert`, so it would drop
  /// every line in release builds — recording a release ride is the whole
  /// point of the log file.
  @visibleForTesting
  static LogFilter createFileFilter() => ProductionFilter();

  Logger _createFileLogger(String directory) {
    return Logger(
      filter: createFileFilter(),
      level: Level.debug,
      printer: FileLogPrinter(),
      output: AdvancedFileOutput(
        // With maxFileSizeKB > 0 the path is a directory and the current file
        // is `latestFileName`; older ones get a timestamped name.
        path: directory,
        latestFileName: logFileName,
        maxFileSizeKB: maxFileSizeKB,
        maxRotatedFilesCount: maxRotatedFilesCount,
      ),
    );
  }

  /// Flush buffered lines to disk so the files on disk are complete, e.g.
  /// before sharing them. Keeps file logging enabled (lines logged while the
  /// file is being reopened go to the console only).
  Future<void> flushFileSink() async {
    final directory = _logDirectory;
    if (_fileLogger == null || directory == null) return;
    await _closeFileLogger();
    try {
      // Appends to the same file, so rotation state is preserved.
      _fileLogger = _createFileLogger(directory);
      await _fileLogger!.init;
    } catch (e) {
      _fileLogger = null;
      _logDirectory = null;
      _logger.w('[$general] Could not reopen log file: $e');
    }
  }

  /// Stop file logging and release the file handle, flushing what is buffered.
  Future<void> detachFileSink() async {
    _logDirectory = null;
    await _closeFileLogger();
  }

  Future<void> _closeFileLogger() async {
    final fileLogger = _fileLogger;
    // Detach first: logging through a closed Logger throws.
    _fileLogger = null;
    if (fileLogger == null) return;
    try {
      await fileLogger.close();
    } catch (e) {
      _logger.w('[$general] Could not close log file: $e');
    }
  }

  /// Existing log files (current + rotated), newest first. Empty when file
  /// logging is off or nothing has been written yet.
  List<File> logFiles() {
    final directory = _logDirectory;
    if (directory == null) return [];
    final dir = Directory(directory);
    if (!dir.existsSync()) return [];
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  /// Debug level log - console in debug builds only, always in the log file
  void d(String tag, String message) {
    _logger.d('[$tag] $message');
    _fileLogger?.d('[$tag] $message');
  }

  /// Info level log - shown in both debug and production
  void i(String tag, String message) {
    _logger.i('[$tag] $message');
    _fileLogger?.i('[$tag] $message');
  }

  /// Warning level log - shown in both debug and production
  void w(String tag, String message) {
    _logger.w('[$tag] $message');
    _fileLogger?.w('[$tag] $message');
  }

  /// Error level log with optional error object and stack trace
  void e(String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.e('[$tag] $message', error: error, stackTrace: stackTrace);
    _fileLogger?.e('[$tag] $message', error: error, stackTrace: stackTrace);
  }

  /// WTF (What a Terrible Failure) level log - for catastrophic failures
  void wtf(String tag, String message,
      [dynamic error, StackTrace? stackTrace]) {
    _logger.f('[$tag] $message', error: error, stackTrace: stackTrace);
    _fileLogger?.f('[$tag] $message', error: error, stackTrace: stackTrace);
  }
}

/// Global logger instance for easy access
final log = SDLogger();

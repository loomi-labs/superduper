import 'package:superduper/src/diagnostics/debug_log.dart';

final class RecordingDebugLog implements DebugLog {
  final entries = <({String area, String message, int? generation})>[];

  @override
  void log(String area, String message, {int? generation}) {
    entries.add((area: area, message: message, generation: generation));
  }

  /// The messages of one area.
  List<String> messages(String area) => [
    for (final entry in entries)
      if (entry.area == area) entry.message,
  ];

  bool has(String area, Pattern pattern) =>
      messages(area).any((m) => m.contains(pattern));
}

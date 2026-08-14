import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:superduper/models.dart';
import 'package:superduper/utils/logger.dart';

part 'db.freezed.dart';
part 'db.g.dart';

@freezed
abstract class SettingsModel with _$SettingsModel {
  const factory SettingsModel({String? currentBike}) = _SettingsModel;

  factory SettingsModel.fromJson(Map<String, dynamic> json) =>
      _$SettingsModelFromJson(json);
}

Future<String> get _localPath async {
  final directory = await getApplicationDocumentsDirectory();
  return directory.path;
}

Future<File> get _settingsFile async {
  final path = await _localPath;
  return File('$path/settings.json');
}

Future<File> get _bikesFile async {
  final path = await _localPath;
  return File('$path/bikes.json');
}

/// Replaces [file]'s contents without ever leaving a half-written file behind:
/// a sibling temp file is filled and flushed first, then renamed over the
/// target — atomic, because both live on the same filesystem.
///
/// Writing in place is not safe here. A process kill mid-write leaves truncated
/// JSON, [_readBikes]'s outer catch maps that to no bikes at all, and the next
/// save persists that empty list over every bike the rider had.
Future<void> _writeAtomically(File file, String contents) async {
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(file.path);
}

/// Tails of the per-file write queues. The saves are fire-and-forget, so two of
/// them can otherwise overlap: they share one temp path, and the second rename
/// would find nothing to rename. Serialized, the last call also wins the file.
Future<void> _bikeWrites = Future<void>.value();
Future<void> _settingsWrites = Future<void>.value();

Future<void> _writeBikes(List<BikeState> bikes) {
  log.d(SDLogger.db, 'Writing bikes to file');
  // Encoded here rather than inside the queued write: the file has to end up
  // holding what the last caller passed, not whatever the list looks like by
  // the time the queue gets around to it.
  final contents = jsonEncode(bikes);
  if (kDebugMode) {
    log.d(SDLogger.db, 'Bike data: $contents');
  }
  // A failure is logged and swallowed rather than left on the chain: the next
  // save must still run, and nobody awaits this future.
  _bikeWrites = _bikeWrites
      .then((_) async => _writeAtomically(await _bikesFile, contents))
      .catchError((Object e) => log.e(SDLogger.db, 'Error writing bikes', e));
  return _bikeWrites;
}

Future<void> _writeSettings(SettingsModel settings) {
  final contents = jsonEncode(settings);
  _settingsWrites = _settingsWrites
      .then((_) async => _writeAtomically(await _settingsFile, contents))
      .catchError((Object e) => log.e(SDLogger.db, 'Error writing settings', e));
  return _settingsWrites;
}

Future<SettingsModel> _readSettings() async {
  try {
    final file = await _settingsFile;
    final contents = await file.readAsString();
    log.d(SDLogger.db, 'Read settings');
    return SettingsModel.fromJson(jsonDecode(contents));
  } catch (e) {
    log.w(SDLogger.db, 'No settings found, using defaults');
    return const SettingsModel();
  }
}

Future<List<BikeState>> _readBikes() async {
  log.d(SDLogger.db, 'Reading bikes from file');
  try {
    final file = await _bikesFile;
    final contents = await file.readAsString();
    if (kDebugMode) {
      log.d(SDLogger.db, 'Read contents: $contents');
    }
    // Per element, so one unreadable entry does not cost the rider every bike:
    // the catch below returns an empty list, and the next save overwrites the
    // file with it.
    final bikes = <BikeState>[];
    for (final e in jsonDecode(contents) as List) {
      try {
        bikes.add(BikeState.fromJson(e as Map<String, Object?>));
      } catch (err) {
        log.e(SDLogger.db, 'Skipping unreadable bike entry', err);
      }
    }
    log.d(SDLogger.db, 'Read ${bikes.length} bikes');
    return bikes;
  } catch (e) {
    log.e(SDLogger.db, 'Error reading bikes', e);
    return [];
  }
}

@Riverpod(keepAlive: true)
class BikesDB extends _$BikesDB {
  /// Completes when bikes.json has landed in [state].
  final Completer<void> _load = Completer<void>();

  /// The mutations the app made before bikes.json landed.
  ///
  /// [state] is empty until the file lands, and a save persists the whole list.
  /// So a mutation in that window would write the file from an incomplete list
  /// and drop every bike the file still holds. The app queues the mutation here
  /// and replays it on top of the loaded list instead.
  final List<void Function(List<BikeState>)> _pending = [];

  /// True after bikes.json has landed. Until then the list is incomplete.
  bool get isLoaded => _load.isCompleted;

  /// Completes when bikes.json has landed.
  Future<void> get ready => _load.future;

  @override
  List<BikeState> build() {
    _readBikes().then((bikes) {
      final merged = [...bikes];
      for (final op in _pending) {
        op(merged);
      }
      final replayed = _pending.length;
      _pending.clear();
      if (ref.mounted) state = merged;
      if (!_load.isCompleted) _load.complete();
      // One write for the whole replay: the queued mutations were never
      // persisted, because the list they ran on was incomplete.
      if (replayed > 0) {
        log.i(SDLogger.db, 'Replayed $replayed mutations on the loaded bikes');
        _writeBikes(merged);
      }
    });
    return [];
  }

  /// Marks the load as done. For tests that seed [state] by hand.
  @visibleForTesting
  void debugMarkLoaded() {
    if (!_load.isCompleted) _load.complete();
  }

  /// Applies [op] to the bike list and persists the result.
  ///
  /// Before bikes.json lands, the app queues [op] for the replay in [build]
  /// instead of persisting an incomplete list.
  void _mutate(void Function(List<BikeState>) op) {
    // Assign a new list: riverpod compares by identity, so mutating the
    // current list in place would not notify watchers.
    final bikes = [...state];
    op(bikes);
    state = bikes;
    if (isLoaded) {
      _writeBikes(state);
    } else {
      _pending.add(op);
    }
  }

  void saveBike(BikeState bike) {
    // Logged out here, not in the operation: a replay must not log twice.
    if (state.any((element) => element.id == bike.id)) {
      log.d(SDLogger.db, 'Updated bike: ${bike.name}');
    } else {
      log.i(SDLogger.db, 'Added new bike: ${bike.name}');
    }
    _mutate((bikes) {
      final index = bikes.indexWhere((element) => element.id == bike.id);
      if (index == -1) {
        bikes.add(bike);
      } else {
        bikes[index] = bike;
      }
    });
  }

  void deleteBike(BikeState bike) {
    log.i(SDLogger.db, 'Deleted bike: ${bike.name}');
    _mutate((bikes) => bikes.removeWhere((element) => element.id == bike.id));
  }

  BikeState? getBike(String id) {
    try {
      return state.firstWhere((element) => element.id == id);
    } catch (e) {
      log.d(SDLogger.db, 'No bike found with ID: $id');
      return null;
    }
  }
}

@Riverpod(keepAlive: true)
class SettingsDB extends _$SettingsDB {
  @override
  SettingsModel build() {
    _readSettings().then((settings) {
      if (ref.mounted) state = settings;
    });
    return const SettingsModel();
  }

  void save(SettingsModel settings) {
    _writeSettings(settings);
    log.d(SDLogger.db, 'Saved settings: $settings');
    state = settings;
  }
}

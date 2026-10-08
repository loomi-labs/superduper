import 'dart:async';

import 'package:flutter/material.dart';
import 'package:superduper/src/diagnostics/debug_log.dart';
import 'package:superduper/src/domain/bike.dart';
import 'package:superduper/src/theme/app_theme.dart';
import 'package:superduper/src/user_facing_error.dart';
import 'package:superduper/src/widgets/app_design.dart';

/// The debug log of one bike: a switch, the size of the log, a share button
/// and a clear button.
final class DebugLogSection extends StatefulWidget {
  const new({
    required this.saved,
    required this.store,
    required this.onToggle,
    required this.shareLog,
    super.key,
  });

  final SavedBike saved;
  final DebugLogStore store;
  final Future<void> Function(bool enabled) onToggle;

  /// Builds the merged file and opens the share sheet. `origin` is the place
  /// of the share button.
  final Future<void> Function(Rect? origin) shareLog;

  @override
  State<DebugLogSection> createState() => _DebugLogSectionState();
}

final class _DebugLogSectionState extends State<DebugLogSection> {
  var _busy = false;
  DebugLogSummary? _summary;
  StreamSubscription<String>? _changes;
  var _refreshing = false;

  String get _deviceId => widget.saved.bike.deviceId;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    final id = debugLogFileId(_deviceId);
    _changes = widget.store.changes
        .where((changed) => changed == id)
        .listen((_) => unawaited(_refresh()));
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// Reads the size and the time span without blocking the page.
  Future<void> _refresh() async {
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    try {
      final summary = await widget.store.summary(_deviceId);
      if (mounted) {
        setState(() => _summary = summary);
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(eyebrow: 'Support', title: 'Debug log'),
        const SizedBox(height: 16),
        SurfacePanel(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                key: const Key('debug-log-switch'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                secondary: const Icon(Icons.bug_report_outlined),
                title: const Text('Debug log'),
                subtitle: const Text(
                  'Records the connection, speed limit, street-legal lock and '
                  'background sync of this bike. For bug reports.',
                ),
                value: widget.saved.debugLogEnabled,
                onChanged: _busy
                    ? null
                    : (enabled) => unawaited(_toggle(enabled)),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _summaryText(summary),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 14),
                    Builder(
                      builder: (buttonContext) => FilledButton.icon(
                        key: const Key('debug-log-share'),
                        onPressed: summary == null || _busy
                            ? null
                            : () => unawaited(_share(buttonContext)),
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.ios_share_rounded),
                        label: const Text('Save or send debug log'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: const Key('debug-log-clear'),
                      onPressed: summary == null || _busy
                          ? null
                          : () => unawaited(_confirmClear()),
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Clear log'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _summaryText(DebugLogSummary? summary) {
    if (summary == null) {
      return 'No log yet.';
    }
    final size = 'Log size: ${_formatBytes(summary.bytes)}';
    final first = summary.first?.toLocal();
    final last = summary.last?.toLocal();
    if (first == null || last == null) {
      return size;
    }
    return '$size. From ${_formatTime(first)} to ${_formatTime(last)}.';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _formatTime(DateTime value) {
    String two(int part) => part.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _toggle(bool enabled) async {
    setState(() => _busy = true);
    try {
      await widget.onToggle(enabled);
      await _refresh();
    } on Object catch (error) {
      _showMessage(userFacingError(error, context: UserErrorContext.saveBike));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    final renderBox = buttonContext.findRenderObject() as RenderBox?;
    final origin = renderBox == null
        ? null
        : renderBox.localToGlobal(Offset.zero) & renderBox.size;
    setState(() => _busy = true);
    try {
      await widget.shareLog(origin);
      await _refresh();
    } on Object catch (error) {
      _showMessage(userFacingError(error, context: UserErrorContext.report));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the debug log?'),
        content: const Text(
          'This deletes all log files of this bike. The switch stays as it is.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      widget.store.clear(_deviceId);
      await _refresh();
    }
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

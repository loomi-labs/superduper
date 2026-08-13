import 'package:flutter/material.dart';
import 'package:superduper/theme.dart';

/// One row [showPinValueSheet] can offer: the value it returns, and the label
/// it shows.
class PinSheetOption<T> {
  const PinSheetOption(this.value, this.label);
  final T value;
  final String label;
}

/// A plain radio-list bottom sheet: the rider picks one of [options], which
/// [Navigator.pop]s that value. Dismissing it (tap outside, drag down) resolves
/// to null and picks nothing — the same contract as `_showColorPicker` in
/// edit_bike.dart, which this sheet is built on.
///
/// [current] marks the pre-selected row, or nothing when it resolves to none
/// of [options] (e.g. a dangling id).
Future<T?> showPinValueSheet<T>(
  BuildContext context, {
  required String title,
  required List<PinSheetOption<T>> options,
  required T? current,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.black,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => _PinValueSheet<T>(
      title: title,
      options: options,
      current: current,
    ),
  );
}

class _PinValueSheet<T> extends StatelessWidget {
  const _PinValueSheet({
    required this.title,
    required this.options,
    required this.current,
  });

  final String title;
  final List<PinSheetOption<T>> options;
  final T? current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The drag handle, same shape as _showColorPicker's.
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 16),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: SDSurface.text,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                for (var i = 0; i < options.length; i++) ...[
                  if (i > 0) const SizedBox(height: 6),
                  _PinOptionRow<T>(
                    option: options[i],
                    selected: options[i].value == current,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// One tappable row: the same radio-and-label idiom as [SelectorChip]'s row
/// layout, built lighter because this sheet has no pin marks or segments to
/// carry.
class _PinOptionRow<T> extends StatelessWidget {
  const _PinOptionRow({required this.option, required this.selected});

  final PinSheetOption<T> option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('pinSheetOption:${option.value}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.pop(context, option.value),
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: SDSurface.row,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 20,
                color: selected ? SDSurface.text : SDSurface.muted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  option.label,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: selected ? SDSurface.text : SDSurface.muted,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.w400,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

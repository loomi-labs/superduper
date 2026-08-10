import 'package:flutter/material.dart';
import 'package:superduper/colors.dart';
import 'package:superduper/theme.dart';

/// How a [SelectorBody] lays its choices out.
enum SelectorLayout {
  /// One full-width row per choice. The only safe layout for a list whose
  /// length the rider controls, such as the bike's modes.
  rows,

  /// Equal-width segments on one line. Only for a fixed, small count: five
  /// assist levels always fit, and so can never wrap the way the old chips did.
  segments,
}

/// One choice in a [SelectorCard]. The caller supplies the finished key and
/// tooltip strings so the card stays generic — it never has to know whether it
/// is showing modes, assist levels or anything else.
class SelectorItem {
  const SelectorItem(
      {required this.keyValue,
      required this.label,
      required this.tooltip,
      required this.selected,
      required this.onTap});

  /// The value of the chip's `ValueKey`, e.g. `modeChip:<id>`.
  final String keyValue;
  final String label;
  final String tooltip;
  final bool selected;

  /// Null makes the chip inert — what a control shows while the bike is not
  /// connected, because a tap could not reach the bike anyway.
  final VoidCallback? onTap;
}

/// Shows whether a control is on. Deliberately not a Material [Switch]: the
/// whole card carries the tap, and a second gesture inside it would fight the
/// first.
class ControlSwitch extends StatelessWidget {
  const ControlSwitch({super.key, required this.on, required this.accent});

  final bool on;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 24,
      decoration: BoxDecoration(
        color: on ? accent : SDSurface.border,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Align(
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: on ? SDSurface.page : SDSurface.label,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// A control section: a header with the section's title, its state and its
/// lock, and an optional body of choices under it.
///
/// The card is graphite for every bike. The bike's colour enters only through
/// [colorIndex], and only as an accent on the icon, the switch and the
/// selection inside [body] — see [SDSurface].
class ControlCard extends StatelessWidget {
  const ControlCard({
    super.key,
    required this.title,
    required this.colorIndex,
    this.titleIcon,
    this.active = false,
    this.showSwitch = true,
    this.enabled = true,
    this.onTap,
    this.trailing,
    this.body,
  });

  final String title;
  final int colorIndex;
  final IconData? titleIcon;

  /// Whether the control is on, or holds a selection. Drives the accent.
  final bool active;

  /// Whether the header shows a [ControlSwitch]. False for a section whose
  /// state lives in its [body] instead.
  final bool showSwitch;

  /// False dims everything the bike owns. [trailing] keeps full contrast: a
  /// lock is app state, so it still works while the bike is out of range.
  final bool enabled;

  final VoidCallback? onTap;

  /// The lock button, or nothing for a section that has no lock.
  final Widget? trailing;

  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final accent = getColor(colorIndex).accent();
    final header = Row(
      children: [
        if (titleIcon != null) ...[
          Icon(titleIcon, size: 20, color: active ? accent : SDSurface.label),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: SDSurface.text,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
        if (showSwitch) ControlSwitch(on: active, accent: accent),
      ],
    );

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: SDSurface.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: SDSurface.border),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                      child:
                          Opacity(opacity: enabled ? 1.0 : 0.5, child: header)),
                  // Outside the Opacity on purpose: the lock stays usable, and
                  // has to stay readable, while the bike is out of range.
                  if (trailing != null) trailing! else const SizedBox(width: 8),
                ],
              ),
              if (body != null)
                Opacity(
                  opacity: enabled ? 1.0 : 0.5,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12, right: 8),
                    child: body,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The choices inside a [ControlCard], laid out by [layout].
class SelectorBody extends StatelessWidget {
  const SelectorBody({
    super.key,
    required this.items,
    required this.layout,
    required this.colorIndex,
  });

  final List<SelectorItem> items;
  final SelectorLayout layout;
  final int colorIndex;

  @override
  Widget build(BuildContext context) {
    final range = getColor(colorIndex);

    SelectorChip chip(SelectorItem item) => SelectorChip(
          key: ValueKey(item.keyValue),
          item: item,
          layout: layout,
          accent: range.accent(),
          onAccent: range.onAccent(),
        );

    if (layout == SelectorLayout.segments) {
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: SDSurface.border),
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                Container(width: 1, height: 44, color: SDSurface.border),
              Expanded(child: chip(items[i])),
            ],
          ],
        ),
      );
    }

    return Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          chip(items[i]),
        ],
      ],
    );
  }
}

/// A single tappable choice inside a [SelectorBody].
class SelectorChip extends StatelessWidget {
  const SelectorChip({
    super.key,
    required this.item,
    required this.layout,
    required this.accent,
    required this.onAccent,
  });

  final SelectorItem item;
  final SelectorLayout layout;

  /// The bike's accent colour.
  final Color accent;

  /// What a label on a solid [accent] fill must be, so a near-white or pastel
  /// accent still carries a readable label.
  final Color onAccent;

  @override
  Widget build(BuildContext context) {
    final selected = item.selected;
    final isSegment = layout == SelectorLayout.segments;

    // Exactly one Text per chip: test/pickers_test.dart reads the chip's label
    // and its weight through a single-Text finder. Draft A's "active" caption
    // on the selected mode row is left out for that reason, and because the
    // accent and the bold label already say which row is active.
    final label = Text(
      item.label,
      overflow: TextOverflow.ellipsis,
      textAlign: isSegment ? TextAlign.center : TextAlign.start,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: selected
                ? (isSegment ? onAccent : SDSurface.text)
                : SDSurface.muted,
            fontWeight: selected ? FontWeight.bold : FontWeight.w400,
          ),
    );

    final Widget content = isSegment
        ? Container(
            height: 48,
            alignment: Alignment.center,
            color: selected ? accent : Colors.transparent,
            child: label,
          )
        : Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: selected ? accent.withAlpha(33) : SDSurface.row,
              borderRadius: BorderRadius.circular(12),
              // A transparent border still takes its line of layout, so a
              // selected row is exactly as tall as an unselected one.
              border: Border.all(color: selected ? accent : Colors.transparent),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: selected ? accent : SDSurface.muted,
                ),
                const SizedBox(width: 12),
                Expanded(child: label),
              ],
            ),
          );

    return Tooltip(
      message: item.tooltip,
      child: GestureDetector(
        onTap: item.onTap,
        behavior: HitTestBehavior.opaque,
        child: content,
      ),
    );
  }
}

class DiscoverCard extends StatelessWidget {
  final String? title;
  final String? subtitle;
  final String? metric;
  final int colorIndex;
  final double? height;
  final double? width;
  final Widget? vectorBottom;
  final Widget? vectorTop;
  final Function()? onTap;
  final Function()? onLongPress;
  final String? tag;
  final bool selected;
  final IconData? titleIcon;

  const DiscoverCard(
      {super.key,
      this.title,
      this.subtitle,
      this.height,
      this.width,
      this.vectorBottom,
      this.vectorTop,
      this.onTap,
      this.onLongPress,
      this.tag,
      this.metric,
      this.colorIndex = 0,
      this.selected = true,
      this.titleIcon});

  @override
  Widget build(BuildContext context) {
    var defaultColors = getColor(colorIndex);
    var startColor = defaultColors.start;
    var endColor = defaultColors.end;
    var textColor = defaultColors.fontColor();

    if (!selected) {
      startColor = Colors.grey[800]!;
      endColor = Colors.grey[800]!;
    }

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              colors: [
                startColor,
                endColor,
              ],
              begin: Alignment.bottomLeft,
              end: Alignment.topRight,
            ),
          ),
          child: Padding(
            padding:
                const EdgeInsets.only(left: 24, top: 20, bottom: 20, right: 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (titleIcon != null) // Check if there's an icon
                            Icon(
                              titleIcon,
                              size: 24, // Adjust the size as needed
                              color: textColor,
                            ),
                          if (titleIcon !=
                              null) // Add spacing if there's an icon
                            const SizedBox(width: 10),
                          if (title != null)
                            Text(
                              title!,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: textColor),
                            ),
                        ],
                      ),
                      if (subtitle != null)
                        Column(
                          children: [
                            const SizedBox(
                              height: 5,
                            ),
                            Text(
                              subtitle!,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w300,
                              ).copyWith(color: textColor),
                            ),
                          ],
                        )
                    ],
                  ),
                ),
                metric != null
                    ? Text(
                        metric!,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: textColor),
                      )
                    : Container(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

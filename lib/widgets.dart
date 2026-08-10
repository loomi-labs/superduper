import 'package:flutter/material.dart';
import 'package:superduper/colors.dart';

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

/// A [DiscoverCard]-styled panel holding a wrapped row of choices.
///
/// Unlike [DiscoverCard] this is not a toggle, so it always renders on the
/// bike's colour gradient: the card is the control panel, and the selection
/// lives in the chips.
class SelectorCard extends StatelessWidget {
  const SelectorCard(
      {super.key,
      required this.items,
      this.title,
      this.titleIcon,
      this.colorIndex = 0});

  final int colorIndex;
  final String? title;
  final IconData? titleIcon;
  final List<SelectorItem> items;

  @override
  Widget build(BuildContext context) {
    var defaultColors = getColor(colorIndex);
    var textColor = defaultColors.fontColor();

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          gradient: LinearGradient(
            colors: [
              defaultColors.start,
              defaultColors.end,
            ],
            begin: Alignment.bottomLeft,
            end: Alignment.topRight,
          ),
        ),
        child: Padding(
          padding:
              const EdgeInsets.only(left: 24, top: 20, bottom: 20, right: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (titleIcon != null) // Check if there's an icon
                    Icon(
                      titleIcon,
                      size: 24,
                      color: textColor,
                    ),
                  if (titleIcon != null) // Add spacing if there's an icon
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
              const SizedBox(height: 14),
              // A wrap, not a scroller: every choice stays visible and tappable
              // without scrolling, with gloves on or from a driver script.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in items)
                    SelectorChip(
                      key: ValueKey(item.keyValue),
                      item: item,
                      textColor: textColor,
                      selectedLabelColor: defaultColors.start,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single tappable pill inside a [SelectorCard].
class SelectorChip extends StatelessWidget {
  const SelectorChip(
      {super.key,
      required this.item,
      required this.textColor,
      required this.selectedLabelColor});

  final SelectorItem item;

  /// The card's foreground colour, picked for contrast against the gradient.
  final Color textColor;

  /// What a filled pill's label sits on: the gradient's own start colour, which
  /// [ColorRange.fontColor] already picked [textColor] to contrast with.
  final Color selectedLabelColor;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: item.tooltip,
      child: GestureDetector(
        onTap: item.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: item.selected
                ? textColor
                : Colors.black.withAlpha(51), // 0.2 opacity
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            item.label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: item.selected ? selectedLabelColor : textColor,
                  fontWeight: item.selected ? FontWeight.bold : FontWeight.w400,
                ),
          ),
        ),
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

import 'package:flutter/material.dart';
import 'package:superduper/colors.dart';
import 'package:superduper/models.dart';
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
      this.pinned = false,
      required this.onTap});

  /// The value of the chip's `ValueKey`, e.g. `modeChip:<id>`.
  final String keyValue;
  final String label;
  final String tooltip;
  final bool selected;

  /// Whether a startup pin starts the ride on this choice. Marked in place, so
  /// the pinned value is visible where the rider picks values.
  final bool pinned;

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

/// What the padlock says in each of its states, for the value called [noun].
///
/// Every state has its own line: a padlock that only changes colour tells a
/// screen reader nothing, and the three states are not guessable from an icon.
String pinTooltip(PinState pin, String noun) => switch (pin) {
      PinState.open => 'The $noun is open. Tap to pin it for the ride start.',
      PinState.startup =>
        'The $noun is pinned for the ride start. Tap to lock it.',
      PinState.locked => 'The $noun is locked. Tap to open it.',
    };

/// The padlock: one tap moves the pin one step, through [nextPin].
///
/// It shows app state, not bike state, so it keeps working — and keeps full
/// contrast — while the bike is out of range.
class EnhancedLockWidget extends StatelessWidget {
  const EnhancedLockWidget({
    super.key,
    PinState? pin,
    // The two-state contract, kept for callers that only know a lock.
    bool locked = false,
    required this.onTap,
    required this.tooltip,
    this.degraded = false,
  }) : pin = pin ?? (locked ? PinState.locked : PinState.open);

  final PinState pin;
  final VoidCallback onTap;

  /// What this state means, from [pinTooltip]. Passed in rather than composed
  /// here, because only the caller knows which value the padlock holds.
  final String tooltip;

  /// The lock is on, but the app cannot hold it while the phone is in a
  /// pocket. Shown rather than hidden: a padlock that quietly stops working is
  /// the bug this page was fixed for.
  final bool degraded;

  static IconData _iconFor(PinState pin) => switch (pin) {
        PinState.open => Icons.lock_open,
        PinState.startup => Icons.push_pin,
        PinState.locked => Icons.lock,
      };

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip:
          degraded ? '$tooltip (only holds while the app is open)' : tooltip,
      iconSize: 20,
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      onPressed: onTap,
      icon: Icon(
        _iconFor(pin),
        color: degraded
            ? SDSurface.warning
            : (pin == PinState.open ? SDSurface.muted : SDSurface.text),
      ),
    );
  }
}

/// The width a pinned row keeps free at its right end, for the badge that is
/// drawn over it. Wide enough for the badge and the gap beside it.
const pinBadgeReserve = 72.0;

/// A short tag that marks what a startup pin does.
///
/// Filled with the bike's accent, with the label picked for contrast against
/// it, so a near-white or pastel accent still carries a readable tag.
class _PinBadge extends StatelessWidget {
  const _PinBadge(
      {super.key,
      required this.text,
      required this.accent,
      required this.onAccent});

  final String text;
  final Color accent;
  final Color onAccent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: onAccent,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
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
    this.badge,
    this.caption,
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

  /// A startup pin's tag, for a section that has no list to mark it in — the
  /// light is on or off, and nothing else.
  final String? badge;

  /// One line under the header, or nothing. Says what the card's taps do while
  /// they mean something other than the usual — a startup pin turns the card
  /// into a picker for the value a ride starts on, and a marker cannot say
  /// that. Dimmed with the [body].
  final String? caption;

  /// The lock button, or nothing for a section that has no lock.
  final Widget? trailing;

  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final range = getColor(colorIndex);
    final accent = range.accent();
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
        if (badge != null) ...[
          _PinBadge(text: badge!, accent: accent, onAccent: range.onAccent()),
          const SizedBox(width: 10),
        ],
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
              // One Opacity for everything under the header, so a card with a
              // caption fades as one piece rather than in two steps.
              if (caption != null || body != null)
                Opacity(
                  opacity: enabled ? 1.0 : 0.5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (caption != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, right: 8),
                          child: Text(
                            caption!,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: SDSurface.muted, fontSize: 12),
                          ),
                        ),
                      if (body != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12, right: 8),
                          child: body,
                        ),
                    ],
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
    this.caption,
  });

  final List<SelectorItem> items;
  final SelectorLayout layout;
  final int colorIndex;

  /// One line under the choices, or nothing. A marker under a 48 dp segment
  /// cannot carry its meaning alone, so the assist card says it in words.
  final String? caption;

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

    // Every pin mark is a sibling of the chip, never a child: a chip holds
    // exactly one Text, which is what the finders in test/pickers_test.dart
    // read the label through. IgnorePointer keeps the mark from swallowing the
    // tap that selects the choice it marks.

    // A segment is too small for a tag, so the pin is a 3 dp underline. On the
    // selected segment it is drawn in the label's colour, because the accent
    // fill is already under it.
    Widget segment(SelectorItem item) => Stack(
          children: [
            chip(item),
            if (item.pinned)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: Container(
                    key: ValueKey('pinMark:${item.keyValue}'),
                    height: 3,
                    color: item.selected ? range.onAccent() : range.accent(),
                  ),
                ),
              ),
          ],
        );

    Widget row(SelectorItem item) => Stack(
          children: [
            chip(item),
            if (item.pinned)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 14),
                      child: _PinBadge(
                        key: ValueKey('pinMark:${item.keyValue}'),
                        text: 'START',
                        accent: range.accent(),
                        onAccent: range.onAccent(),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );

    final Widget choices = layout == SelectorLayout.segments
        ? Container(
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
                  Expanded(child: segment(items[i])),
                ],
              ],
            ),
          )
        : Column(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                row(items[i]),
              ],
            ],
          );

    if (caption == null) {
      return choices;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        choices,
        const SizedBox(height: 8),
        Text(
          caption!,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: SDSurface.muted, fontSize: 12),
        ),
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
                // Room for the START badge, which the body draws over the row
                // rather than in it. Without it a long mode name runs under
                // the badge, because the label ellipsises at the full width.
                if (item.pinned) const SizedBox(width: pinBadgeReserve),
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

/// A bike row on the select page.
///
/// The card uses the same graphite surface as a [ControlCard], so the first
/// screen and the bike page read as one app. The bike's colour enters only as
/// an accent on [titleIcon], and only while [selected].
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
    final accent = getColor(colorIndex).accent();

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          decoration: BoxDecoration(
            color: SDSurface.card,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: SDSurface.border),
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
                              color: selected ? accent : SDSurface.muted,
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
                                  ?.copyWith(color: SDSurface.text),
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
                                color: SDSurface.label,
                              ),
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
                            ?.copyWith(color: SDSurface.label),
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

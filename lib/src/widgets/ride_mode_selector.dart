import 'package:flutter/material.dart';
import 'package:superduper/src/domain/ride_modes.dart';

/// Chips for the modes a V1 bike offers. Custom modes first, then the
/// region's native wires. A wire the bike reports that is not on offer is
/// shown as one more chip, so the rider always sees what the bike rides.
final class RideModeSelector extends StatelessWidget {
  const new({
    required this.options,
    required this.selected,
    required this.region,
    required this.enabled,
    required this.onSelected,
    this.observedWire,
    super.key,
  });

  final List<RideModeSelection> options;
  final RideModeSelection? selected;
  final BikeRegion? region;
  final bool enabled;
  final ValueChanged<RideModeSelection> onSelected;
  final int? observedWire;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = [
      ...options,
      if (observedWire case final wire?
          when !options.contains(NativeRideMode(wire)))
        NativeRideMode(wire),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in shown)
          Tooltip(
            message: switch (option) {
              NativeRideMode(:final profile) =>
                '${profile.name}: ${profile.note}',
              CustomRideMode(:final mode) =>
                '${mode.effectiveLimitKmh} km/h${mode.throttle ? ' + throttle' : ''}',
            },
            child: ChoiceChip(
              key: ValueKey(switch (option) {
                NativeRideMode(:final wire) => 'ride-mode-native-$wire',
                CustomRideMode(:final mode) => 'ride-mode-custom-${mode.id}',
              }),
              label: Text(option.label(region)),
              selected: option == selected,
              onSelected: enabled ? (_) => onSelected(option) : null,
              selectedColor: scheme.primary,
              labelStyle: TextStyle(
                fontWeight: FontWeight.w800,
                color: option == selected ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          ),
      ],
    );
  }
}

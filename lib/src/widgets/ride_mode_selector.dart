import 'package:flutter/material.dart';
import 'package:superduper/src/domain/ride_modes.dart';

/// Chips for the modes a V1 bike offers. Custom modes first, then the
/// region's native wires. A wire the bike reports that is not on offer is
/// shown as one more chip, so the rider always sees what the bike rides. The
/// chip stays hidden while the selected custom mode runs that wire. The chip
/// cannot be tapped: the region does not offer the wire.
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
    final extra = switch (observedWire) {
      final wire?
          when !options.contains(NativeRideMode(wire)) &&
              !switch (selected) {
                final CustomRideMode custom => assertsWire(
                  custom,
                  wire,
                  region,
                ),
                _ => false,
              } =>
        NativeRideMode(wire),
      _ => null,
    };
    final shown = [...options, ?extra];
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
              onSelected: enabled && option != extra
                  ? (_) => onSelected(option)
                  : null,
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

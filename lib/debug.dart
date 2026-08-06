import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:superduper/db.dart';
import 'package:superduper/fake_bike.dart';

import 'bike.dart';
import 'edit_bike.dart';

class DebugPage extends ConsumerWidget {
  const DebugPage({super.key});

  /// Generates a MAC-like id that [isFakeBike] recognizes.
  String _generateFakeMac() {
    final random = Random();
    final parts = List.generate(4, (_) => random.nextInt(256));
    return fakeBikeIdPrefix +
        parts.map((part) => part.toRadixString(16).padLeft(2, '0')).join(':');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fakeBikes =
        ref.watch(bikesDBProvider).where((bike) => isFakeBike(bike.id)).toList();
    final store = ref.watch(fakeBikeStoreProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
      ),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: ElevatedButton(
              onPressed: () {
                showModalBottomSheet<void>(
                    isScrollControlled: true,
                    context: context,
                    builder: (BuildContext context) {
                      return BikeSettingsWidget(
                          bike: BikeState.defaultState(_generateFakeMac()));
                    });
              },
              child: const Text('Create fake bike'),
            ),
          ),
          if (fakeBikes.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Text(
                'Fake bikes. The light/assist buttons simulate the rider '
                'pressing a button on the bike itself; the mode button '
                'simulates another app changing the mode (the bike has no mode '
                'button). The app picks the change up on its next poll. '
                'The slider simulates the rider speed that the CH dynamic mode '
                'follows; it switches over at '
                '${chSpeedThresholdKmh.round()} km/h.',
              ),
            ),
            for (final bike in fakeBikes)
              Column(
                // Keyed so deleting a bike cannot hand its speed slider state
                // to whichever bike takes over its position in the list.
                key: ValueKey(bike.id),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    title: Text(bike.name),
                    subtitle: Text(bike.id),
                    onTap: () {
                      Navigator.push<void>(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => BikePage(bikeID: bike.id),
                        ),
                      );
                    },
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Rider toggles light',
                          icon: const Icon(Icons.lightbulb_outline),
                          onPressed: () => store.toggleLight(bike.id),
                        ),
                        IconButton(
                          tooltip: 'Another app changes mode',
                          icon: const Icon(Icons.electric_bike),
                          onPressed: () => store.cycleMode(bike.id),
                        ),
                        IconButton(
                          tooltip: 'Rider changes assist',
                          icon: const Icon(Icons.autorenew),
                          onPressed: () => store.cycleAssist(bike.id),
                        ),
                      ],
                    ),
                  ),
                  _FakeBikeSpeedControl(deviceId: bike.id),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

/// Feeds a rider speed into one fake bike, standing in for the speed
/// notifications a real bike sends. Ranges well past the CH dynamic-mode
/// threshold so it can be crossed in both directions.
class _FakeBikeSpeedControl extends ConsumerStatefulWidget {
  const _FakeBikeSpeedControl({required this.deviceId});
  final String deviceId;

  @override
  ConsumerState<_FakeBikeSpeedControl> createState() =>
      _FakeBikeSpeedControlState();
}

class _FakeBikeSpeedControlState extends ConsumerState<_FakeBikeSpeedControl> {
  static const _maxKmh = 45.0;

  late double _speedKmh;

  @override
  void initState() {
    super.initState();
    _speedKmh = ref.read(fakeBikeStoreProvider).speedKmh(widget.deviceId);
  }

  void _setSpeed(double kmh) {
    final clamped = kmh.clamp(0.0, _maxKmh);
    setState(() {
      _speedKmh = clamped;
    });
    ref.read(fakeBikeStoreProvider).setSpeed(widget.deviceId, clamped);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 8, bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.speed, size: 20),
          Expanded(
            child: Slider(
              value: _speedKmh,
              max: _maxKmh,
              divisions: _maxKmh.round(),
              label: '${_speedKmh.round()} km/h',
              onChanged: _setSpeed,
            ),
          ),
          SizedBox(
            width: 68,
            child: Text(
              '${_speedKmh.round()} km/h',
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

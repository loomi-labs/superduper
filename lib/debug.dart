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
                      // Preset a region: the form requires one, and a fresh
                      // bike has none, which makes Save silently do nothing.
                      return BikeSettingsWidget(
                          bike: BikeState.defaultState(_generateFakeMac())
                              .copyWith(region: BikeRegion.us));
                    });
              },
              child: const Text('Create fake bike'),
            ),
          ),
          if (fakeBikes.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.0),
              child: Text(
                'Fake bikes. The buttons simulate a rider pressing a button on '
                'the bike itself. The app picks the change up on its next poll.',
              ),
            ),
            for (final bike in fakeBikes)
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
                      tooltip: 'Rider changes mode',
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
          ],
        ],
      ),
    );
  }
}

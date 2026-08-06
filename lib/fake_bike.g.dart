// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'fake_bike.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// In-memory stand-in for a bike's state register. Kept alive so it survives
/// the auto-dispose of ConnectionHandler.

@ProviderFor(fakeBikeStore)
final fakeBikeStoreProvider = FakeBikeStoreProvider._();

/// In-memory stand-in for a bike's state register. Kept alive so it survives
/// the auto-dispose of ConnectionHandler.

final class FakeBikeStoreProvider
    extends $FunctionalProvider<FakeBikeStore, FakeBikeStore, FakeBikeStore>
    with $Provider<FakeBikeStore> {
  /// In-memory stand-in for a bike's state register. Kept alive so it survives
  /// the auto-dispose of ConnectionHandler.
  FakeBikeStoreProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'fakeBikeStoreProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$fakeBikeStoreHash();

  @$internal
  @override
  $ProviderElement<FakeBikeStore> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  FakeBikeStore create(Ref ref) {
    return fakeBikeStore(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(FakeBikeStore value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<FakeBikeStore>(value),
    );
  }
}

String _$fakeBikeStoreHash() => r'b455ada32f003bd58ac92893b7b15a4bb4be49ea';

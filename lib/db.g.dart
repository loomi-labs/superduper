// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'db.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_SettingsModel _$SettingsModelFromJson(Map<String, dynamic> json) =>
    _SettingsModel(currentBike: json['currentBike'] as String?);

Map<String, dynamic> _$SettingsModelToJson(_SettingsModel instance) =>
    <String, dynamic>{'currentBike': instance.currentBike};

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(BikesDB)
final bikesDBProvider = BikesDBProvider._();

final class BikesDBProvider
    extends $NotifierProvider<BikesDB, List<BikeState>> {
  BikesDBProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'bikesDBProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$bikesDBHash();

  @$internal
  @override
  BikesDB create() => BikesDB();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(List<BikeState> value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<List<BikeState>>(value),
    );
  }
}

String _$bikesDBHash() => r'48b105d80cfd55289ea8baebf5fca10ac5428e7f';

abstract class _$BikesDB extends $Notifier<List<BikeState>> {
  List<BikeState> build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<List<BikeState>, List<BikeState>>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<List<BikeState>, List<BikeState>>,
              List<BikeState>,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(SettingsDB)
final settingsDBProvider = SettingsDBProvider._();

final class SettingsDBProvider
    extends $NotifierProvider<SettingsDB, SettingsModel> {
  SettingsDBProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'settingsDBProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$settingsDBHash();

  @$internal
  @override
  SettingsDB create() => SettingsDB();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SettingsModel value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SettingsModel>(value),
    );
  }
}

String _$settingsDBHash() => r'be5fefb75813f8c2cd654f28ea321b83930aa96b';

abstract class _$SettingsDB extends $Notifier<SettingsModel> {
  SettingsModel build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<SettingsModel, SettingsModel>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<SettingsModel, SettingsModel>,
              SettingsModel,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'bike.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning
/// Whether the rider refused the notification the foreground service needs, so
/// a locked padlock cannot be held while the phone is in a pocket.
///
/// Not gated on the platform: the pins show as degraded from this one flag, and
/// [backgroundStatusFor] adds what the platform can do.

@ProviderFor(NotificationsBlocked)
final notificationsBlockedProvider = NotificationsBlockedProvider._();

/// Whether the rider refused the notification the foreground service needs, so
/// a locked padlock cannot be held while the phone is in a pocket.
///
/// Not gated on the platform: the pins show as degraded from this one flag, and
/// [backgroundStatusFor] adds what the platform can do.
final class NotificationsBlockedProvider
    extends $NotifierProvider<NotificationsBlocked, bool> {
  /// Whether the rider refused the notification the foreground service needs, so
  /// a locked padlock cannot be held while the phone is in a pocket.
  ///
  /// Not gated on the platform: the pins show as degraded from this one flag, and
  /// [backgroundStatusFor] adds what the platform can do.
  NotificationsBlockedProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'notificationsBlockedProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$notificationsBlockedHash();

  @$internal
  @override
  NotificationsBlocked create() => NotificationsBlocked();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(bool value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<bool>(value),
    );
  }
}

String _$notificationsBlockedHash() =>
    r'8910345ef1f8fe292cb038ca3864def17502ead6';

/// Whether the rider refused the notification the foreground service needs, so
/// a locked padlock cannot be held while the phone is in a pocket.
///
/// Not gated on the platform: the pins show as degraded from this one flag, and
/// [backgroundStatusFor] adds what the platform can do.

abstract class _$NotificationsBlocked extends $Notifier<bool> {
  bool build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<bool, bool>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<bool, bool>,
              bool,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}

@ProviderFor(Bike)
final bikeProvider = BikeFamily._();

final class BikeProvider extends $NotifierProvider<Bike, BikeState> {
  BikeProvider._({
    required BikeFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'bikeProvider',
         isAutoDispose: true,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$bikeHash();

  @override
  String toString() {
    return r'bikeProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  Bike create() => Bike();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(BikeState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<BikeState>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is BikeProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$bikeHash() => r'f88c2a4990df8ab5c2be16734f7fcc0d191bec48';

final class BikeFamily extends $Family
    with $ClassFamilyOverride<Bike, BikeState, BikeState, BikeState, String> {
  BikeFamily._()
    : super(
        retry: null,
        name: r'bikeProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: true,
      );

  BikeProvider call(String id) => BikeProvider._(argument: id, from: this);

  @override
  String toString() => r'bikeProvider';
}

abstract class _$Bike extends $Notifier<BikeState> {
  late final _$args = ref.$arg as String;
  String get id => _$args;

  BikeState build(String id);
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<BikeState, BikeState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<BikeState, BikeState>,
              BikeState,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, () => build(_$args));
  }
}

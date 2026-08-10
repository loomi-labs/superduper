// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'models.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$CustomMode {

 String get id; String get name; int get limitKmh; bool get throttle;
/// Create a copy of CustomMode
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$CustomModeCopyWith<CustomMode> get copyWith => _$CustomModeCopyWithImpl<CustomMode>(this as CustomMode, _$identity);

  /// Serializes this CustomMode to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is CustomMode&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.limitKmh, limitKmh) || other.limitKmh == limitKmh)&&(identical(other.throttle, throttle) || other.throttle == throttle));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,limitKmh,throttle);

@override
String toString() {
  return 'CustomMode(id: $id, name: $name, limitKmh: $limitKmh, throttle: $throttle)';
}


}

/// @nodoc
abstract mixin class $CustomModeCopyWith<$Res>  {
  factory $CustomModeCopyWith(CustomMode value, $Res Function(CustomMode) _then) = _$CustomModeCopyWithImpl;
@useResult
$Res call({
 String id, String name, int limitKmh, bool throttle
});




}
/// @nodoc
class _$CustomModeCopyWithImpl<$Res>
    implements $CustomModeCopyWith<$Res> {
  _$CustomModeCopyWithImpl(this._self, this._then);

  final CustomMode _self;
  final $Res Function(CustomMode) _then;

/// Create a copy of CustomMode
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? name = null,Object? limitKmh = null,Object? throttle = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,limitKmh: null == limitKmh ? _self.limitKmh : limitKmh // ignore: cast_nullable_to_non_nullable
as int,throttle: null == throttle ? _self.throttle : throttle // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [CustomMode].
extension CustomModePatterns on CustomMode {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _CustomMode value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _CustomMode() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _CustomMode value)  $default,){
final _that = this;
switch (_that) {
case _CustomMode():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _CustomMode value)?  $default,){
final _that = this;
switch (_that) {
case _CustomMode() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id,  String name,  int limitKmh,  bool throttle)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _CustomMode() when $default != null:
return $default(_that.id,_that.name,_that.limitKmh,_that.throttle);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id,  String name,  int limitKmh,  bool throttle)  $default,) {final _that = this;
switch (_that) {
case _CustomMode():
return $default(_that.id,_that.name,_that.limitKmh,_that.throttle);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id,  String name,  int limitKmh,  bool throttle)?  $default,) {final _that = this;
switch (_that) {
case _CustomMode() when $default != null:
return $default(_that.id,_that.name,_that.limitKmh,_that.throttle);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _CustomMode extends CustomMode {
  const _CustomMode({required this.id, required this.name, required this.limitKmh, this.throttle = false}): super._();
  factory _CustomMode.fromJson(Map<String, dynamic> json) => _$CustomModeFromJson(json);

@override final  String id;
@override final  String name;
@override final  int limitKmh;
@override@JsonKey() final  bool throttle;

/// Create a copy of CustomMode
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$CustomModeCopyWith<_CustomMode> get copyWith => __$CustomModeCopyWithImpl<_CustomMode>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$CustomModeToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _CustomMode&&(identical(other.id, id) || other.id == id)&&(identical(other.name, name) || other.name == name)&&(identical(other.limitKmh, limitKmh) || other.limitKmh == limitKmh)&&(identical(other.throttle, throttle) || other.throttle == throttle));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,name,limitKmh,throttle);

@override
String toString() {
  return 'CustomMode(id: $id, name: $name, limitKmh: $limitKmh, throttle: $throttle)';
}


}

/// @nodoc
abstract mixin class _$CustomModeCopyWith<$Res> implements $CustomModeCopyWith<$Res> {
  factory _$CustomModeCopyWith(_CustomMode value, $Res Function(_CustomMode) _then) = __$CustomModeCopyWithImpl;
@override @useResult
$Res call({
 String id, String name, int limitKmh, bool throttle
});




}
/// @nodoc
class __$CustomModeCopyWithImpl<$Res>
    implements _$CustomModeCopyWith<$Res> {
  __$CustomModeCopyWithImpl(this._self, this._then);

  final _CustomMode _self;
  final $Res Function(_CustomMode) _then;

/// Create a copy of CustomMode
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? name = null,Object? limitKmh = null,Object? throttle = null,}) {
  return _then(_CustomMode(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,limitKmh: null == limitKmh ? _self.limitKmh : limitKmh // ignore: cast_nullable_to_non_nullable
as int,throttle: null == throttle ? _self.throttle : throttle // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$LastSeen {

 int get assist; bool get light; int get wire;
/// Create a copy of LastSeen
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$LastSeenCopyWith<LastSeen> get copyWith => _$LastSeenCopyWithImpl<LastSeen>(this as LastSeen, _$identity);

  /// Serializes this LastSeen to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is LastSeen&&(identical(other.assist, assist) || other.assist == assist)&&(identical(other.light, light) || other.light == light)&&(identical(other.wire, wire) || other.wire == wire));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,assist,light,wire);

@override
String toString() {
  return 'LastSeen(assist: $assist, light: $light, wire: $wire)';
}


}

/// @nodoc
abstract mixin class $LastSeenCopyWith<$Res>  {
  factory $LastSeenCopyWith(LastSeen value, $Res Function(LastSeen) _then) = _$LastSeenCopyWithImpl;
@useResult
$Res call({
 int assist, bool light, int wire
});




}
/// @nodoc
class _$LastSeenCopyWithImpl<$Res>
    implements $LastSeenCopyWith<$Res> {
  _$LastSeenCopyWithImpl(this._self, this._then);

  final LastSeen _self;
  final $Res Function(LastSeen) _then;

/// Create a copy of LastSeen
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? assist = null,Object? light = null,Object? wire = null,}) {
  return _then(_self.copyWith(
assist: null == assist ? _self.assist : assist // ignore: cast_nullable_to_non_nullable
as int,light: null == light ? _self.light : light // ignore: cast_nullable_to_non_nullable
as bool,wire: null == wire ? _self.wire : wire // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [LastSeen].
extension LastSeenPatterns on LastSeen {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _LastSeen value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _LastSeen() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _LastSeen value)  $default,){
final _that = this;
switch (_that) {
case _LastSeen():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _LastSeen value)?  $default,){
final _that = this;
switch (_that) {
case _LastSeen() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( int assist,  bool light,  int wire)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _LastSeen() when $default != null:
return $default(_that.assist,_that.light,_that.wire);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( int assist,  bool light,  int wire)  $default,) {final _that = this;
switch (_that) {
case _LastSeen():
return $default(_that.assist,_that.light,_that.wire);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( int assist,  bool light,  int wire)?  $default,) {final _that = this;
switch (_that) {
case _LastSeen() when $default != null:
return $default(_that.assist,_that.light,_that.wire);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _LastSeen implements LastSeen {
  const _LastSeen({required this.assist, required this.light, required this.wire});
  factory _LastSeen.fromJson(Map<String, dynamic> json) => _$LastSeenFromJson(json);

@override final  int assist;
@override final  bool light;
@override final  int wire;

/// Create a copy of LastSeen
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$LastSeenCopyWith<_LastSeen> get copyWith => __$LastSeenCopyWithImpl<_LastSeen>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$LastSeenToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _LastSeen&&(identical(other.assist, assist) || other.assist == assist)&&(identical(other.light, light) || other.light == light)&&(identical(other.wire, wire) || other.wire == wire));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,assist,light,wire);

@override
String toString() {
  return 'LastSeen(assist: $assist, light: $light, wire: $wire)';
}


}

/// @nodoc
abstract mixin class _$LastSeenCopyWith<$Res> implements $LastSeenCopyWith<$Res> {
  factory _$LastSeenCopyWith(_LastSeen value, $Res Function(_LastSeen) _then) = __$LastSeenCopyWithImpl;
@override @useResult
$Res call({
 int assist, bool light, int wire
});




}
/// @nodoc
class __$LastSeenCopyWithImpl<$Res>
    implements _$LastSeenCopyWith<$Res> {
  __$LastSeenCopyWithImpl(this._self, this._then);

  final _LastSeen _self;
  final $Res Function(_LastSeen) _then;

/// Create a copy of LastSeen
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? assist = null,Object? light = null,Object? wire = null,}) {
  return _then(_LastSeen(
assist: null == assist ? _self.assist : assist // ignore: cast_nullable_to_non_nullable
as int,light: null == light ? _self.light : light // ignore: cast_nullable_to_non_nullable
as bool,wire: null == wire ? _self.wire : wire // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$BikeState {

 String get id;@JsonKey(name: 'mode') int get legacyMode; String get modeId; List<CustomMode> get customModes;@JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState get pinMode; bool get light;@JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState get pinLight; int get assist;@JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState get pinAssist; bool? get startupLight; String? get startupModeId; int? get startupAssist; LastSeen? get lastSeen; String get name; BikeRegion? get region; bool get autoReconnect; int get color;
/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BikeStateCopyWith<BikeState> get copyWith => _$BikeStateCopyWithImpl<BikeState>(this as BikeState, _$identity);

  /// Serializes this BikeState to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BikeState&&(identical(other.id, id) || other.id == id)&&(identical(other.legacyMode, legacyMode) || other.legacyMode == legacyMode)&&(identical(other.modeId, modeId) || other.modeId == modeId)&&const DeepCollectionEquality().equals(other.customModes, customModes)&&(identical(other.pinMode, pinMode) || other.pinMode == pinMode)&&(identical(other.light, light) || other.light == light)&&(identical(other.pinLight, pinLight) || other.pinLight == pinLight)&&(identical(other.assist, assist) || other.assist == assist)&&(identical(other.pinAssist, pinAssist) || other.pinAssist == pinAssist)&&(identical(other.startupLight, startupLight) || other.startupLight == startupLight)&&(identical(other.startupModeId, startupModeId) || other.startupModeId == startupModeId)&&(identical(other.startupAssist, startupAssist) || other.startupAssist == startupAssist)&&(identical(other.lastSeen, lastSeen) || other.lastSeen == lastSeen)&&(identical(other.name, name) || other.name == name)&&(identical(other.region, region) || other.region == region)&&(identical(other.autoReconnect, autoReconnect) || other.autoReconnect == autoReconnect)&&(identical(other.color, color) || other.color == color));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,legacyMode,modeId,const DeepCollectionEquality().hash(customModes),pinMode,light,pinLight,assist,pinAssist,startupLight,startupModeId,startupAssist,lastSeen,name,region,autoReconnect,color);

@override
String toString() {
  return 'BikeState(id: $id, legacyMode: $legacyMode, modeId: $modeId, customModes: $customModes, pinMode: $pinMode, light: $light, pinLight: $pinLight, assist: $assist, pinAssist: $pinAssist, startupLight: $startupLight, startupModeId: $startupModeId, startupAssist: $startupAssist, lastSeen: $lastSeen, name: $name, region: $region, autoReconnect: $autoReconnect, color: $color)';
}


}

/// @nodoc
abstract mixin class $BikeStateCopyWith<$Res>  {
  factory $BikeStateCopyWith(BikeState value, $Res Function(BikeState) _then) = _$BikeStateCopyWithImpl;
@useResult
$Res call({
 String id,@JsonKey(name: 'mode') int legacyMode, String modeId, List<CustomMode> customModes,@JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinMode, bool light,@JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinLight, int assist,@JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinAssist, bool? startupLight, String? startupModeId, int? startupAssist, LastSeen? lastSeen, String name, BikeRegion? region, bool autoReconnect, int color
});


$LastSeenCopyWith<$Res>? get lastSeen;

}
/// @nodoc
class _$BikeStateCopyWithImpl<$Res>
    implements $BikeStateCopyWith<$Res> {
  _$BikeStateCopyWithImpl(this._self, this._then);

  final BikeState _self;
  final $Res Function(BikeState) _then;

/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? legacyMode = null,Object? modeId = null,Object? customModes = null,Object? pinMode = null,Object? light = null,Object? pinLight = null,Object? assist = null,Object? pinAssist = null,Object? startupLight = freezed,Object? startupModeId = freezed,Object? startupAssist = freezed,Object? lastSeen = freezed,Object? name = null,Object? region = freezed,Object? autoReconnect = null,Object? color = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,legacyMode: null == legacyMode ? _self.legacyMode : legacyMode // ignore: cast_nullable_to_non_nullable
as int,modeId: null == modeId ? _self.modeId : modeId // ignore: cast_nullable_to_non_nullable
as String,customModes: null == customModes ? _self.customModes : customModes // ignore: cast_nullable_to_non_nullable
as List<CustomMode>,pinMode: null == pinMode ? _self.pinMode : pinMode // ignore: cast_nullable_to_non_nullable
as PinState,light: null == light ? _self.light : light // ignore: cast_nullable_to_non_nullable
as bool,pinLight: null == pinLight ? _self.pinLight : pinLight // ignore: cast_nullable_to_non_nullable
as PinState,assist: null == assist ? _self.assist : assist // ignore: cast_nullable_to_non_nullable
as int,pinAssist: null == pinAssist ? _self.pinAssist : pinAssist // ignore: cast_nullable_to_non_nullable
as PinState,startupLight: freezed == startupLight ? _self.startupLight : startupLight // ignore: cast_nullable_to_non_nullable
as bool?,startupModeId: freezed == startupModeId ? _self.startupModeId : startupModeId // ignore: cast_nullable_to_non_nullable
as String?,startupAssist: freezed == startupAssist ? _self.startupAssist : startupAssist // ignore: cast_nullable_to_non_nullable
as int?,lastSeen: freezed == lastSeen ? _self.lastSeen : lastSeen // ignore: cast_nullable_to_non_nullable
as LastSeen?,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,region: freezed == region ? _self.region : region // ignore: cast_nullable_to_non_nullable
as BikeRegion?,autoReconnect: null == autoReconnect ? _self.autoReconnect : autoReconnect // ignore: cast_nullable_to_non_nullable
as bool,color: null == color ? _self.color : color // ignore: cast_nullable_to_non_nullable
as int,
  ));
}
/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$LastSeenCopyWith<$Res>? get lastSeen {
    if (_self.lastSeen == null) {
    return null;
  }

  return $LastSeenCopyWith<$Res>(_self.lastSeen!, (value) {
    return _then(_self.copyWith(lastSeen: value));
  });
}
}


/// Adds pattern-matching-related methods to [BikeState].
extension BikeStatePatterns on BikeState {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BikeState value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BikeState() when $default != null:
return $default(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BikeState value)  $default,){
final _that = this;
switch (_that) {
case _BikeState():
return $default(_that);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BikeState value)?  $default,){
final _that = this;
switch (_that) {
case _BikeState() when $default != null:
return $default(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes, @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinMode,  bool light, @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinLight,  int assist, @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinAssist,  bool? startupLight,  String? startupModeId,  int? startupAssist,  LastSeen? lastSeen,  String name,  BikeRegion? region,  bool autoReconnect,  int color)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BikeState() when $default != null:
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.pinMode,_that.light,_that.pinLight,_that.assist,_that.pinAssist,_that.startupLight,_that.startupModeId,_that.startupAssist,_that.lastSeen,_that.name,_that.region,_that.autoReconnect,_that.color);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes, @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinMode,  bool light, @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinLight,  int assist, @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinAssist,  bool? startupLight,  String? startupModeId,  int? startupAssist,  LastSeen? lastSeen,  String name,  BikeRegion? region,  bool autoReconnect,  int color)  $default,) {final _that = this;
switch (_that) {
case _BikeState():
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.pinMode,_that.light,_that.pinLight,_that.assist,_that.pinAssist,_that.startupLight,_that.startupModeId,_that.startupAssist,_that.lastSeen,_that.name,_that.region,_that.autoReconnect,_that.color);case _:
  throw StateError('Unexpected subclass');

}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes, @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinMode,  bool light, @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinLight,  int assist, @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinAssist,  bool? startupLight,  String? startupModeId,  int? startupAssist,  LastSeen? lastSeen,  String name,  BikeRegion? region,  bool autoReconnect,  int color)?  $default,) {final _that = this;
switch (_that) {
case _BikeState() when $default != null:
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.pinMode,_that.light,_that.pinLight,_that.assist,_that.pinAssist,_that.startupLight,_that.startupModeId,_that.startupAssist,_that.lastSeen,_that.name,_that.region,_that.autoReconnect,_that.color);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BikeState extends BikeState {
  const _BikeState({required this.id, @JsonKey(name: 'mode') this.legacyMode = 0, this.modeId = '', final  List<CustomMode> customModes = const <CustomMode>[], @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) this.pinMode = PinState.open, required this.light, @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) this.pinLight = PinState.open, required this.assist, @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) this.pinAssist = PinState.open, this.startupLight, this.startupModeId, this.startupAssist, this.lastSeen, required this.name, this.region, this.autoReconnect = true, this.color = 0}): assert(assist >= 0),assert(assist <= 4),assert(color >= 0),_customModes = customModes,super._();
  factory _BikeState.fromJson(Map<String, dynamic> json) => _$BikeStateFromJson(json);

@override final  String id;
@override@JsonKey(name: 'mode') final  int legacyMode;
@override@JsonKey() final  String modeId;
 final  List<CustomMode> _customModes;
@override@JsonKey() List<CustomMode> get customModes {
  if (_customModes is EqualUnmodifiableListView) return _customModes;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_customModes);
}

@override@JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) final  PinState pinMode;
@override final  bool light;
@override@JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) final  PinState pinLight;
@override final  int assist;
@override@JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) final  PinState pinAssist;
@override final  bool? startupLight;
@override final  String? startupModeId;
@override final  int? startupAssist;
@override final  LastSeen? lastSeen;
@override final  String name;
@override final  BikeRegion? region;
@override@JsonKey() final  bool autoReconnect;
@override@JsonKey() final  int color;

/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BikeStateCopyWith<_BikeState> get copyWith => __$BikeStateCopyWithImpl<_BikeState>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$BikeStateToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BikeState&&(identical(other.id, id) || other.id == id)&&(identical(other.legacyMode, legacyMode) || other.legacyMode == legacyMode)&&(identical(other.modeId, modeId) || other.modeId == modeId)&&const DeepCollectionEquality().equals(other._customModes, _customModes)&&(identical(other.pinMode, pinMode) || other.pinMode == pinMode)&&(identical(other.light, light) || other.light == light)&&(identical(other.pinLight, pinLight) || other.pinLight == pinLight)&&(identical(other.assist, assist) || other.assist == assist)&&(identical(other.pinAssist, pinAssist) || other.pinAssist == pinAssist)&&(identical(other.startupLight, startupLight) || other.startupLight == startupLight)&&(identical(other.startupModeId, startupModeId) || other.startupModeId == startupModeId)&&(identical(other.startupAssist, startupAssist) || other.startupAssist == startupAssist)&&(identical(other.lastSeen, lastSeen) || other.lastSeen == lastSeen)&&(identical(other.name, name) || other.name == name)&&(identical(other.region, region) || other.region == region)&&(identical(other.autoReconnect, autoReconnect) || other.autoReconnect == autoReconnect)&&(identical(other.color, color) || other.color == color));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,legacyMode,modeId,const DeepCollectionEquality().hash(_customModes),pinMode,light,pinLight,assist,pinAssist,startupLight,startupModeId,startupAssist,lastSeen,name,region,autoReconnect,color);

@override
String toString() {
  return 'BikeState(id: $id, legacyMode: $legacyMode, modeId: $modeId, customModes: $customModes, pinMode: $pinMode, light: $light, pinLight: $pinLight, assist: $assist, pinAssist: $pinAssist, startupLight: $startupLight, startupModeId: $startupModeId, startupAssist: $startupAssist, lastSeen: $lastSeen, name: $name, region: $region, autoReconnect: $autoReconnect, color: $color)';
}


}

/// @nodoc
abstract mixin class _$BikeStateCopyWith<$Res> implements $BikeStateCopyWith<$Res> {
  factory _$BikeStateCopyWith(_BikeState value, $Res Function(_BikeState) _then) = __$BikeStateCopyWithImpl;
@override @useResult
$Res call({
 String id,@JsonKey(name: 'mode') int legacyMode, String modeId, List<CustomMode> customModes,@JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinMode, bool light,@JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinLight, int assist,@JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinAssist, bool? startupLight, String? startupModeId, int? startupAssist, LastSeen? lastSeen, String name, BikeRegion? region, bool autoReconnect, int color
});


@override $LastSeenCopyWith<$Res>? get lastSeen;

}
/// @nodoc
class __$BikeStateCopyWithImpl<$Res>
    implements _$BikeStateCopyWith<$Res> {
  __$BikeStateCopyWithImpl(this._self, this._then);

  final _BikeState _self;
  final $Res Function(_BikeState) _then;

/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? legacyMode = null,Object? modeId = null,Object? customModes = null,Object? pinMode = null,Object? light = null,Object? pinLight = null,Object? assist = null,Object? pinAssist = null,Object? startupLight = freezed,Object? startupModeId = freezed,Object? startupAssist = freezed,Object? lastSeen = freezed,Object? name = null,Object? region = freezed,Object? autoReconnect = null,Object? color = null,}) {
  return _then(_BikeState(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,legacyMode: null == legacyMode ? _self.legacyMode : legacyMode // ignore: cast_nullable_to_non_nullable
as int,modeId: null == modeId ? _self.modeId : modeId // ignore: cast_nullable_to_non_nullable
as String,customModes: null == customModes ? _self._customModes : customModes // ignore: cast_nullable_to_non_nullable
as List<CustomMode>,pinMode: null == pinMode ? _self.pinMode : pinMode // ignore: cast_nullable_to_non_nullable
as PinState,light: null == light ? _self.light : light // ignore: cast_nullable_to_non_nullable
as bool,pinLight: null == pinLight ? _self.pinLight : pinLight // ignore: cast_nullable_to_non_nullable
as PinState,assist: null == assist ? _self.assist : assist // ignore: cast_nullable_to_non_nullable
as int,pinAssist: null == pinAssist ? _self.pinAssist : pinAssist // ignore: cast_nullable_to_non_nullable
as PinState,startupLight: freezed == startupLight ? _self.startupLight : startupLight // ignore: cast_nullable_to_non_nullable
as bool?,startupModeId: freezed == startupModeId ? _self.startupModeId : startupModeId // ignore: cast_nullable_to_non_nullable
as String?,startupAssist: freezed == startupAssist ? _self.startupAssist : startupAssist // ignore: cast_nullable_to_non_nullable
as int?,lastSeen: freezed == lastSeen ? _self.lastSeen : lastSeen // ignore: cast_nullable_to_non_nullable
as LastSeen?,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,region: freezed == region ? _self.region : region // ignore: cast_nullable_to_non_nullable
as BikeRegion?,autoReconnect: null == autoReconnect ? _self.autoReconnect : autoReconnect // ignore: cast_nullable_to_non_nullable
as bool,color: null == color ? _self.color : color // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$LastSeenCopyWith<$Res>? get lastSeen {
    if (_self.lastSeen == null) {
    return null;
  }

  return $LastSeenCopyWith<$Res>(_self.lastSeen!, (value) {
    return _then(_self.copyWith(lastSeen: value));
  });
}
}

// dart format on

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
mixin _$BikeState {

 String get id;@JsonKey(name: 'mode') int get legacyMode; String get modeId; List<CustomMode> get customModes; bool get modeLocked; bool get light; bool get lightLocked; int get assist; bool get assistLocked; String get name; BikeRegion? get region; bool get modeLock; bool get modeLockAuto; bool get autoReconnect; int get color;
/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BikeStateCopyWith<BikeState> get copyWith => _$BikeStateCopyWithImpl<BikeState>(this as BikeState, _$identity);

  /// Serializes this BikeState to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BikeState&&(identical(other.id, id) || other.id == id)&&(identical(other.legacyMode, legacyMode) || other.legacyMode == legacyMode)&&(identical(other.modeId, modeId) || other.modeId == modeId)&&const DeepCollectionEquality().equals(other.customModes, customModes)&&(identical(other.modeLocked, modeLocked) || other.modeLocked == modeLocked)&&(identical(other.light, light) || other.light == light)&&(identical(other.lightLocked, lightLocked) || other.lightLocked == lightLocked)&&(identical(other.assist, assist) || other.assist == assist)&&(identical(other.assistLocked, assistLocked) || other.assistLocked == assistLocked)&&(identical(other.name, name) || other.name == name)&&(identical(other.region, region) || other.region == region)&&(identical(other.modeLock, modeLock) || other.modeLock == modeLock)&&(identical(other.modeLockAuto, modeLockAuto) || other.modeLockAuto == modeLockAuto)&&(identical(other.autoReconnect, autoReconnect) || other.autoReconnect == autoReconnect)&&(identical(other.color, color) || other.color == color));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,legacyMode,modeId,const DeepCollectionEquality().hash(customModes),modeLocked,light,lightLocked,assist,assistLocked,name,region,modeLock,modeLockAuto,autoReconnect,color);

@override
String toString() {
  return 'BikeState(id: $id, legacyMode: $legacyMode, modeId: $modeId, customModes: $customModes, modeLocked: $modeLocked, light: $light, lightLocked: $lightLocked, assist: $assist, assistLocked: $assistLocked, name: $name, region: $region, modeLock: $modeLock, modeLockAuto: $modeLockAuto, autoReconnect: $autoReconnect, color: $color)';
}


}

/// @nodoc
abstract mixin class $BikeStateCopyWith<$Res>  {
  factory $BikeStateCopyWith(BikeState value, $Res Function(BikeState) _then) = _$BikeStateCopyWithImpl;
@useResult
$Res call({
 String id,@JsonKey(name: 'mode') int legacyMode, String modeId, List<CustomMode> customModes, bool modeLocked, bool light, bool lightLocked, int assist, bool assistLocked, String name, BikeRegion? region, bool modeLock, bool modeLockAuto, bool autoReconnect, int color
});




}
/// @nodoc
class _$BikeStateCopyWithImpl<$Res>
    implements $BikeStateCopyWith<$Res> {
  _$BikeStateCopyWithImpl(this._self, this._then);

  final BikeState _self;
  final $Res Function(BikeState) _then;

/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? legacyMode = null,Object? modeId = null,Object? customModes = null,Object? modeLocked = null,Object? light = null,Object? lightLocked = null,Object? assist = null,Object? assistLocked = null,Object? name = null,Object? region = freezed,Object? modeLock = null,Object? modeLockAuto = null,Object? autoReconnect = null,Object? color = null,}) {
  return _then(_self.copyWith(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,legacyMode: null == legacyMode ? _self.legacyMode : legacyMode // ignore: cast_nullable_to_non_nullable
as int,modeId: null == modeId ? _self.modeId : modeId // ignore: cast_nullable_to_non_nullable
as String,customModes: null == customModes ? _self.customModes : customModes // ignore: cast_nullable_to_non_nullable
as List<CustomMode>,modeLocked: null == modeLocked ? _self.modeLocked : modeLocked // ignore: cast_nullable_to_non_nullable
as bool,light: null == light ? _self.light : light // ignore: cast_nullable_to_non_nullable
as bool,lightLocked: null == lightLocked ? _self.lightLocked : lightLocked // ignore: cast_nullable_to_non_nullable
as bool,assist: null == assist ? _self.assist : assist // ignore: cast_nullable_to_non_nullable
as int,assistLocked: null == assistLocked ? _self.assistLocked : assistLocked // ignore: cast_nullable_to_non_nullable
as bool,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,region: freezed == region ? _self.region : region // ignore: cast_nullable_to_non_nullable
as BikeRegion?,modeLock: null == modeLock ? _self.modeLock : modeLock // ignore: cast_nullable_to_non_nullable
as bool,modeLockAuto: null == modeLockAuto ? _self.modeLockAuto : modeLockAuto // ignore: cast_nullable_to_non_nullable
as bool,autoReconnect: null == autoReconnect ? _self.autoReconnect : autoReconnect // ignore: cast_nullable_to_non_nullable
as bool,color: null == color ? _self.color : color // ignore: cast_nullable_to_non_nullable
as int,
  ));
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes,  bool modeLocked,  bool light,  bool lightLocked,  int assist,  bool assistLocked,  String name,  BikeRegion? region,  bool modeLock,  bool modeLockAuto,  bool autoReconnect,  int color)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BikeState() when $default != null:
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.modeLocked,_that.light,_that.lightLocked,_that.assist,_that.assistLocked,_that.name,_that.region,_that.modeLock,_that.modeLockAuto,_that.autoReconnect,_that.color);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes,  bool modeLocked,  bool light,  bool lightLocked,  int assist,  bool assistLocked,  String name,  BikeRegion? region,  bool modeLock,  bool modeLockAuto,  bool autoReconnect,  int color)  $default,) {final _that = this;
switch (_that) {
case _BikeState():
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.modeLocked,_that.light,_that.lightLocked,_that.assist,_that.assistLocked,_that.name,_that.region,_that.modeLock,_that.modeLockAuto,_that.autoReconnect,_that.color);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes,  bool modeLocked,  bool light,  bool lightLocked,  int assist,  bool assistLocked,  String name,  BikeRegion? region,  bool modeLock,  bool modeLockAuto,  bool autoReconnect,  int color)?  $default,) {final _that = this;
switch (_that) {
case _BikeState() when $default != null:
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.modeLocked,_that.light,_that.lightLocked,_that.assist,_that.assistLocked,_that.name,_that.region,_that.modeLock,_that.modeLockAuto,_that.autoReconnect,_that.color);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BikeState extends BikeState {
  const _BikeState({required this.id, @JsonKey(name: 'mode') this.legacyMode = 0, this.modeId = '', final  List<CustomMode> customModes = const <CustomMode>[], this.modeLocked = false, required this.light, this.lightLocked = false, required this.assist, this.assistLocked = false, required this.name, this.region, this.modeLock = false, this.modeLockAuto = false, this.autoReconnect = true, this.color = 0}): assert(assist >= 0),assert(assist <= 4),assert(color >= 0),_customModes = customModes,super._();
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

@override@JsonKey() final  bool modeLocked;
@override final  bool light;
@override@JsonKey() final  bool lightLocked;
@override final  int assist;
@override@JsonKey() final  bool assistLocked;
@override final  String name;
@override final  BikeRegion? region;
@override@JsonKey() final  bool modeLock;
@override@JsonKey() final  bool modeLockAuto;
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BikeState&&(identical(other.id, id) || other.id == id)&&(identical(other.legacyMode, legacyMode) || other.legacyMode == legacyMode)&&(identical(other.modeId, modeId) || other.modeId == modeId)&&const DeepCollectionEquality().equals(other._customModes, _customModes)&&(identical(other.modeLocked, modeLocked) || other.modeLocked == modeLocked)&&(identical(other.light, light) || other.light == light)&&(identical(other.lightLocked, lightLocked) || other.lightLocked == lightLocked)&&(identical(other.assist, assist) || other.assist == assist)&&(identical(other.assistLocked, assistLocked) || other.assistLocked == assistLocked)&&(identical(other.name, name) || other.name == name)&&(identical(other.region, region) || other.region == region)&&(identical(other.modeLock, modeLock) || other.modeLock == modeLock)&&(identical(other.modeLockAuto, modeLockAuto) || other.modeLockAuto == modeLockAuto)&&(identical(other.autoReconnect, autoReconnect) || other.autoReconnect == autoReconnect)&&(identical(other.color, color) || other.color == color));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,id,legacyMode,modeId,const DeepCollectionEquality().hash(_customModes),modeLocked,light,lightLocked,assist,assistLocked,name,region,modeLock,modeLockAuto,autoReconnect,color);

@override
String toString() {
  return 'BikeState(id: $id, legacyMode: $legacyMode, modeId: $modeId, customModes: $customModes, modeLocked: $modeLocked, light: $light, lightLocked: $lightLocked, assist: $assist, assistLocked: $assistLocked, name: $name, region: $region, modeLock: $modeLock, modeLockAuto: $modeLockAuto, autoReconnect: $autoReconnect, color: $color)';
}


}

/// @nodoc
abstract mixin class _$BikeStateCopyWith<$Res> implements $BikeStateCopyWith<$Res> {
  factory _$BikeStateCopyWith(_BikeState value, $Res Function(_BikeState) _then) = __$BikeStateCopyWithImpl;
@override @useResult
$Res call({
 String id,@JsonKey(name: 'mode') int legacyMode, String modeId, List<CustomMode> customModes, bool modeLocked, bool light, bool lightLocked, int assist, bool assistLocked, String name, BikeRegion? region, bool modeLock, bool modeLockAuto, bool autoReconnect, int color
});




}
/// @nodoc
class __$BikeStateCopyWithImpl<$Res>
    implements _$BikeStateCopyWith<$Res> {
  __$BikeStateCopyWithImpl(this._self, this._then);

  final _BikeState _self;
  final $Res Function(_BikeState) _then;

/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? legacyMode = null,Object? modeId = null,Object? customModes = null,Object? modeLocked = null,Object? light = null,Object? lightLocked = null,Object? assist = null,Object? assistLocked = null,Object? name = null,Object? region = freezed,Object? modeLock = null,Object? modeLockAuto = null,Object? autoReconnect = null,Object? color = null,}) {
  return _then(_BikeState(
id: null == id ? _self.id : id // ignore: cast_nullable_to_non_nullable
as String,legacyMode: null == legacyMode ? _self.legacyMode : legacyMode // ignore: cast_nullable_to_non_nullable
as int,modeId: null == modeId ? _self.modeId : modeId // ignore: cast_nullable_to_non_nullable
as String,customModes: null == customModes ? _self._customModes : customModes // ignore: cast_nullable_to_non_nullable
as List<CustomMode>,modeLocked: null == modeLocked ? _self.modeLocked : modeLocked // ignore: cast_nullable_to_non_nullable
as bool,light: null == light ? _self.light : light // ignore: cast_nullable_to_non_nullable
as bool,lightLocked: null == lightLocked ? _self.lightLocked : lightLocked // ignore: cast_nullable_to_non_nullable
as bool,assist: null == assist ? _self.assist : assist // ignore: cast_nullable_to_non_nullable
as int,assistLocked: null == assistLocked ? _self.assistLocked : assistLocked // ignore: cast_nullable_to_non_nullable
as bool,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
as String,region: freezed == region ? _self.region : region // ignore: cast_nullable_to_non_nullable
as BikeRegion?,modeLock: null == modeLock ? _self.modeLock : modeLock // ignore: cast_nullable_to_non_nullable
as bool,modeLockAuto: null == modeLockAuto ? _self.modeLockAuto : modeLockAuto // ignore: cast_nullable_to_non_nullable
as bool,autoReconnect: null == autoReconnect ? _self.autoReconnect : autoReconnect // ignore: cast_nullable_to_non_nullable
as bool,color: null == color ? _self.color : color // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}

// dart format on

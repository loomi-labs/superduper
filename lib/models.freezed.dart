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
mixin _$BootSignature {

 DateTime get measuredAt; int? get bootWire; int? get bootAssist; bool? get bootLight; int get preOffWire; int get preOffAssist;
/// Create a copy of BootSignature
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BootSignatureCopyWith<BootSignature> get copyWith => _$BootSignatureCopyWithImpl<BootSignature>(this as BootSignature, _$identity);

  /// Serializes this BootSignature to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BootSignature&&(identical(other.measuredAt, measuredAt) || other.measuredAt == measuredAt)&&(identical(other.bootWire, bootWire) || other.bootWire == bootWire)&&(identical(other.bootAssist, bootAssist) || other.bootAssist == bootAssist)&&(identical(other.bootLight, bootLight) || other.bootLight == bootLight)&&(identical(other.preOffWire, preOffWire) || other.preOffWire == preOffWire)&&(identical(other.preOffAssist, preOffAssist) || other.preOffAssist == preOffAssist));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,measuredAt,bootWire,bootAssist,bootLight,preOffWire,preOffAssist);

@override
String toString() {
  return 'BootSignature(measuredAt: $measuredAt, bootWire: $bootWire, bootAssist: $bootAssist, bootLight: $bootLight, preOffWire: $preOffWire, preOffAssist: $preOffAssist)';
}


}

/// @nodoc
abstract mixin class $BootSignatureCopyWith<$Res>  {
  factory $BootSignatureCopyWith(BootSignature value, $Res Function(BootSignature) _then) = _$BootSignatureCopyWithImpl;
@useResult
$Res call({
 DateTime measuredAt, int? bootWire, int? bootAssist, bool? bootLight, int preOffWire, int preOffAssist
});




}
/// @nodoc
class _$BootSignatureCopyWithImpl<$Res>
    implements $BootSignatureCopyWith<$Res> {
  _$BootSignatureCopyWithImpl(this._self, this._then);

  final BootSignature _self;
  final $Res Function(BootSignature) _then;

/// Create a copy of BootSignature
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? measuredAt = null,Object? bootWire = freezed,Object? bootAssist = freezed,Object? bootLight = freezed,Object? preOffWire = null,Object? preOffAssist = null,}) {
  return _then(_self.copyWith(
measuredAt: null == measuredAt ? _self.measuredAt : measuredAt // ignore: cast_nullable_to_non_nullable
as DateTime,bootWire: freezed == bootWire ? _self.bootWire : bootWire // ignore: cast_nullable_to_non_nullable
as int?,bootAssist: freezed == bootAssist ? _self.bootAssist : bootAssist // ignore: cast_nullable_to_non_nullable
as int?,bootLight: freezed == bootLight ? _self.bootLight : bootLight // ignore: cast_nullable_to_non_nullable
as bool?,preOffWire: null == preOffWire ? _self.preOffWire : preOffWire // ignore: cast_nullable_to_non_nullable
as int,preOffAssist: null == preOffAssist ? _self.preOffAssist : preOffAssist // ignore: cast_nullable_to_non_nullable
as int,
  ));
}

}


/// Adds pattern-matching-related methods to [BootSignature].
extension BootSignaturePatterns on BootSignature {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BootSignature value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BootSignature() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BootSignature value)  $default,){
final _that = this;
switch (_that) {
case _BootSignature():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BootSignature value)?  $default,){
final _that = this;
switch (_that) {
case _BootSignature() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( DateTime measuredAt,  int? bootWire,  int? bootAssist,  bool? bootLight,  int preOffWire,  int preOffAssist)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BootSignature() when $default != null:
return $default(_that.measuredAt,_that.bootWire,_that.bootAssist,_that.bootLight,_that.preOffWire,_that.preOffAssist);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( DateTime measuredAt,  int? bootWire,  int? bootAssist,  bool? bootLight,  int preOffWire,  int preOffAssist)  $default,) {final _that = this;
switch (_that) {
case _BootSignature():
return $default(_that.measuredAt,_that.bootWire,_that.bootAssist,_that.bootLight,_that.preOffWire,_that.preOffAssist);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( DateTime measuredAt,  int? bootWire,  int? bootAssist,  bool? bootLight,  int preOffWire,  int preOffAssist)?  $default,) {final _that = this;
switch (_that) {
case _BootSignature() when $default != null:
return $default(_that.measuredAt,_that.bootWire,_that.bootAssist,_that.bootLight,_that.preOffWire,_that.preOffAssist);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BootSignature implements BootSignature {
  const _BootSignature({required this.measuredAt, this.bootWire, this.bootAssist, this.bootLight, required this.preOffWire, required this.preOffAssist});
  factory _BootSignature.fromJson(Map<String, dynamic> json) => _$BootSignatureFromJson(json);

@override final  DateTime measuredAt;
@override final  int? bootWire;
@override final  int? bootAssist;
@override final  bool? bootLight;
@override final  int preOffWire;
@override final  int preOffAssist;

/// Create a copy of BootSignature
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BootSignatureCopyWith<_BootSignature> get copyWith => __$BootSignatureCopyWithImpl<_BootSignature>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$BootSignatureToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BootSignature&&(identical(other.measuredAt, measuredAt) || other.measuredAt == measuredAt)&&(identical(other.bootWire, bootWire) || other.bootWire == bootWire)&&(identical(other.bootAssist, bootAssist) || other.bootAssist == bootAssist)&&(identical(other.bootLight, bootLight) || other.bootLight == bootLight)&&(identical(other.preOffWire, preOffWire) || other.preOffWire == preOffWire)&&(identical(other.preOffAssist, preOffAssist) || other.preOffAssist == preOffAssist));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,measuredAt,bootWire,bootAssist,bootLight,preOffWire,preOffAssist);

@override
String toString() {
  return 'BootSignature(measuredAt: $measuredAt, bootWire: $bootWire, bootAssist: $bootAssist, bootLight: $bootLight, preOffWire: $preOffWire, preOffAssist: $preOffAssist)';
}


}

/// @nodoc
abstract mixin class _$BootSignatureCopyWith<$Res> implements $BootSignatureCopyWith<$Res> {
  factory _$BootSignatureCopyWith(_BootSignature value, $Res Function(_BootSignature) _then) = __$BootSignatureCopyWithImpl;
@override @useResult
$Res call({
 DateTime measuredAt, int? bootWire, int? bootAssist, bool? bootLight, int preOffWire, int preOffAssist
});




}
/// @nodoc
class __$BootSignatureCopyWithImpl<$Res>
    implements _$BootSignatureCopyWith<$Res> {
  __$BootSignatureCopyWithImpl(this._self, this._then);

  final _BootSignature _self;
  final $Res Function(_BootSignature) _then;

/// Create a copy of BootSignature
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? measuredAt = null,Object? bootWire = freezed,Object? bootAssist = freezed,Object? bootLight = freezed,Object? preOffWire = null,Object? preOffAssist = null,}) {
  return _then(_BootSignature(
measuredAt: null == measuredAt ? _self.measuredAt : measuredAt // ignore: cast_nullable_to_non_nullable
as DateTime,bootWire: freezed == bootWire ? _self.bootWire : bootWire // ignore: cast_nullable_to_non_nullable
as int?,bootAssist: freezed == bootAssist ? _self.bootAssist : bootAssist // ignore: cast_nullable_to_non_nullable
as int?,bootLight: freezed == bootLight ? _self.bootLight : bootLight // ignore: cast_nullable_to_non_nullable
as bool?,preOffWire: null == preOffWire ? _self.preOffWire : preOffWire // ignore: cast_nullable_to_non_nullable
as int,preOffAssist: null == preOffAssist ? _self.preOffAssist : preOffAssist // ignore: cast_nullable_to_non_nullable
as int,
  ));
}


}


/// @nodoc
mixin _$BikeCapabilities {

 DateTime get measuredAt; List<int> get acceptedWires; List<int> get acceptedAssist; bool get lightWritable;
/// Create a copy of BikeCapabilities
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BikeCapabilitiesCopyWith<BikeCapabilities> get copyWith => _$BikeCapabilitiesCopyWithImpl<BikeCapabilities>(this as BikeCapabilities, _$identity);

  /// Serializes this BikeCapabilities to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BikeCapabilities&&(identical(other.measuredAt, measuredAt) || other.measuredAt == measuredAt)&&const DeepCollectionEquality().equals(other.acceptedWires, acceptedWires)&&const DeepCollectionEquality().equals(other.acceptedAssist, acceptedAssist)&&(identical(other.lightWritable, lightWritable) || other.lightWritable == lightWritable));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,measuredAt,const DeepCollectionEquality().hash(acceptedWires),const DeepCollectionEquality().hash(acceptedAssist),lightWritable);

@override
String toString() {
  return 'BikeCapabilities(measuredAt: $measuredAt, acceptedWires: $acceptedWires, acceptedAssist: $acceptedAssist, lightWritable: $lightWritable)';
}


}

/// @nodoc
abstract mixin class $BikeCapabilitiesCopyWith<$Res>  {
  factory $BikeCapabilitiesCopyWith(BikeCapabilities value, $Res Function(BikeCapabilities) _then) = _$BikeCapabilitiesCopyWithImpl;
@useResult
$Res call({
 DateTime measuredAt, List<int> acceptedWires, List<int> acceptedAssist, bool lightWritable
});




}
/// @nodoc
class _$BikeCapabilitiesCopyWithImpl<$Res>
    implements $BikeCapabilitiesCopyWith<$Res> {
  _$BikeCapabilitiesCopyWithImpl(this._self, this._then);

  final BikeCapabilities _self;
  final $Res Function(BikeCapabilities) _then;

/// Create a copy of BikeCapabilities
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? measuredAt = null,Object? acceptedWires = null,Object? acceptedAssist = null,Object? lightWritable = null,}) {
  return _then(_self.copyWith(
measuredAt: null == measuredAt ? _self.measuredAt : measuredAt // ignore: cast_nullable_to_non_nullable
as DateTime,acceptedWires: null == acceptedWires ? _self.acceptedWires : acceptedWires // ignore: cast_nullable_to_non_nullable
as List<int>,acceptedAssist: null == acceptedAssist ? _self.acceptedAssist : acceptedAssist // ignore: cast_nullable_to_non_nullable
as List<int>,lightWritable: null == lightWritable ? _self.lightWritable : lightWritable // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}

}


/// Adds pattern-matching-related methods to [BikeCapabilities].
extension BikeCapabilitiesPatterns on BikeCapabilities {
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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>(TResult Function( _BikeCapabilities value)?  $default,{required TResult orElse(),}){
final _that = this;
switch (_that) {
case _BikeCapabilities() when $default != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>(TResult Function( _BikeCapabilities value)  $default,){
final _that = this;
switch (_that) {
case _BikeCapabilities():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>(TResult? Function( _BikeCapabilities value)?  $default,){
final _that = this;
switch (_that) {
case _BikeCapabilities() when $default != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( DateTime measuredAt,  List<int> acceptedWires,  List<int> acceptedAssist,  bool lightWritable)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BikeCapabilities() when $default != null:
return $default(_that.measuredAt,_that.acceptedWires,_that.acceptedAssist,_that.lightWritable);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( DateTime measuredAt,  List<int> acceptedWires,  List<int> acceptedAssist,  bool lightWritable)  $default,) {final _that = this;
switch (_that) {
case _BikeCapabilities():
return $default(_that.measuredAt,_that.acceptedWires,_that.acceptedAssist,_that.lightWritable);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( DateTime measuredAt,  List<int> acceptedWires,  List<int> acceptedAssist,  bool lightWritable)?  $default,) {final _that = this;
switch (_that) {
case _BikeCapabilities() when $default != null:
return $default(_that.measuredAt,_that.acceptedWires,_that.acceptedAssist,_that.lightWritable);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BikeCapabilities extends BikeCapabilities {
  const _BikeCapabilities({required this.measuredAt, required final  List<int> acceptedWires, required final  List<int> acceptedAssist, required this.lightWritable}): _acceptedWires = acceptedWires,_acceptedAssist = acceptedAssist,super._();
  factory _BikeCapabilities.fromJson(Map<String, dynamic> json) => _$BikeCapabilitiesFromJson(json);

@override final  DateTime measuredAt;
 final  List<int> _acceptedWires;
@override List<int> get acceptedWires {
  if (_acceptedWires is EqualUnmodifiableListView) return _acceptedWires;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_acceptedWires);
}

 final  List<int> _acceptedAssist;
@override List<int> get acceptedAssist {
  if (_acceptedAssist is EqualUnmodifiableListView) return _acceptedAssist;
  // ignore: implicit_dynamic_type
  return EqualUnmodifiableListView(_acceptedAssist);
}

@override final  bool lightWritable;

/// Create a copy of BikeCapabilities
/// with the given fields replaced by the non-null parameter values.
@override @JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
_$BikeCapabilitiesCopyWith<_BikeCapabilities> get copyWith => __$BikeCapabilitiesCopyWithImpl<_BikeCapabilities>(this, _$identity);

@override
Map<String, dynamic> toJson() {
  return _$BikeCapabilitiesToJson(this, );
}

@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BikeCapabilities&&(identical(other.measuredAt, measuredAt) || other.measuredAt == measuredAt)&&const DeepCollectionEquality().equals(other._acceptedWires, _acceptedWires)&&const DeepCollectionEquality().equals(other._acceptedAssist, _acceptedAssist)&&(identical(other.lightWritable, lightWritable) || other.lightWritable == lightWritable));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hash(runtimeType,measuredAt,const DeepCollectionEquality().hash(_acceptedWires),const DeepCollectionEquality().hash(_acceptedAssist),lightWritable);

@override
String toString() {
  return 'BikeCapabilities(measuredAt: $measuredAt, acceptedWires: $acceptedWires, acceptedAssist: $acceptedAssist, lightWritable: $lightWritable)';
}


}

/// @nodoc
abstract mixin class _$BikeCapabilitiesCopyWith<$Res> implements $BikeCapabilitiesCopyWith<$Res> {
  factory _$BikeCapabilitiesCopyWith(_BikeCapabilities value, $Res Function(_BikeCapabilities) _then) = __$BikeCapabilitiesCopyWithImpl;
@override @useResult
$Res call({
 DateTime measuredAt, List<int> acceptedWires, List<int> acceptedAssist, bool lightWritable
});




}
/// @nodoc
class __$BikeCapabilitiesCopyWithImpl<$Res>
    implements _$BikeCapabilitiesCopyWith<$Res> {
  __$BikeCapabilitiesCopyWithImpl(this._self, this._then);

  final _BikeCapabilities _self;
  final $Res Function(_BikeCapabilities) _then;

/// Create a copy of BikeCapabilities
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? measuredAt = null,Object? acceptedWires = null,Object? acceptedAssist = null,Object? lightWritable = null,}) {
  return _then(_BikeCapabilities(
measuredAt: null == measuredAt ? _self.measuredAt : measuredAt // ignore: cast_nullable_to_non_nullable
as DateTime,acceptedWires: null == acceptedWires ? _self._acceptedWires : acceptedWires // ignore: cast_nullable_to_non_nullable
as List<int>,acceptedAssist: null == acceptedAssist ? _self._acceptedAssist : acceptedAssist // ignore: cast_nullable_to_non_nullable
as List<int>,lightWritable: null == lightWritable ? _self.lightWritable : lightWritable // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}


/// @nodoc
mixin _$BikeState {

 String get id;@JsonKey(name: 'mode') int get legacyMode; String get modeId; List<CustomMode> get customModes;@JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState get pinMode; bool get light;@JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState get pinLight; int get assist;@JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState get pinAssist; bool? get startupLight; String? get startupModeId; int? get startupAssist; LastSeen? get lastSeen; BootSignature? get bootSignature; BikeCapabilities? get capabilities; String get name; BikeRegion? get region; bool get autoReconnect; int get color;
/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$BikeStateCopyWith<BikeState> get copyWith => _$BikeStateCopyWithImpl<BikeState>(this as BikeState, _$identity);

  /// Serializes this BikeState to a JSON map.
  Map<String, dynamic> toJson();


@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is BikeState&&(identical(other.id, id) || other.id == id)&&(identical(other.legacyMode, legacyMode) || other.legacyMode == legacyMode)&&(identical(other.modeId, modeId) || other.modeId == modeId)&&const DeepCollectionEquality().equals(other.customModes, customModes)&&(identical(other.pinMode, pinMode) || other.pinMode == pinMode)&&(identical(other.light, light) || other.light == light)&&(identical(other.pinLight, pinLight) || other.pinLight == pinLight)&&(identical(other.assist, assist) || other.assist == assist)&&(identical(other.pinAssist, pinAssist) || other.pinAssist == pinAssist)&&(identical(other.startupLight, startupLight) || other.startupLight == startupLight)&&(identical(other.startupModeId, startupModeId) || other.startupModeId == startupModeId)&&(identical(other.startupAssist, startupAssist) || other.startupAssist == startupAssist)&&(identical(other.lastSeen, lastSeen) || other.lastSeen == lastSeen)&&(identical(other.bootSignature, bootSignature) || other.bootSignature == bootSignature)&&(identical(other.capabilities, capabilities) || other.capabilities == capabilities)&&(identical(other.name, name) || other.name == name)&&(identical(other.region, region) || other.region == region)&&(identical(other.autoReconnect, autoReconnect) || other.autoReconnect == autoReconnect)&&(identical(other.color, color) || other.color == color));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,legacyMode,modeId,const DeepCollectionEquality().hash(customModes),pinMode,light,pinLight,assist,pinAssist,startupLight,startupModeId,startupAssist,lastSeen,bootSignature,capabilities,name,region,autoReconnect,color]);

@override
String toString() {
  return 'BikeState(id: $id, legacyMode: $legacyMode, modeId: $modeId, customModes: $customModes, pinMode: $pinMode, light: $light, pinLight: $pinLight, assist: $assist, pinAssist: $pinAssist, startupLight: $startupLight, startupModeId: $startupModeId, startupAssist: $startupAssist, lastSeen: $lastSeen, bootSignature: $bootSignature, capabilities: $capabilities, name: $name, region: $region, autoReconnect: $autoReconnect, color: $color)';
}


}

/// @nodoc
abstract mixin class $BikeStateCopyWith<$Res>  {
  factory $BikeStateCopyWith(BikeState value, $Res Function(BikeState) _then) = _$BikeStateCopyWithImpl;
@useResult
$Res call({
 String id,@JsonKey(name: 'mode') int legacyMode, String modeId, List<CustomMode> customModes,@JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinMode, bool light,@JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinLight, int assist,@JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinAssist, bool? startupLight, String? startupModeId, int? startupAssist, LastSeen? lastSeen, BootSignature? bootSignature, BikeCapabilities? capabilities, String name, BikeRegion? region, bool autoReconnect, int color
});


$LastSeenCopyWith<$Res>? get lastSeen;$BootSignatureCopyWith<$Res>? get bootSignature;$BikeCapabilitiesCopyWith<$Res>? get capabilities;

}
/// @nodoc
class _$BikeStateCopyWithImpl<$Res>
    implements $BikeStateCopyWith<$Res> {
  _$BikeStateCopyWithImpl(this._self, this._then);

  final BikeState _self;
  final $Res Function(BikeState) _then;

/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') @override $Res call({Object? id = null,Object? legacyMode = null,Object? modeId = null,Object? customModes = null,Object? pinMode = null,Object? light = null,Object? pinLight = null,Object? assist = null,Object? pinAssist = null,Object? startupLight = freezed,Object? startupModeId = freezed,Object? startupAssist = freezed,Object? lastSeen = freezed,Object? bootSignature = freezed,Object? capabilities = freezed,Object? name = null,Object? region = freezed,Object? autoReconnect = null,Object? color = null,}) {
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
as LastSeen?,bootSignature: freezed == bootSignature ? _self.bootSignature : bootSignature // ignore: cast_nullable_to_non_nullable
as BootSignature?,capabilities: freezed == capabilities ? _self.capabilities : capabilities // ignore: cast_nullable_to_non_nullable
as BikeCapabilities?,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
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
}/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$BootSignatureCopyWith<$Res>? get bootSignature {
    if (_self.bootSignature == null) {
    return null;
  }

  return $BootSignatureCopyWith<$Res>(_self.bootSignature!, (value) {
    return _then(_self.copyWith(bootSignature: value));
  });
}/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$BikeCapabilitiesCopyWith<$Res>? get capabilities {
    if (_self.capabilities == null) {
    return null;
  }

  return $BikeCapabilitiesCopyWith<$Res>(_self.capabilities!, (value) {
    return _then(_self.copyWith(capabilities: value));
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>(TResult Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes, @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinMode,  bool light, @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinLight,  int assist, @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinAssist,  bool? startupLight,  String? startupModeId,  int? startupAssist,  LastSeen? lastSeen,  BootSignature? bootSignature,  BikeCapabilities? capabilities,  String name,  BikeRegion? region,  bool autoReconnect,  int color)?  $default,{required TResult orElse(),}) {final _that = this;
switch (_that) {
case _BikeState() when $default != null:
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.pinMode,_that.light,_that.pinLight,_that.assist,_that.pinAssist,_that.startupLight,_that.startupModeId,_that.startupAssist,_that.lastSeen,_that.bootSignature,_that.capabilities,_that.name,_that.region,_that.autoReconnect,_that.color);case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>(TResult Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes, @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinMode,  bool light, @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinLight,  int assist, @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinAssist,  bool? startupLight,  String? startupModeId,  int? startupAssist,  LastSeen? lastSeen,  BootSignature? bootSignature,  BikeCapabilities? capabilities,  String name,  BikeRegion? region,  bool autoReconnect,  int color)  $default,) {final _that = this;
switch (_that) {
case _BikeState():
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.pinMode,_that.light,_that.pinLight,_that.assist,_that.pinAssist,_that.startupLight,_that.startupModeId,_that.startupAssist,_that.lastSeen,_that.bootSignature,_that.capabilities,_that.name,_that.region,_that.autoReconnect,_that.color);case _:
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>(TResult? Function( String id, @JsonKey(name: 'mode')  int legacyMode,  String modeId,  List<CustomMode> customModes, @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinMode,  bool light, @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinLight,  int assist, @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson)  PinState pinAssist,  bool? startupLight,  String? startupModeId,  int? startupAssist,  LastSeen? lastSeen,  BootSignature? bootSignature,  BikeCapabilities? capabilities,  String name,  BikeRegion? region,  bool autoReconnect,  int color)?  $default,) {final _that = this;
switch (_that) {
case _BikeState() when $default != null:
return $default(_that.id,_that.legacyMode,_that.modeId,_that.customModes,_that.pinMode,_that.light,_that.pinLight,_that.assist,_that.pinAssist,_that.startupLight,_that.startupModeId,_that.startupAssist,_that.lastSeen,_that.bootSignature,_that.capabilities,_that.name,_that.region,_that.autoReconnect,_that.color);case _:
  return null;

}
}

}

/// @nodoc
@JsonSerializable()

class _BikeState extends BikeState {
  const _BikeState({required this.id, @JsonKey(name: 'mode') this.legacyMode = 0, this.modeId = '', final  List<CustomMode> customModes = const <CustomMode>[], @JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) this.pinMode = PinState.open, required this.light, @JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) this.pinLight = PinState.open, required this.assist, @JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) this.pinAssist = PinState.open, this.startupLight, this.startupModeId, this.startupAssist, this.lastSeen, this.bootSignature, this.capabilities, required this.name, this.region, this.autoReconnect = true, this.color = 0}): assert(assist >= 0),assert(assist <= 4),assert(color >= 0),_customModes = customModes,super._();
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
@override final  BootSignature? bootSignature;
@override final  BikeCapabilities? capabilities;
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
  return identical(this, other) || (other.runtimeType == runtimeType&&other is _BikeState&&(identical(other.id, id) || other.id == id)&&(identical(other.legacyMode, legacyMode) || other.legacyMode == legacyMode)&&(identical(other.modeId, modeId) || other.modeId == modeId)&&const DeepCollectionEquality().equals(other._customModes, _customModes)&&(identical(other.pinMode, pinMode) || other.pinMode == pinMode)&&(identical(other.light, light) || other.light == light)&&(identical(other.pinLight, pinLight) || other.pinLight == pinLight)&&(identical(other.assist, assist) || other.assist == assist)&&(identical(other.pinAssist, pinAssist) || other.pinAssist == pinAssist)&&(identical(other.startupLight, startupLight) || other.startupLight == startupLight)&&(identical(other.startupModeId, startupModeId) || other.startupModeId == startupModeId)&&(identical(other.startupAssist, startupAssist) || other.startupAssist == startupAssist)&&(identical(other.lastSeen, lastSeen) || other.lastSeen == lastSeen)&&(identical(other.bootSignature, bootSignature) || other.bootSignature == bootSignature)&&(identical(other.capabilities, capabilities) || other.capabilities == capabilities)&&(identical(other.name, name) || other.name == name)&&(identical(other.region, region) || other.region == region)&&(identical(other.autoReconnect, autoReconnect) || other.autoReconnect == autoReconnect)&&(identical(other.color, color) || other.color == color));
}

@JsonKey(includeFromJson: false, includeToJson: false)
@override
int get hashCode => Object.hashAll([runtimeType,id,legacyMode,modeId,const DeepCollectionEquality().hash(_customModes),pinMode,light,pinLight,assist,pinAssist,startupLight,startupModeId,startupAssist,lastSeen,bootSignature,capabilities,name,region,autoReconnect,color]);

@override
String toString() {
  return 'BikeState(id: $id, legacyMode: $legacyMode, modeId: $modeId, customModes: $customModes, pinMode: $pinMode, light: $light, pinLight: $pinLight, assist: $assist, pinAssist: $pinAssist, startupLight: $startupLight, startupModeId: $startupModeId, startupAssist: $startupAssist, lastSeen: $lastSeen, bootSignature: $bootSignature, capabilities: $capabilities, name: $name, region: $region, autoReconnect: $autoReconnect, color: $color)';
}


}

/// @nodoc
abstract mixin class _$BikeStateCopyWith<$Res> implements $BikeStateCopyWith<$Res> {
  factory _$BikeStateCopyWith(_BikeState value, $Res Function(_BikeState) _then) = __$BikeStateCopyWithImpl;
@override @useResult
$Res call({
 String id,@JsonKey(name: 'mode') int legacyMode, String modeId, List<CustomMode> customModes,@JsonKey(name: 'modeLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinMode, bool light,@JsonKey(name: 'lightLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinLight, int assist,@JsonKey(name: 'assistLocked', fromJson: _pinFromJson, toJson: _pinToJson) PinState pinAssist, bool? startupLight, String? startupModeId, int? startupAssist, LastSeen? lastSeen, BootSignature? bootSignature, BikeCapabilities? capabilities, String name, BikeRegion? region, bool autoReconnect, int color
});


@override $LastSeenCopyWith<$Res>? get lastSeen;@override $BootSignatureCopyWith<$Res>? get bootSignature;@override $BikeCapabilitiesCopyWith<$Res>? get capabilities;

}
/// @nodoc
class __$BikeStateCopyWithImpl<$Res>
    implements _$BikeStateCopyWith<$Res> {
  __$BikeStateCopyWithImpl(this._self, this._then);

  final _BikeState _self;
  final $Res Function(_BikeState) _then;

/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override @pragma('vm:prefer-inline') $Res call({Object? id = null,Object? legacyMode = null,Object? modeId = null,Object? customModes = null,Object? pinMode = null,Object? light = null,Object? pinLight = null,Object? assist = null,Object? pinAssist = null,Object? startupLight = freezed,Object? startupModeId = freezed,Object? startupAssist = freezed,Object? lastSeen = freezed,Object? bootSignature = freezed,Object? capabilities = freezed,Object? name = null,Object? region = freezed,Object? autoReconnect = null,Object? color = null,}) {
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
as LastSeen?,bootSignature: freezed == bootSignature ? _self.bootSignature : bootSignature // ignore: cast_nullable_to_non_nullable
as BootSignature?,capabilities: freezed == capabilities ? _self.capabilities : capabilities // ignore: cast_nullable_to_non_nullable
as BikeCapabilities?,name: null == name ? _self.name : name // ignore: cast_nullable_to_non_nullable
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
}/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$BootSignatureCopyWith<$Res>? get bootSignature {
    if (_self.bootSignature == null) {
    return null;
  }

  return $BootSignatureCopyWith<$Res>(_self.bootSignature!, (value) {
    return _then(_self.copyWith(bootSignature: value));
  });
}/// Create a copy of BikeState
/// with the given fields replaced by the non-null parameter values.
@override
@pragma('vm:prefer-inline')
$BikeCapabilitiesCopyWith<$Res>? get capabilities {
    if (_self.capabilities == null) {
    return null;
  }

  return $BikeCapabilitiesCopyWith<$Res>(_self.capabilities!, (value) {
    return _then(_self.copyWith(capabilities: value));
  });
}
}

// dart format on

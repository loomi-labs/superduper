// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_CustomMode _$CustomModeFromJson(Map<String, dynamic> json) => _CustomMode(
  id: json['id'] as String,
  name: json['name'] as String,
  limitKmh: (json['limitKmh'] as num).toInt(),
  throttle: json['throttle'] as bool? ?? false,
);

Map<String, dynamic> _$CustomModeToJson(_CustomMode instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'limitKmh': instance.limitKmh,
      'throttle': instance.throttle,
    };

_BikeState _$BikeStateFromJson(Map<String, dynamic> json) => _BikeState(
  id: json['id'] as String,
  legacyMode: (json['mode'] as num?)?.toInt() ?? 0,
  modeId: json['modeId'] as String? ?? '',
  customModes:
      (json['customModes'] as List<dynamic>?)
          ?.map((e) => CustomMode.fromJson(e as Map<String, dynamic>))
          .toList() ??
      const <CustomMode>[],
  modeLocked: json['modeLocked'] as bool? ?? false,
  light: json['light'] as bool,
  lightLocked: json['lightLocked'] as bool? ?? false,
  assist: (json['assist'] as num).toInt(),
  assistLocked: json['assistLocked'] as bool? ?? false,
  name: json['name'] as String,
  region: $enumDecodeNullable(_$BikeRegionEnumMap, json['region']),
  modeLock: json['modeLock'] as bool? ?? false,
  modeLockAuto: json['modeLockAuto'] as bool? ?? false,
  autoReconnect: json['autoReconnect'] as bool? ?? true,
  color: (json['color'] as num?)?.toInt() ?? 0,
);

Map<String, dynamic> _$BikeStateToJson(_BikeState instance) =>
    <String, dynamic>{
      'id': instance.id,
      'mode': instance.legacyMode,
      'modeId': instance.modeId,
      'customModes': instance.customModes.map((e) => e.toJson()).toList(),
      'modeLocked': instance.modeLocked,
      'light': instance.light,
      'lightLocked': instance.lightLocked,
      'assist': instance.assist,
      'assistLocked': instance.assistLocked,
      'name': instance.name,
      'region': _$BikeRegionEnumMap[instance.region],
      'modeLock': instance.modeLock,
      'modeLockAuto': instance.modeLockAuto,
      'autoReconnect': instance.autoReconnect,
      'color': instance.color,
    };

const _$BikeRegionEnumMap = {
  BikeRegion.ch: 202,
  BikeRegion.eu: 201,
  BikeRegion.us: 200,
};

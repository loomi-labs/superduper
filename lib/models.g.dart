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

_LastSeen _$LastSeenFromJson(Map<String, dynamic> json) => _LastSeen(
  assist: (json['assist'] as num).toInt(),
  light: json['light'] as bool,
  wire: (json['wire'] as num).toInt(),
);

Map<String, dynamic> _$LastSeenToJson(_LastSeen instance) => <String, dynamic>{
  'assist': instance.assist,
  'light': instance.light,
  'wire': instance.wire,
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
  pinMode: json['modeLocked'] == null
      ? PinState.open
      : _pinFromJson(json['modeLocked']),
  light: json['light'] as bool,
  pinLight: json['lightLocked'] == null
      ? PinState.open
      : _pinFromJson(json['lightLocked']),
  assist: (json['assist'] as num).toInt(),
  pinAssist: json['assistLocked'] == null
      ? PinState.open
      : _pinFromJson(json['assistLocked']),
  startupLight: json['startupLight'] as bool?,
  startupModeId: json['startupModeId'] as String?,
  startupAssist: (json['startupAssist'] as num?)?.toInt(),
  lastSeen: json['lastSeen'] == null
      ? null
      : LastSeen.fromJson(json['lastSeen'] as Map<String, dynamic>),
  name: json['name'] as String,
  region: $enumDecodeNullable(_$BikeRegionEnumMap, json['region']),
  autoReconnect: json['autoReconnect'] as bool? ?? true,
  color: (json['color'] as num?)?.toInt() ?? 0,
);

Map<String, dynamic> _$BikeStateToJson(_BikeState instance) =>
    <String, dynamic>{
      'id': instance.id,
      'mode': instance.legacyMode,
      'modeId': instance.modeId,
      'customModes': instance.customModes.map((e) => e.toJson()).toList(),
      'modeLocked': _pinToJson(instance.pinMode),
      'light': instance.light,
      'lightLocked': _pinToJson(instance.pinLight),
      'assist': instance.assist,
      'assistLocked': _pinToJson(instance.pinAssist),
      'startupLight': instance.startupLight,
      'startupModeId': instance.startupModeId,
      'startupAssist': instance.startupAssist,
      'lastSeen': instance.lastSeen?.toJson(),
      'name': instance.name,
      'region': _$BikeRegionEnumMap[instance.region],
      'autoReconnect': instance.autoReconnect,
      'color': instance.color,
    };

const _$BikeRegionEnumMap = {
  BikeRegion.ch: 202,
  BikeRegion.eu: 201,
  BikeRegion.us: 200,
};

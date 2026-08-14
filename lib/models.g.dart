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

_BootSignature _$BootSignatureFromJson(Map<String, dynamic> json) =>
    _BootSignature(
      measuredAt: DateTime.parse(json['measuredAt'] as String),
      bootWire: (json['bootWire'] as num?)?.toInt(),
      bootAssist: (json['bootAssist'] as num?)?.toInt(),
      bootLight: json['bootLight'] as bool?,
      preOffWire: (json['preOffWire'] as num).toInt(),
      preOffAssist: (json['preOffAssist'] as num).toInt(),
    );

Map<String, dynamic> _$BootSignatureToJson(_BootSignature instance) =>
    <String, dynamic>{
      'measuredAt': instance.measuredAt.toIso8601String(),
      'bootWire': instance.bootWire,
      'bootAssist': instance.bootAssist,
      'bootLight': instance.bootLight,
      'preOffWire': instance.preOffWire,
      'preOffAssist': instance.preOffAssist,
    };

_BikeCapabilities _$BikeCapabilitiesFromJson(Map<String, dynamic> json) =>
    _BikeCapabilities(
      measuredAt: DateTime.parse(json['measuredAt'] as String),
      acceptedWires: (json['acceptedWires'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      acceptedAssist: (json['acceptedAssist'] as List<dynamic>)
          .map((e) => (e as num).toInt())
          .toList(),
      lightWritable: json['lightWritable'] as bool,
    );

Map<String, dynamic> _$BikeCapabilitiesToJson(_BikeCapabilities instance) =>
    <String, dynamic>{
      'measuredAt': instance.measuredAt.toIso8601String(),
      'acceptedWires': instance.acceptedWires,
      'acceptedAssist': instance.acceptedAssist,
      'lightWritable': instance.lightWritable,
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
  bootSignature: json['bootSignature'] == null
      ? null
      : BootSignature.fromJson(json['bootSignature'] as Map<String, dynamic>),
  capabilities: json['capabilities'] == null
      ? null
      : BikeCapabilities.fromJson(json['capabilities'] as Map<String, dynamic>),
  name: json['name'] as String,
  region: $enumDecodeNullable(_$BikeRegionEnumMap, json['region']),
  autoReconnect: json['autoReconnect'] as bool? ?? false,
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
      'bootSignature': instance.bootSignature?.toJson(),
      'capabilities': instance.capabilities?.toJson(),
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

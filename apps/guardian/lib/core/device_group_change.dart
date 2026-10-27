import 'api.dart';

const _invalidInput = ApiFailure(400, 'VALIDATION_FAILED');
const _invalidResponse = ApiFailure(502, 'INVALID_DEVICE_GROUP_RESPONSE');
const _maximumInteger = 9007199254740991;
const _maximumEpoch = 8640000000000000;
const _snapshotKeys = [
  'id', 'name', 'state', 'version', 'deviceCount', 'createdAt', 'updatedAt',
];
final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _nameControls = RegExp(r'[\p{Cc}\p{Cf}]', unicode: true);

bool _uuid(Object? value) {
  if (value is! String) return false;
  final match = _uuidPattern.firstMatch(value);
  return match != null && match.end == value.length;
}
bool _integer(Object? value, {int maximum = _maximumInteger}) =>
    value is int && value >= 0 && value <= maximum;
bool _validName(Object? value) => value is String &&
    value.trim().isNotEmpty && value.length <= 100 && !_nameControls.hasMatch(value);
bool _same(Json left, Json right) =>
    _snapshotKeys.every((key) => left[key] == right[key]);
Json _frozen(Json value) => Map<String, dynamic>.unmodifiable(value);

/// Complete directory facts; membership never implies policy execution.
Json readDeviceGroupSnapshot(Object? raw, {String? expectedId}) {
  if (raw is! Json || !_snapshotKeys.every(raw.containsKey) ||
      !_uuid(raw['id']) || (expectedId != null && raw['id'] != expectedId) ||
      !_validName(raw['name']) ||
      !const {'ACTIVE', 'ARCHIVED'}.contains(raw['state']) ||
      !_integer(raw['version']) || !_integer(raw['deviceCount'], maximum: 5000) ||
      !_integer(raw['createdAt'], maximum: _maximumEpoch) ||
      !_integer(raw['updatedAt'], maximum: _maximumEpoch) ||
      (raw['updatedAt'] as int) < (raw['createdAt'] as int)) throw _invalidResponse;
  return _frozen({for (final key in _snapshotKeys) key: raw[key]});
}

Json _activeBefore(Json before) {
  final Json result;
  try {
    result = readDeviceGroupSnapshot(before);
  } on ApiFailure {
    throw _invalidInput;
  }
  if (result['state'] != 'ACTIVE' || result['version'] == _maximumInteger) {
    throw _invalidInput;
  }
  return result;
}

Json _name(Json values) {
  final name = values['name'];
  if (values.length != 1 || name is! String || !_validName(name.trim())) {
    throw _invalidInput;
  }
  return _frozen({'name': name.trim()});
}

class DeviceGroupChangeResult {
  final Json committed, current;
  const DeviceGroupChangeResult._(this.committed, this.current);
}

/// Captures one writer and its read-only original-result query independently.
class DeviceGroupChange {
  final String operation;
  final Json body, queryBody;
  final Json? _before;
  const DeviceGroupChange._(this.operation, this.body, this.queryBody, this._before);

  String? get groupId => _before?['id'] as String?;
  int? get version => _before?['version'] as int?;

  factory DeviceGroupChange.create(Json values) {
    final body = _name(values);
    return DeviceGroupChange._('CREATE', body,
        _frozen({'operation': 'CREATE', ...body}), null);
  }

  factory DeviceGroupChange.rename(Json before, Json values) {
    final original = _activeBefore(before), body = _name(values);
    return DeviceGroupChange._('RENAME', body, _frozen({
      'operation': 'RENAME', 'groupId': original['id'],
      'version': original['version'], ...body,
    }), original);
  }

  factory DeviceGroupChange.archive(Json before) {
    final original = _activeBefore(before);
    return DeviceGroupChange._('ARCHIVE', _frozen({}), _frozen({
      'operation': 'ARCHIVE', 'groupId': original['id'], 'version': original['version'],
    }), original);
  }

  factory DeviceGroupChange.members(Json before, List<Json> targets,
      {required bool removing}) {
    final original = _activeBefore(before), seen = <String>{};
    if (targets.isEmpty || targets.length > 50 ||
        (removing && targets.length > (original['deviceCount'] as int))) {
      throw _invalidInput;
    }
    final ordered = <Json>[];
    for (final target in targets) {
      if (target.length != 2 || !_uuid(target['deviceId']) ||
          !_uuid(target['registrationId']) || !seen.add(target['deviceId'] as String)) {
        throw _invalidInput;
      }
      ordered.add(_frozen({'deviceId': target['deviceId'],
        'registrationId': target['registrationId']}));
    }
    ordered.sort((left, right) =>
        (left['deviceId'] as String).compareTo(right['deviceId'] as String));
    final operation = removing ? 'REMOVE' : 'ADD';
    final body = _frozen({'devices': List<Json>.unmodifiable(ordered)});
    return DeviceGroupChange._(operation, body, _frozen({
      'operation': operation, 'groupId': original['id'],
      'version': original['version'], ...body,
    }), original);
  }

  Json committed(Object? raw) {
    final result = readDeviceGroupSnapshot(raw, expectedId: groupId);
    final before = _before;
    if (before == null) {
      if (result['name'] != body['name'] || result['state'] != 'ACTIVE' ||
          result['version'] != 0 || result['deviceCount'] != 0 ||
          result['createdAt'] != result['updatedAt']) throw _invalidResponse;
      return result;
    }
    if (result['createdAt'] != before['createdAt'] ||
        (result['updatedAt'] as int) < (before['updatedAt'] as int)) throw _invalidResponse;
    if ((operation == 'RENAME' && body['name'] == before['name']) ||
        (operation == 'ADD' && result['version'] == before['version'])) {
      if (!_same(result, before)) throw _invalidResponse;
      return result;
    }
    if (result['version'] != before['version'] + 1 ||
        result['state'] != (operation == 'ARCHIVE' ? 'ARCHIVED' : 'ACTIVE') ||
        result['name'] != (operation == 'RENAME' ? body['name'] : before['name'])) {
      throw _invalidResponse;
    }
    final count = result['deviceCount'] as int, previous = before['deviceCount'] as int;
    if (operation == 'ADD') {
      if (count <= previous || count - previous > (body['devices'] as List).length) {
        throw _invalidResponse;
      }
    } else if (count != previous -
        (operation == 'REMOVE' ? (body['devices'] as List).length : 0)) {
      throw _invalidResponse;
    }
    return result;
  }

  DeviceGroupChangeResult queryResult(Object? raw) {
    if (raw is! Json || raw.length != 3 ||
        !const ['operation', 'committed', 'current'].every(raw.containsKey) ||
        raw['operation'] != operation) throw _invalidResponse;
    final original = committed(raw['committed']);
    final current = readDeviceGroupSnapshot(raw['current'], expectedId: original['id'] as String);
    if (current['createdAt'] != original['createdAt'] ||
        (current['updatedAt'] as int) < (original['updatedAt'] as int) ||
        (current['version'] as int) < (original['version'] as int) ||
        (current['version'] == original['version'] && !_same(current, original)) ||
        (original['state'] == 'ARCHIVED' && !_same(current, original))) {
      throw _invalidResponse;
    }
    return DeviceGroupChangeResult._(original, current);
  }
}

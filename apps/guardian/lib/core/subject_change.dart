import 'api.dart';

const _maxVersion = 9007199254740991;
const _ageBands = {'UNDER_7', 'AGE_7_12', 'AGE_13_17'};
const _snapshotKeys = ['id', 'nickname', 'ageBand', 'version', 'state'];
final _subjectId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

String? validateSubjectNickname(String? value) {
  final nickname = value?.trim() ?? '';
  if (nickname.isEmpty) return '请输入儿童昵称。';
  if (nickname.length > 60) return '昵称最多 60 个字符，部分表情会占多个字符，请缩短后再试。';
  return null;
}

/// Server facts retain their exact primitive values; extra fields are excluded.
Json readSubjectSnapshot(Object? raw, {String? expectedId}) {
  if (raw is! Map || raw['id'] is! String ||
      _subjectId.firstMatch(raw['id'] as String)?.end != (raw['id'] as String).length ||
      expectedId != null && raw['id'] != expectedId ||
      raw['nickname'] is! String || (raw['nickname'] as String).trim().isEmpty ||
      (raw['nickname'] as String).length > 60 || !_ageBands.contains(raw['ageBand']) ||
      raw['version'] is! int || (raw['version'] as int) < 0 ||
      (raw['version'] as int) > _maxVersion ||
      !const {'ACTIVE', 'ARCHIVED'}.contains(raw['state'])) {
    throw const ApiFailure(502, 'INVALID_RESPONSE');
  }
  return Map<String, dynamic>.unmodifiable({
    for (final key in _snapshotKeys) key: raw[key],
  });
}

Json _activeSnapshot(Json before) {
  final snapshot = readSubjectSnapshot(before);
  if (snapshot['state'] != 'ACTIVE' || (snapshot['version'] as int) >= _maxVersion) {
    throw const ApiFailure(502, 'INVALID_RESPONSE');
  }
  return snapshot;
}

Json _fields(Json values) {
  final nickname = values['nickname'];
  if (nickname is! String || validateSubjectNickname(nickname) != null ||
      !_ageBands.contains(values['ageBand'])) {
    throw const ApiFailure(400, 'VALIDATION_FAILED');
  }
  return {'nickname': nickname.trim(), 'ageBand': values['ageBand']};
}

class SubjectChangeResult {
  final Json committed, current;
  const SubjectChangeResult._(this.committed, this.current);
}

/// One immutable mutation and its exact original receipt, independent of UI/API.
class SubjectChangeDraft {
  final String operation;
  final Json body;
  final Json? before;
  SubjectChangeDraft._(this.operation, Json body, this.before)
      : body = Map<String, dynamic>.unmodifiable(body);

  factory SubjectChangeDraft.create(Json values) =>
      SubjectChangeDraft._('CREATE', {'operation': 'CREATE', ..._fields(values)}, null);

  factory SubjectChangeDraft.update(Json before, Json values) {
    final snapshot = _activeSnapshot(before);
    return SubjectChangeDraft._('UPDATE', {
      'operation': 'UPDATE', 'subjectId': snapshot['id'],
      'version': snapshot['version'], ..._fields(values),
    }, snapshot);
  }

  factory SubjectChangeDraft.archive(Json before) {
    final snapshot = _activeSnapshot(before);
    return SubjectChangeDraft._('ARCHIVE', {
      'operation': 'ARCHIVE', 'subjectId': snapshot['id'], 'version': snapshot['version'],
    }, snapshot);
  }

  Json committed(Object? raw) {
    final snapshot = readSubjectSnapshot(raw, expectedId: before?['id'] as String?);
    final archived = operation == 'ARCHIVE';
    final expectedVersion = before == null ? 0 : (before!['version'] as int) + 1;
    if (snapshot['state'] != (archived ? 'ARCHIVED' : 'ACTIVE') ||
        snapshot['version'] != expectedVersion ||
        snapshot['nickname'] != (archived ? before!['nickname'] : body['nickname']) ||
        snapshot['ageBand'] != (archived ? before!['ageBand'] : body['ageBand'])) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    return snapshot;
  }

  SubjectChangeResult queryResult(Object? raw) {
    if (raw is! Map || raw['operation'] != operation) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    final original = committed(raw['committed']);
    final latest = readSubjectSnapshot(raw['current'], expectedId: original['id'] as String);
    if ((latest['version'] as int) < (original['version'] as int) ||
        operation == 'ARCHIVE' && latest['state'] != 'ARCHIVED' ||
        latest['version'] == original['version'] &&
            _snapshotKeys.any((key) => latest[key] != original[key])) {
      throw const ApiFailure(502, 'INVALID_RESPONSE');
    }
    return SubjectChangeResult._(original, latest);
  }
}

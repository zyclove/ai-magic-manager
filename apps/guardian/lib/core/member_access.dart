import 'api.dart';
import 'labels.dart';

final _memberKeyPattern = RegExp(r'[0-9a-f]{64}');
// Match Java String.isBlank without trimming or normalizing the OIDC subject.
final _memberBlankPattern = RegExp(
    r'[\u0009-\u000d\u001c-\u0020\u1680\u2000-\u2006\u2008-\u200a\u2028\u2029\u205f\u3000]*');
final _memberUuidPattern = RegExp(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}');
const _memberAccessFields = {
  'actorId', 'memberKey', 'role', 'subjectId', 'version', 'classIds'
};
const _memberUpdateFields = {'role', 'subjectId', 'classIds'};

Never _invalidMemberAccess() =>
    throw const ApiFailure(502, 'INVALID_MEMBER_ACCESS_RESPONSE');

bool _memberMatches(RegExp pattern, Object? value) {
  if (value is! String) return false;
  final match = pattern.matchAsPrefix(value);
  return match != null && match.end == value.length;
}

/// Captures the selected list row before any asynchronous access request.
class MemberAccessTarget {
  final String actorId;
  final String memberKey;

  const MemberAccessTarget._(this.actorId, this.memberKey);

  factory MemberAccessTarget.fromRow(Json row) {
    final actorId = row['actorId'];
    final memberKey = row['cursor'];
    if (actorId is! String || _memberMatches(_memberBlankPattern, actorId) ||
        actorId.length > 255 ||
        !_memberMatches(_memberKeyPattern, memberKey)) {
      _invalidMemberAccess();
    }
    return MemberAccessTarget._(actorId, memberKey as String);
  }
}

class _MemberAccessScope {
  final String role;
  final String? subjectId;
  final List<String> classIds;

  const _MemberAccessScope._(this.role, this.subjectId, this.classIds);

  factory _MemberAccessScope.read({required String kind, required Object? role,
      required Object? subjectId, required Object? classIds}) {
    final roles = switch (kind) {
      'FAMILY' => const {'OWNER', 'GUARDIAN', 'AUDITOR', 'CHILD'},
      'ORGANIZATION' => const {'OWNER', 'ORG_ADMIN', 'TEACHER', 'AUDITOR', 'CHILD'},
      _ => _invalidMemberAccess(),
    };
    if (role is! String || !roles.contains(role) ||
        (subjectId != null && !_memberMatches(_memberUuidPattern, subjectId)) ||
        classIds is! List || classIds.length > 50) {
      _invalidMemberAccess();
    }
    final ids = <String>[];
    for (final id in classIds) {
      if (id is! String || !_memberMatches(_memberUuidPattern, id)) {
        _invalidMemberAccess();
      }
      ids.add(id);
    }
    if (ids.toSet().length != ids.length) _invalidMemberAccess();
    if (ids.isNotEmpty) {
      if (role != 'TEACHER' || subjectId != null) _invalidMemberAccess();
    } else if (memberNeedsSubject(role) ? subjectId == null : subjectId != null) {
      _invalidMemberAccess();
    }
    ids.sort();
    return _MemberAccessScope._(role, subjectId as String?,
        List<String>.unmodifiable(ids));
  }

  bool sameAs(_MemberAccessScope other) {
    if (role != other.role || subjectId != other.subjectId ||
        classIds.length != other.classIds.length) return false;
    for (var index = 0; index < classIds.length; index++) {
      if (classIds[index] != other.classIds[index]) return false;
    }
    return true;
  }
}

/// Validated current-contract access facts, independent of directory activity.
class MemberAccessSnapshot {
  final String _kind;
  final MemberAccessTarget _target;
  final _MemberAccessScope _scope;
  final int version;

  const MemberAccessSnapshot._(this._kind, this._target, this._scope, this.version);

  String get actorId => _target.actorId;
  String get memberKey => _target.memberKey;
  String get role => _scope.role;
  String? get subjectId => _scope.subjectId;
  List<String> get classIds => _scope.classIds;

  factory MemberAccessSnapshot.read(Object? raw, {required String kind,
      required MemberAccessTarget target, MemberAccessSnapshot? previous}) {
    if (raw is! Map || raw.length != _memberAccessFields.length ||
        !_memberAccessFields.every(raw.containsKey) ||
        raw['actorId'] != target.actorId || raw['memberKey'] != target.memberKey) {
      _invalidMemberAccess();
    }
    final version = raw['version'];
    if (version is! int || version < 0 || version > 9007199254740991) {
      _invalidMemberAccess();
    }
    final scope = _MemberAccessScope.read(kind: kind, role: raw['role'],
        subjectId: raw['subjectId'], classIds: raw['classIds']);
    if (previous != null && (previous._kind != kind ||
        previous.actorId != target.actorId || previous.memberKey != target.memberKey ||
        version < previous.version ||
        (version == previous.version && !scope.sameAs(previous._scope)))) {
      _invalidMemberAccess();
    }
    return MemberAccessSnapshot._(kind, target, scope, version);
  }

  Json toJson() => Map<String, dynamic>.unmodifiable({
    'actorId': actorId, 'memberKey': memberKey, 'role': role,
    'subjectId': subjectId, 'version': version, 'classIds': classIds,
  });

  MemberAccessSnapshot verifyUpdate(Object? raw, {required Json body}) {
    if (!body.containsKey('role') ||
        !body.keys.every(_memberUpdateFields.contains)) {
      _invalidMemberAccess();
    }
    final requested = _MemberAccessScope.read(kind: _kind, role: body['role'],
        subjectId: body['subjectId'],
        classIds: body.containsKey('classIds') ? body['classIds'] : const <String>[]);
    if (role == 'OWNER' || requested.role == 'OWNER' ||
        (role == 'CHILD') != (requested.role == 'CHILD')) {
      _invalidMemberAccess();
    }
    final result = MemberAccessSnapshot.read(raw, kind: _kind, target: _target);
    final expectedVersion = requested.sameAs(_scope) ? version : version + 1;
    if (!result._scope.sameAs(requested) || result.version != expectedVersion) {
      _invalidMemberAccess();
    }
    return result;
  }
}

List<String> memberRoles(String kind, String operatorRole,
    {String? currentRole}) {
  if (!['OWNER', 'ORG_ADMIN'].contains(operatorRole) ||
      currentRole == 'OWNER' ||
      (currentRole == 'ORG_ADMIN' && operatorRole != 'OWNER')) return const [];
  final available = kind == 'FAMILY'
      ? <String>['GUARDIAN', 'AUDITOR', 'CHILD']
      : <String>[
          if (operatorRole == 'OWNER') 'ORG_ADMIN',
          'TEACHER',
          'AUDITOR',
          'CHILD'
        ];
  if (currentRole == null) return available;
  return available
      .where((r) => (r == 'CHILD') == (currentRole == 'CHILD'))
      .toList();
}

bool memberNeedsSubject(String role) => role == 'CHILD' || role == 'TEACHER';
String memberName(Json row) {
  final name = row['displayName'] as String?;
  if (name != null && name.trim().isNotEmpty) return name;
  return shortId(row['actorId']);
}

String memberScope(Json row) {
  final classes = row['classIds'] as List? ?? const [];
  if (classes.isNotEmpty) return '${classes.length} 个班级';
  if (row['subjectId'] != null) {
    return '${row['subjectName'] ?? shortId(row['subjectId'])}${row['subjectArchived'] == true ? '（已归档）' : ''}';
  }
  return row['role'] == 'TEACHER' ? '尚未分配范围' : '工作空间范围';
}

/// Human-readable history; incomplete scope facts never imply an empty scope.
String memberAccessHistorySummary(Json row) {
  const roles = {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'TEACHER', 'AUDITOR', 'CHILD'};
  final previousRole = row['previousRole'], role = row['role'];
  if (!roles.contains(previousRole) || !row.containsKey('role') ||
      (role != null && !roles.contains(role))) return '权限变更资料待核对';
  if (role == null) return '${label(previousRole)} → 已撤销';
  final roleText = previousRole == role
      ? label(role) : '${label(previousRole)} → ${label(role)}';
  final previousSubject = row['previousSubjectId'], subject = row['subjectId'];
  final previousClasses = _historyClassIds(row['previousClassIds']);
  final classes = _historyClassIds(row['classIds']);
  if (!row.containsKey('previousSubjectId') || !row.containsKey('subjectId') ||
      (previousSubject != null && (previousSubject is! String || previousSubject.trim().isEmpty)) ||
      (subject != null && (subject is! String || subject.trim().isEmpty)) ||
      previousClasses == null || classes == null) {
    return '$roleText · 范围资料待核对';
  }
  final added = classes.difference(previousClasses).length;
  final removed = previousClasses.difference(classes).length;
  final changes = <String>[
    if (previousSubject != subject)
      subject == null ? '关联档案已移除' : previousSubject == null
          ? '关联档案已设置' : '关联档案已更换',
    if (added > 0 || removed > 0)
      '班级${[if (added > 0) '新增 $added 个', if (removed > 0) '移除 $removed 个'].join('、')}',
  ];
  if (changes.isEmpty) return previousRole == role
      ? '$roleText · 范围未变化' : roleText;
  return '$roleText · ${changes.join(' · ')}';
}

Set<String>? _historyClassIds(Object? value) {
  if (value is! List || value.length > 50 ||
      value.any((id) => id is! String || id.trim().isEmpty)) return null;
  final ids = Set<String>.from(value);
  return ids.length == value.length ? ids : null;
}

/// Search only known receipt fields and their visible Chinese summary.
String memberAccessHistorySearchText(Json row) => [
  memberAccessHistorySummary(row),
  for (final field in const ['id', 'previousRole', 'role', 'previousSubjectId',
    'subjectId', 'changedByActorId', 'memberVersion', 'occurredAt'])
    if (row[field] is String || row[field] is int) '${row[field]}',
  if (row['memberVersion'] is int) 'v${row['memberVersion']}',
  for (final field in const ['previousClassIds', 'classIds'])
    if (row[field] is List)
      for (final id in (row[field] as List).take(50))
        if (id is String) id,
].join('\n');

const memberConsequences =
    '保存后立即按新权限访问。该成员发出的未使用邀请、待确认设备配对、临时访问窗口及相关预览将失效。已生效设备和已发布策略保留。';
String memberRoleDescription(String role) => switch (role) {
      'GUARDIAN' => '管理家庭档案、设备和规则；成员管理由所有者负责。',
      'ORG_ADMIN' => '管理机构档案、设备、规则及普通成员；不能交接所有权。',
      'TEACHER' => '查看获授班级内或指定档案的学生和设备状态，可提交与取消本人的有限访问申请。不能审批、修改学生、设备或组织策略。',
      'AUDITOR' => '查看工作空间内允许审计的信息，无权修改配置或成员。',
      'CHILD' => '仅访问所关联的儿童档案范围；不授予成人管理资格。',
      _ => '请核对角色和访问范围。',
    };

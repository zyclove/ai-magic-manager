import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

const memberRoleLabels = {
  'OWNER': '所有者',
  'GUARDIAN': '监护人',
  'ORG_ADMIN': '机构管理员',
  'TEACHER': '教师',
  'AUDITOR': '审计员',
  'CHILD': '儿童/学生'
};
const memberConsequences =
    '保存后按新权限访问。该成员发出的未使用邀请、待确认设备配对、临时访问窗口及相关预览将失效。已生效设备和已发布策略保留。';
String memberRoleDescription(String role) => switch (role) {
      'GUARDIAN' => '管理家庭档案、设备和规则；成员管理由所有者负责。',
      'ORG_ADMIN' => '管理机构档案、设备、规则及普通成员；不能交接所有权。',
      'TEACHER' => '仅查看获授范围内学生和设备状态，提交与取消本人的有限申请；不能审批或修改组织规则。',
      'AUDITOR' => '查看允许审计的信息，无权修改配置或成员。',
      'CHILD' => '只访问关联的儿童档案，不获得成人管理资格。',
      _ => '所有权需要通过专门交接流程变更。',
    };
List<String> memberRoles(String kind, String operatorRole, String currentRole) {
  if (!const {'OWNER', 'ORG_ADMIN'}.contains(operatorRole) ||
      currentRole == 'OWNER' ||
      (currentRole == 'ORG_ADMIN' && operatorRole != 'OWNER')) return const [];
  return (kind == 'FAMILY'
          ? ['GUARDIAN', 'AUDITOR', 'CHILD']
          : [
              if (operatorRole == 'OWNER') 'ORG_ADMIN',
              'TEACHER',
              'AUDITOR',
              'CHILD'
            ])
      .where((r) => (r == 'CHILD') == (currentRole == 'CHILD'))
      .toList();
}

final _uuidPattern =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
bool _uuid(dynamic v) => v is String && _uuidPattern.hasMatch(v);
bool _key(dynamic v) => v is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(v);
bool _text(dynamic v, int max) =>
    v is String && v.trim().isNotEmpty && v.length <= max;
bool _version(dynamic v) => v is int && v >= 0 && v <= 9007199254740991;
bool _classes(dynamic v) =>
    v is List &&
    v.length <= 50 &&
    v.every(_uuid) &&
    v.toSet().length == v.length;
const _invalid = ParentApiException(502, 'INVALID_RESPONSE');
bool validMemberScope(String role, dynamic subject, dynamic classes,
    {bool allowUnassignedTeacher = false}) {
  if (!_classes(classes)) return false;
  if (role == 'CHILD') return _uuid(subject) && (classes as List).isEmpty;
  if (role == 'TEACHER') {
    return subject == null
        ? (classes as List).isNotEmpty || allowUnassignedTeacher
        : _uuid(subject) && (classes as List).isEmpty;
  }
  return memberRoleLabels.containsKey(role) &&
      subject == null &&
      (classes as List).isEmpty;
}

Json readMemberAccess(dynamic raw) {
  if (raw is! Json ||
      !_text(raw['actorId'], 255) ||
      !_key(raw['memberKey']) ||
      raw['role'] is! String ||
      !_version(raw['version']) ||
      !validMemberScope(raw['role'], raw['subjectId'], raw['classIds'],
          allowUnassignedTeacher: true)) throw _invalid;
  return Map<String, dynamic>.unmodifiable(raw);
}

void validateMemberRow(Json raw) {
  readMemberAccess({...raw, 'memberKey': raw['cursor']});
  if ((raw['displayName'] != null && !_text(raw['displayName'], 255)) ||
      (raw['verifiedEmail'] != null && !_text(raw['verifiedEmail'], 254)) ||
      (raw['subjectName'] != null && !_text(raw['subjectName'], 100)) ||
      raw['subjectArchived'] is! bool) throw _invalid;
}

void validateMemberHistory(Json row) {
  if (!_uuid(row['id']) ||
      !_version(row['memberVersion']) ||
      !_version(row['occurredAt']) ||
      row['occurredAt'] > 253402300799999 ||
      !_text(row['changedByActorId'], 255) ||
      row['previousRole'] is! String ||
      !validMemberScope(row['previousRole'], row['previousSubjectId'],
          row['previousClassIds'], allowUnassignedTeacher: true) ||
      (row['changeType'] == 'REVOKED'
          ? row['role'] != null ||
              row['subjectId'] != null ||
              !_classes(row['classIds']) ||
              row['classIds'].isNotEmpty
          : row['changeType'] != 'UPDATED' ||
              row['role'] is! String ||
              !validMemberScope(row['role'], row['subjectId'], row['classIds'],
                  allowUnassignedTeacher: true))) throw _invalid;
}

String memberName(Json row) =>
    row['displayName'] ??
    row['verifiedEmail'] ??
    '账号 ${(row['actorId'] as String).substring(0, (row['actorId'] as String).length.clamp(0, 8))}';
String memberScope(Json row) => (row['classIds'] as List).isNotEmpty
    ? '${row['classIds'].length} 个班级'
    : row['subjectId'] != null
        ? '${row['subjectName'] ?? '单个学生档案'}${row['subjectArchived'] == true ? '（已归档）' : ''}'
        : row['role'] == 'TEACHER'
            ? '尚未分配范围'
            : '工作空间范围';
void validateMemberOperation(Json input, Json before) {
  readMemberAccess(before);
  final revoke = input['operation'] == 'REVOKE';
  if ((!revoke && input['operation'] != 'UPDATE') ||
      !_version(input['version']) ||
      input['version'] != before['version'] ||
      before['role'] == 'OWNER') throw _invalid;
  final fields = {
    'operation',
    'version',
    if (!revoke) ...['role', 'subjectId', 'classIds']
  };
  if (input.keys.toSet().difference(fields).isNotEmpty ||
      fields.difference(input.keys.toSet()).isNotEmpty) throw _invalid;
  if (!revoke &&
      (input['role'] is! String ||
          input['role'] == 'OWNER' ||
          !validMemberScope(
              input['role'], input['subjectId'], input['classIds']) ||
          (before['role'] == 'CHILD') != (input['role'] == 'CHILD'))) {
    throw const FormatException('请核对角色和范围；儿童与成人身份不能通过编辑直接互换。');
  }
}

class MemberOperationStore {
  final ParentDurableStorage storage;
  MemberOperationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _keyFor(String tenant, String actor) =>
      'parent.pending.member.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final value = await storage.read(key: _keyFor(tenant, actor));
    if (value == null) return null;
    if (value.length > 16384) throw const FormatException('成员恢复记录过大。');
    final row = jsonDecode(value);
    if (row is! Json ||
        !_uuid(row['requestId']) ||
        row['input'] is! Json ||
        row['before'] is! Json) throw const FormatException('成员恢复记录损坏，请联系管理员。');
    validateMemberOperation(row['input'], row['before']);
    return row;
  }

  Future<void> save(String tenant, String actor, Json row) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对上次成员操作。');
    final encoded = jsonEncode(row);
    if (encoded.length > 16384) throw const FormatException('成员恢复记录过大。');
    await storage.write(key: _keyFor(tenant, actor), value: encoded);
  }

  Future<void> clear(String tenant, String actor, String requestId) async {
    final row = await load(tenant, actor);
    if (row == null) return;
    if (row['requestId'] != requestId) throw StateError('恢复记录已变化。');
    await storage.delete(key: _keyFor(tenant, actor));
  }
}

class MemberOperationController extends ChangeNotifier {
  final ParentApi api;
  final String tenant, actor;
  final MemberOperationStore store;
  final bool Function() isCurrent;
  bool busy = false,
      loaded = false,
      queried = false,
      saved = false,
      _disposed = false;
  Json? pending, committed, latest;
  String? currentState;
  Object? error;
  MemberOperationController(
      {required this.api,
      required this.tenant,
      required this.actor,
      required this.store,
      required this.isCurrent});
  bool get current => !_disposed && isCurrent();
  bool get canSubmit => current && loaded && !busy && pending == null;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    if (!current || busy) return;
    busy = true;
    loaded = false;
    error = null;
    _changed();
    try {
      final row = await store.load(tenant, actor);
      if (current) {
        pending = row;
        committed = null;
        latest = null;
        currentState = null;
        queried = false;
        saved = false;
        loaded = true;
      }
    } catch (failure) {
      if (current) error = failure;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> submit(Json input, Json before) async {
    if (!canSubmit) return;
    busy = true;
    error = null;
    _changed();
    try {
      validateMemberOperation(input, before);
      final row = jsonDecode(jsonEncode({
        'requestId': const Uuid().v4(),
        'input': input,
        'before': before
      })) as Json;
      await store.save(tenant, actor, row);
      if (!current) return;
      pending = row;
      await _send();
    } catch (failure) {
      if (current) {
        error = failure;
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      _changed();
    }
  }

  String get _path =>
      '/tenants/$tenant/members/${pending!['before']['memberKey']}';
  Json _checkCommitted(dynamic raw) {
    final result = readMemberAccess(raw),
        before = pending!['before'] as Json,
        input = pending!['input'] as Json;
    if (result['memberKey'] != before['memberKey'] ||
        result['actorId'] != before['actorId'] ||
        result['version'] < before['version'] ||
        result['version'] > before['version'] + 1 ||
        result['role'] != input['role'] ||
        result['subjectId'] != input['subjectId'] ||
        !setEquals((result['classIds'] as List).toSet(),
            (input['classIds'] as List).toSet())) throw _invalid;
    return result;
  }

  Future<void> _send() async {
    final input = pending!['input'] as Json,
        revoke = input['operation'] == 'REVOKE';
    final result = await api.send(revoke ? 'DELETE' : 'PATCH', '$_path/access',
        body: revoke
            ? null
            : {
                'role': input['role'],
                'subjectId': input['subjectId'],
                'classIds': input['classIds']
              },
        version: input['version'],
        idempotencyKey: pending!['requestId'],
        isCurrent: () => current);
    if (!current) return;
    if (!revoke) committed = _checkCommitted(result);
    saved = true;
    await _query();
  }

  Future<void> _query() async {
    final p = pending!,
        before = p['before'] as Json,
        input = p['input'] as Json,
        revoke = input['operation'] == 'REVOKE';
    try {
      final result = await api.send(
          'POST', '$_path/access-results/${p['requestId']}/query',
          body: input, isCurrent: () => current);
      if (!current) return;
      if (result is! Json ||
          result['requestId'] != p['requestId'] ||
          result['operation'] != input['operation'] ||
          result['revocationCommitted'] != revoke ||
          !const {'ACTIVE', 'REVOKED'}.contains(result['currentState']) ||
          (revoke && result['committedAccess'] != null)) throw _invalid;
      final original =
              revoke ? null : _checkCommitted(result['committedAccess']),
          now = readMemberAccess(result['current']);
      if (now['actorId'] != before['actorId'] ||
          now['memberKey'] != before['memberKey'] ||
          now['version'] <
              (revoke ? before['version'] + 1 : original!['version'])) {
        throw _invalid;
      }
      committed = original;
      latest = now;
      currentState = result['currentState'];
      saved = true;
      queried = true;
    } on ParentApiException catch (failure) {
      if (current &&
          failure.status == 404 &&
          failure.code == 'MEMBER_RESULT_UNAVAILABLE') {
        queried = true;
        latest = null;
        currentState = null;
      } else {
        rethrow;
      }
    }
  }

  Future<void> recover({bool retry = false}) async {
    if (!current || busy || pending == null || (retry && saved)) return;
    busy = true;
    error = null;
    latest = null;
    currentState = null;
    _changed();
    try {
      if (retry) {
        await _send();
      } else {
        await _query();
      }
    } catch (failure) {
      if (current) error = failure;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<bool> acknowledge() async {
    if (!current || busy || pending == null || !queried) return false;
    busy = true;
    error = null;
    _changed();
    try {
      await store.clear(tenant, actor, pending!['requestId']);
      if (!current) return false;
      pending = null;
      committed = null;
      latest = null;
      currentState = null;
      saved = false;
      queried = false;
      return true;
    } catch (failure) {
      if (current) error = failure;
      return false;
    } finally {
      busy = false;
      _changed();
    }
  }
}

String memberFailure(Object e) => e is ParentApiException
    ? switch (e.code) {
        'OWNER_TRANSFER_REQUIRED' => '所有者需要通过专门的所有权交接流程变更。',
        'MEMBER_CLASS_CHANGE_REQUIRES_INVITATION' =>
          '儿童与成人身份不能直接互换，请使用经过验证的邀请流程。',
        'SUBJECT_SCOPE_REQUIRED' => '请选择一个有效的儿童或学生档案。',
        'CLASS_SCOPE_UNAVAILABLE' => '所选班级已有不可用项，请重新核对班级范围。',
        'ROLE_SCOPE_NOT_APPLICABLE' => '角色与范围不匹配，请重新选择。',
        'ROLE_NOT_APPLICABLE' => '该角色不适用于当前家庭或机构。',
        'IDEMPOTENCY_KEY_EXPIRED' => '原请求已超过重试期限，请查询结果并核对成员记录。',
        _ => e.toString(),
      }
    : e.toString();

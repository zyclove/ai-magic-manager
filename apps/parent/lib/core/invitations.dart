import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'member_access.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
import 'operation_journal.dart';
import 'operation_result_terminal.dart';

const invitationStates = {
  'PENDING': '待接受',
  'ACCEPTED': '已加入',
  'CANCELLED': '已取消',
  'EXPIRED': '已过期'
};
bool _uuid(dynamic v) =>
    v is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(v);
const _invalid = ParentApiException(502, 'INVALID_INVITATION_RESPONSE');

Json readInvitation(dynamic raw) {
  if (raw is! Json ||
      !_uuid(raw['id']) ||
      raw['role'] is! String ||
      raw['role'] == 'OWNER' ||
      !validMemberScope(raw['role'], raw['subjectId'], raw['classIds']) ||
      raw['expiresAt'] is! int ||
      raw['expiresAt'] < 0 ||
      raw['expiresAt'] > 253402300799999 ||
      !invitationStates.containsKey(raw['state'])) throw _invalid;
  return Map<String, dynamic>.unmodifiable(raw);
}

List<String> invitationRoles(String kind, String operatorRole) =>
    const {'OWNER', 'ORG_ADMIN'}.contains(operatorRole)
        ? [...memberRoles(kind, operatorRole, 'AUDITOR'), 'CHILD']
        : const [];

void validateInvitationInput(Json input) {
  const fields = {'recipientEmail', 'role', 'subjectId', 'classIds'};
  if (!setEquals(input.keys.toSet(), fields) ||
      input['recipientEmail'] is! String ||
      input['recipientEmail'].length > 254 ||
      !RegExp(r'^[^@\s]+@[^@\s]+$').hasMatch(input['recipientEmail']) ||
      input['role'] is! String ||
      input['role'] == 'OWNER' ||
      !validMemberScope(input['role'], input['subjectId'], input['classIds'])) {
    throw const FormatException('请填写有效收件邮箱，并核对角色和范围。');
  }
}

/// Only request descriptors are encrypted locally. Raw invitation tokens stay in memory.
class InvitationOperationStore {
  late final ParentOperationJournal journal = ParentOperationJournal(storage);
  final ParentDurableStorage storage;
  InvitationOperationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String key(String tenant, String actor) =>
      'parent.pending.invitation.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final value = await journal.read(key: key(tenant, actor));
    if (value == null) return null;
    if (value.length > 16384) throw const FormatException('邀请恢复记录过大。');
    final row = jsonDecode(value);
    if (row is! Json ||
        !_uuid(row['requestId']) ||
        !const {'ISSUE', 'CANCEL'}.contains(row['operation']) ||
        row.keys.any((k) =>
            !const {'requestId', 'operation', 'input', 'before'}.contains(k))) {
      throw const FormatException('邀请恢复记录无效，请联系管理员。');
    }
    if (row['operation'] == 'ISSUE') {
      if (row['input'] is! Json || row['before'] != null) {
        throw const FormatException('邀请恢复参数无效。');
      }
      validateInvitationInput(row['input']);
    } else {
      readInvitation(row['before']);
      if (row['input'] != null) throw const FormatException('取消邀请参数无效。');
    }
    return row;
  }

  Future<void> save(String tenant, String actor, Json row) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对上次邀请操作。');
    final encoded = jsonEncode(row);
    if (encoded.length > 16384) throw const FormatException('邀请恢复记录过大。');
    await journal.write(key: key(tenant, actor), value: encoded);
  }

  Future<void> clear(String tenant, String actor, String id) async {
    final row = await load(tenant, actor);
    if (row != null && row['requestId'] != id) throw StateError('邀请恢复记录已变化。');
    await journal.delete(key: key(tenant, actor));
  }
}

class InvitationOperationController extends ChangeNotifier with ParentTerminalOperation {
  @override
  ParentOperationJournal get operationJournal => store.journal;
  @override
  String get operationSlot => store.key(tenant, actor);
  @override
  Json? get operationPayload => pending;
  @override
  bool get operationCurrent => current;
  @override
  bool get operationHasSuccessfulResult => committed && pending?['operation'] == 'ISSUE';
  @override
  void forgetOperationPayload() {
    pending = null;
    latest = null;
    _token = null;
    queried = false;
    loaded = false;
    committed = false;
    _secretEpoch++;
  }
  final ParentApi api;
  final String tenant, actor;
  final InvitationOperationStore store;
  final bool Function() isCurrent;
  bool busy = false,
      loaded = false,
      queried = false,
      committed = false,
      _disposed = false;
  Json? pending, latest;
  String? _token;
  int _secretEpoch = 0;
  Object? error;
  InvitationOperationController(
      {required this.api,
      required this.tenant,
      required this.actor,
      required this.store,
      required this.isCurrent});
  bool get current => !_disposed && isCurrent();
  bool get canSubmit => current && loaded && !busy && pending == null;
  String get root => '/tenants/$tenant/invitations';
  String? get token => current &&
          latest?['state'] == 'PENDING' &&
          latest!['expiresAt'] > DateTime.now().millisecondsSinceEpoch
      ? _token
      : null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void forgetToken() {
    _secretEpoch++;
    _token = null;
    _notify();
  }

  @override
  void dispose() {
    _token = null;
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    if (!current || busy) return;
    busy = true;
    loaded = false;
    error = null;
    _token = null;
    _notify();
    try {
      final row = await store.load(tenant, actor);
      if (current) {
        pending = row;
        latest = null;
        committed = false;
        queried = false;
        loaded = true;
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (current) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> issue(Json input) async {
    if (operationBlocked) return;
    if (!canSubmit) return;
    validateInvitationInput(input);
    await _submit(
        {'requestId': const Uuid().v4(), 'operation': 'ISSUE', 'input': input});
  }

  Future<void> cancel(Json before) async {
    if (operationBlocked) return;
    if (!canSubmit) return;
    readInvitation(before);
    await _submit({
      'requestId': const Uuid().v4(),
      'operation': 'CANCEL',
      'before': before
    });
  }

  Future<void> _submit(Json row) async {
    busy = true;
    error = null;
    _token = null;
    _notify();
    try {
      final copy = jsonDecode(jsonEncode(row)) as Json;
      await store.save(tenant, actor, copy);
      if (!current) return;
      pending = copy;
      await _send();
    } catch (e) {
      await captureResultTerminal(e);
      if (current) {
        error = e;
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Json _checkIssued(dynamic raw, {required bool query}) {
    if (raw is! Json || raw['requestId'] != pending!['requestId']) {
      throw _invalid;
    }
    final row = readInvitation(raw['invitation']),
        input = pending!['input'] as Json;
    if (row['role'] != input['role'] ||
        row['subjectId'] != input['subjectId'] ||
        !setEquals((row['classIds'] as List).toSet(),
            (input['classIds'] as List).toSet()) ||
        (latest != null && row['id'] != latest!['id']) ||
        (query && raw['token'] != null) ||
        (raw['token'] != null &&
            (raw['token'] is! String ||
                !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(raw['token'])))) {
      throw _invalid;
    }
    return row;
  }

  Future<void> _send() async {
    final p = pending!;
    if (p['operation'] == 'ISSUE') {
      final secretEpoch = _secretEpoch;
      final result = await api.send('POST', '$root/issuances',
          body: p['input'],
          idempotencyKey: p['requestId'],
          isCurrent: () => current, beforeDispatch: operationBeforeWrite);
      if (!current) return;
      final row = _checkIssued(result, query: false);
      latest = row;
      _token = secretEpoch == _secretEpoch ? result['token'] : null;
      committed = true;
      queried = true;
      if (operationHasSuccessfulResult) await recordSuccessfulOperation();
    } else {
      await api.send('DELETE', '$root/${p['before']['id']}',
          isCurrent: () => current, beforeDispatch: operationBeforeWrite);
      if (!current) return;
      committed = true;
      await recordSuccessfulOperation();
      await _query();
    }
  }

  Future<void> _query() async {
    final p = pending!;
    try {
      if (p['operation'] == 'ISSUE') {
        final result = await api.send(
            'POST', '$root/issuance-results/${p['requestId']}/query',
            body: p['input'], isCurrent: () => current, beforeDispatch: operationBeforeDispatch);
        if (!current) return;
        latest = _checkIssued(result, query: true);
        committed = true;
      } else {
        final row = readInvitation(await api
            .object('$root/${p['before']['id']}', isCurrent: () => current));
        if (!current) return;
        if (row['id'] != p['before']['id'] ||
            row['role'] != p['before']['role'] ||
            row['expiresAt'] != p['before']['expiresAt']) throw _invalid;
        latest = row;
        // A concurrently accepted invitation is not a successful cancellation.
        committed = row['state'] == 'CANCELLED';
      }
      queried = true;
      if (operationHasSuccessfulResult) await recordSuccessfulOperation();
      if (latest?['state'] != 'PENDING') _token = null;
    } on ParentApiException catch (e) {
      await captureResultTerminal(e);
      if (current &&
          e.status == 404 &&
          e.code == 'INVITATION_RESULT_UNAVAILABLE') {
        queried = true;
      } else {
        rethrow;
      }
    }
  }

  Future<void> recover({bool retry = false}) async {
    if (operationBlocked) return;
    if (!current || busy || pending == null || (retry && (committed || operationKnownSuccessful))) return;
    busy = true;
    error = null;
    _notify();
    try {
      if (retry) {
        await _send();
      } else {
        if (operationHasSuccessfulResult) await recordSuccessfulOperation();
        await _query();
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (current) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> acknowledge() async {
    if (operationBlocked) return false;
    if (!current || busy || !queried || pending == null) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await store.clear(tenant, actor, pending!['requestId']);
      if (!current) return false;
      pending = null;
      latest = null;
      _token = null;
      queried = false;
      committed = false;
      return true;
    } catch (e) {
      await captureResultTerminal(e);
      if (current) error = e;
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }
}

String invitationFailure(Object e) => e is ParentApiException
    ? switch (e.code) {
        'INVITATION_ALREADY_ACCEPTED' => '对方已经加入，不能通过取消邀请撤销成员资格。请查看成员权限。',
        'INVITATION_RESULT_UNAVAILABLE' => '未找到可读取的原结果，请核对邀请记录。',
        'IDEMPOTENCY_KEY_EXPIRED' => '已超过原请求重试期限，请查询原结果。',
        'INVALID_INVITATION_RESPONSE' => '邀请响应未通过校验，请重新核对。',
        _ => memberFailure(e),
      }
    : e.toString();

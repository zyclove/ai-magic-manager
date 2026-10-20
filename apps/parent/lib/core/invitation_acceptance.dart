import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'member_access.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
import 'operation_journal.dart';
import 'operation_result_terminal.dart';

bool _uuid(dynamic v) =>
    v is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(v);
bool _text(dynamic v) => v is String && v.trim().isNotEmpty && v.length <= 100;
bool _version(dynamic v) => v is int && v >= 0 && v <= 9007199254740991;
bool validInvitationToken(String token) =>
    RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token);
const _invalid =
    ParentApiException(502, 'INVALID_INVITATION_ACCEPTANCE_RESPONSE');

Json readInvitationPreview(dynamic raw) {
  if (raw is! Json ||
      !_uuid(raw['invitationId']) ||
      !_uuid(raw['tenantId']) ||
      !_text(raw['tenantName']) ||
      !const {'FAMILY', 'ORGANIZATION'}.contains(raw['tenantKind']) ||
      raw['role'] is! String ||
      raw['role'] == 'OWNER' ||
      raw['classes'] is! List ||
      raw['classes'].length > 50 ||
      raw['expiresAt'] is! int ||
      raw['expiresAt'] < 0 ||
      raw['expiresAt'] > 253402300799999 ||
      raw['requiresRecentAuthentication'] != (raw['role'] != 'CHILD')) {
    throw _invalid;
  }
  final classIds = <String>[];
  for (final row in raw['classes']) {
    if (row is! Json || !_uuid(row['id']) || !_text(row['name'])) {
      throw _invalid;
    }
    classIds.add(row['id']);
  }
  if (!validMemberScope(raw['role'], raw['subjectId'], classIds) ||
      (raw['subjectId'] == null
          ? raw['subjectName'] != null
          : !_text(raw['subjectName'])) ||
      (raw['tenantKind'] == 'FAMILY' &&
          const {'TEACHER', 'ORG_ADMIN'}.contains(raw['role'])) ||
      (raw['tenantKind'] == 'ORGANIZATION' && raw['role'] == 'GUARDIAN')) {
    throw _invalid;
  }
  return Map<String, dynamic>.unmodifiable(raw);
}

void validateAcceptanceReference(Json row) {
  if (!setEquals(row.keys.toSet(),
          {'requestId', 'invitationId', 'tenantId', 'role'}) ||
      !_uuid(row['requestId']) ||
      !_uuid(row['invitationId']) ||
      !_uuid(row['tenantId']) ||
      !memberRoleLabels.containsKey(row['role']) ||
      row['role'] == 'OWNER') throw const FormatException('加入恢复记录无效，请联系管理员。');
}

class InvitationAcceptanceStore {
  late final ParentOperationJournal journal = ParentOperationJournal(storage);
  final ParentDurableStorage storage;
  InvitationAcceptanceStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String key(String actor) => 'parent.pending.invitation-acceptance.$actor';
  Future<Json?> load(String actor) async {
    final raw = await journal.read(key: key(actor));
    if (raw == null) return null;
    if (raw.length > 2048) throw const FormatException('加入恢复记录过大。');
    final row = jsonDecode(raw);
    if (row is! Json) throw const FormatException('加入恢复记录无效。');
    validateAcceptanceReference(row);
    return row;
  }

  Future<void> save(String actor, Json row) async {
    validateAcceptanceReference(row);
    if (await load(actor) != null) throw StateError('请先核对上次加入操作。');
    await journal.write(key: key(actor), value: jsonEncode(row));
  }

  Future<void> clear(String actor, String id) async {
    final row = await load(actor);
    if (row != null && row['requestId'] != id) throw StateError('加入恢复记录已变化。');
    await journal.delete(key: key(actor));
  }
}

/// An actor may join before any workspace exists. No token is stored in the recovery descriptor.
class InvitationAcceptanceController extends ChangeNotifier with ParentTerminalOperation {
  @override
  ParentOperationJournal get operationJournal => store.journal;
  @override
  String get operationSlot => store.key(actor);
  @override
  Json? get operationPayload => pending;
  @override
  bool get operationCurrent => current;
  @override
  bool get operationHasSuccessfulResult => committed;
  @override
  void forgetOperationPayload() {
    pending = null;
    preview = null;
    result = null;
    _token = null;
    queried = false;
    loaded = false;
    committed = false;
    _secretEpoch++;
  }
  final ParentApi api;
  final String actor;
  final InvitationAcceptanceStore store;
  final bool Function() isCurrent;
  bool busy = false,
      loaded = false,
      queried = false,
      committed = false,
      _disposed = false;
  Json? preview, pending, result;
  Object? error;
  String? _token;
  int _secretEpoch = 0;
  InvitationAcceptanceController(
      {required this.api,
      required this.actor,
      required this.store,
      required this.isCurrent});
  bool get current => !_disposed && isCurrent();
  bool get canPreview => current && loaded && !busy && pending == null;
  bool get canAccept =>
      canPreview &&
      preview != null &&
      _token != null &&
      preview!['expiresAt'] > DateTime.now().millisecondsSinceEpoch;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void forgetSecret() {
    _secretEpoch++;
    _token = null;
    preview = null;
    _notify();
  }

  @override
  void dispose() {
    _secretEpoch++;
    _token = null;
    preview = null;
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    if (!current || busy) return;
    busy = true;
    loaded = false;
    error = null;
    forgetSecret();
    try {
      final row = await store.load(actor);
      if (current) {
        pending = row;
        result = null;
        queried = false;
        committed = false;
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

  Future<void> inspect(String input) async {
    if (operationBlocked) return;
    if (!canPreview) return;
    final token = input.trim();
    forgetSecret();
    error = null;
    if (!validInvitationToken(token)) {
      error = const FormatException('请输入完整的 43 位邀请码。');
      _notify();
      return;
    }
    final epoch = _secretEpoch;
    busy = true;
    _notify();
    try {
      final raw = await api.send('POST', '/invitations/preview',
          body: {'token': token},
          isCurrent: () => current && epoch == _secretEpoch, beforeDispatch: operationBeforeWrite);
      if (!current || epoch != _secretEpoch) return;
      preview = readInvitationPreview(raw);
      _token = token;
    } catch (e) {
      await captureResultTerminal(e);
      if (current && epoch == _secretEpoch) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> accept() async {
    if (operationBlocked) return;
    if (canPreview &&
        preview != null &&
        preview!['expiresAt'] <= DateTime.now().millisecondsSinceEpoch) {
      error = const ParentApiException(409, 'INVITATION_UNAVAILABLE');
      forgetSecret();
      return;
    }
    if (!canAccept) return;
    final token = _token!, view = preview!, epoch = _secretEpoch;
    busy = true;
    error = null;
    _notify();
    try {
      final row = <String, dynamic>{
        'requestId': const Uuid().v4(),
        'invitationId': view['invitationId'],
        'tenantId': view['tenantId'],
        'role': view['role']
      };
      await store.save(actor, row);
      if (!current || epoch != _secretEpoch) return;
      pending = row;
      await _send(token);
    } catch (e) {
      await captureResultTerminal(e);
      if (current) {
        error = e;
        if (pending == null) loaded = false;
      }
    } finally {
      _token = null;
      preview = null;
      if (pending == null) loaded = false;
      busy = false;
      _notify();
    }
  }

  Json _readResult(dynamic raw) {
    final p = pending!;
    if (raw is! Json ||
        raw['requestId'] != p['requestId'] ||
        raw['actorId'] != actor ||
        raw['accepted'] is! Json ||
        raw['current'] is! Json) throw _invalid;
    final accepted = raw['accepted'] as Json, now = raw['current'] as Json;
    if (accepted['invitationId'] != p['invitationId'] ||
        accepted['tenantId'] != p['tenantId'] ||
        accepted['role'] != p['role'] ||
        !_version(accepted['memberVersion']) ||
        !const {'ACTIVE', 'REVOKED', 'MISSING'}.contains(now['state']) ||
        (now['state'] == 'MISSING'
            ? (now['role'] != null || now['version'] != null)
            : !memberRoleLabels.containsKey(now['role']) ||
                !_version(now['version']) ||
                now['version'] < accepted['memberVersion'])) throw _invalid;
    return Map<String, dynamic>.unmodifiable(raw);
  }

  Future<void> _send(String token) async {
    final epoch = _secretEpoch;
    final raw = await api.send('POST', '/invitations/acceptances',
        body: {'invitationId': pending!['invitationId'], 'token': token},
        idempotencyKey: pending!['requestId'],
        isCurrent: () => current && epoch == _secretEpoch, beforeDispatch: operationBeforeWrite);
    if (!current) return;
    result = _readResult(raw);
    committed = true;
    queried = true;
    if (operationHasSuccessfulResult) await recordSuccessfulOperation();
  }

  Future<void> recover({String? retryToken}) async {
    if (operationBlocked) return;
    if (!current ||
        busy ||
        pending == null ||
        (retryToken != null && (committed || operationKnownSuccessful))) return;
    if (retryToken != null && !validInvitationToken(retryToken.trim())) {
      error = const FormatException('请重新输入原邀请的完整 43 位邀请码。');
      _notify();
      return;
    }
    busy = true;
    error = null;
    _notify();
    try {
      if (retryToken != null) {
        await _send(retryToken.trim());
      } else {
        final raw = await api.object(
            '/invitations/${pending!['invitationId']}/acceptance-results/${pending!['requestId']}',
            isCurrent: () => current, beforeDispatch: operationBeforeDispatch);
        if (!current) return;
        result = _readResult(raw);
        committed = true;
        queried = true;
        if (operationHasSuccessfulResult) await recordSuccessfulOperation();
      }
    } on ParentApiException catch (e) {
      await captureResultTerminal(e);
      if (current) {
        if (retryToken == null &&
            ((e.status == 404 &&
                    e.code == 'INVITATION_ACCEPTANCE_RESULT_UNAVAILABLE'))) {
          queried = true;
          error = e;
        } else {
          error = e;
        }
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
    if (!current || busy || pending == null || !queried) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await store.clear(actor, pending!['requestId']);
      if (!current) return false;
      pending = null;
      result = null;
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

String acceptanceFailure(Object e) => e is ParentApiException
    ? switch (e.code) {
        'INVITATION_UNAVAILABLE' => '邀请已使用、过期或取消。若先前提交结果不明，请核对原操作。',
        'MEMBER_ALREADY_EXISTS' => '此账号已是该工作空间的成员，无需重复加入。可刷新工作空间查看。',
        'INVITATION_ACCEPTANCE_RESULT_UNAVAILABLE' =>
          '暂时没有可读取的原结果，不代表从未加入。请核对工作空间或重试原邀请。',
        'IDEMPOTENCY_RESPONSE_ERASED' => '原结果已按数据处理流程移除，无法恢复；请核对当前工作空间。',
        'INVALID_INVITATION_ACCEPTANCE_RESPONSE' => '加入响应未通过校验，请重新核对。',
        'FORBIDDEN' || 'SCOPE_DENIED' => '无法使用此邀请，请核对邀请码、登录账号及已验证的收件邮箱。',
        _ => e.toString(),
      }
    : e.toString();

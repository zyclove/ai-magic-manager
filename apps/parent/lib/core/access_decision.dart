import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'pending_decisions.dart';

const accessStates = {
  'PENDING': '待处理',
  'APPROVED_PENDING_DELIVERY': '已批准，待核对设备',
  'DENIED': '已拒绝',
  'CANCELLED': '已取消',
  'EXPIRED': '已到期',
  'REVOKED': '已撤销',
  'INVALIDATED': '已失效'
};
const denialReasons = {
  'NOT_NOW': '现在不适合',
  'NOT_ALLOWED': '不允许使用',
  'OTHER': '其他原因'
};
bool _uuid(dynamic v) =>
    v is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(v);
Json decisionRequest(dynamic v, String id) {
  if (v is! Json ||
      v['id'] != id ||
      !_uuid(id) ||
      ![
        'subjectId',
        'deviceId',
        'registrationId',
        'policyId',
        'baseVersionId',
        'applicationId'
      ].every((k) => _uuid(v[k])) ||
      v['version'] is! int ||
      v['version'] < 0 ||
      v['version'] >= 9007199254740991 ||
      !accessStates.containsKey(v['state']) ||
      v['requestedWindowSeconds'] is! int ||
      v['requestedWindowSeconds'] < 1 ||
      v['requestedWindowSeconds'] > 3600) {
    throw const ParentApiException(502, 'INVALID_RESPONSE');
  }
  return jsonDecode(jsonEncode(v)) as Json;
}

/// Shared by the inbox and current-request detail. Never replays a decision.
class ParentAccessDecision extends ChangeNotifier {
  final ParentApi api;
  final PendingDecisionStore store;
  final String tenant, actor, requestId;
  final bool Function() isCurrent, foreground;
  final Future<bool> Function() reauthenticate;
  Json? request, receipt;
  PendingDecision? pending;
  Object? error;
  bool busy = false, loaded = false, queried = false, disposed = false;
  int generation = 0;
  bool get available => !disposed && isCurrent() && foreground();
  String get path => '/tenants/$tenant/access-requests/$requestId';
  ParentAccessDecision(
      {required this.api,
      required this.store,
      required this.tenant,
      required this.actor,
      required this.requestId,
      required this.isCurrent,
      required this.foreground,
      required this.reauthenticate});
  bool valid(int g) => available && generation == g;
  void notify() {
    if (!disposed) notifyListeners();
  }

  Future<void> load() async {
    if (!available || busy) return;
    final g = ++generation;
    busy = true;
    error = null;
    request = null;
    loaded = false;
    queried = false;
    notify();
    try {
      if (!_uuid(requestId)) {
        throw const ParentApiException(400, 'INVALID_RESPONSE');
      }
      final records = await store.load(tenant, actor);
      if (!valid(g)) return;
      final matches = records.where((r) => r.requestId == requestId).toList();
      if (matches.length > 1) {
        throw const FormatException('同一申请有多条待核对记录，请先在申请页核对。');
      }
      pending = matches.isEmpty ? null : matches.single;
      final current = decisionRequest(
          await api.object(path, isCurrent: () => valid(g)), requestId);
      if (!valid(g)) return;
      if (pending != null && current['version'] < pending!.version) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      request = current;
      loaded = true;
      queried = pending != null;
    } catch (e) {
      if (valid(g)) error = e;
    } finally {
      if (!disposed) {
        busy = false;
        notify();
      }
    }
  }

  Future<void> execute(
      {required String choice, int? seconds, String? reason}) async {
    if (!available ||
        busy ||
        !loaded ||
        request?['state'] != 'PENDING' ||
        pending != null) return;
    final original = decisionRequest(request, requestId);
    if (!{'APPROVE', 'DENY'}.contains(choice) ||
        choice == 'APPROVE' &&
            (seconds == null ||
                seconds < 1 ||
                seconds > original['requestedWindowSeconds'] ||
                reason != null) ||
        choice == 'DENY' &&
            (seconds != null || !denialReasons.containsKey(reason))) {
      error = const FormatException('请核对批准时长或拒绝原因。');
      notify();
      return;
    }
    busy = true;
    error = null;
    receipt = null;
    queried = false;
    notify();
    try {
      if (!await reauthenticate() || !available) return;
      final g = generation;
      final current = decisionRequest(
          await api.object(path, isCurrent: () => valid(g)), requestId);
      if (!valid(g)) return;
      if (current['state'] != 'PENDING' ||
          current['version'] != original['version'] ||
          [
            'subjectId',
            'deviceId',
            'registrationId',
            'policyId',
            'baseVersionId',
            'applicationId',
            'requestedWindowSeconds'
          ].any((key) => current[key] != original[key])) {
        throw const ParentApiException(412, 'RESOURCE_VERSION_CONFLICT');
      }
      final marker = PendingDecision(
          requestId: requestId,
          version: original['version'],
          idempotencyKey: const Uuid().v4(),
          choice: choice,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          grantedWindowSeconds: seconds,
          reasonCode: reason);
      await store.add(tenant, actor, marker);
      if (!valid(g)) return;
      pending = marker;
      loaded = false;
      notify();
      final body = <String, dynamic>{
        'decision': choice,
        if (seconds != null) 'grantedWindowSeconds': seconds,
        if (reason != null) 'reasonCode': reason
      };
      final result = decisionRequest(
          await api.send('POST', '$path/decisions',
              body: body,
              version: marker.version,
              idempotencyKey: marker.idempotencyKey,
              isCurrent: () => valid(g)),
          requestId);
      if (!valid(g)) return;
      if (result['version'] != marker.version + 1 ||
          result['state'] !=
              (choice == 'APPROVE' ? 'APPROVED_PENDING_DELIVERY' : 'DENIED') ||
          [
            'subjectId',
            'deviceId',
            'registrationId',
            'policyId',
            'baseVersionId',
            'applicationId',
            'requestedWindowSeconds'
          ].any((key) => result[key] != original[key]) ||
          (choice == 'APPROVE'
              ? result['grantedWindowSeconds'] != seconds ||
                  result['issuedAt'] is! int ||
                  result['absoluteNotAfter'] !=
                      result['issuedAt'] + seconds! * 1000
              : result['reasonCode'] != reason)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      receipt = result;
      await store.remove(tenant, actor, marker.idempotencyKey);
      if (!valid(g)) return;
      pending = null;
      request = result;
    } catch (e) {
      if (available) {
        error = e;
        loaded = false;
      }
    } finally {
      if (!disposed) {
        busy = false;
        notify();
      }
    }
  }

  Future<bool> acknowledge() async {
    if (!available || busy || !queried || pending == null) return false;
    busy = true;
    error = null;
    notify();
    try {
      final g = generation;
      await store.remove(tenant, actor, pending!.idempotencyKey);
      if (!valid(g)) return false;
      pending = null;
      loaded = false;
      queried = false;
      return true;
    } catch (e) {
      if (available) error = e;
      return false;
    } finally {
      if (!disposed) {
        busy = false;
        notify();
      }
    }
  }

  void hide() {
    generation++;
    request = null;
    receipt = null;
    loaded = false;
    queried = false;
    error = null;
    notify();
  }

  @override
  void dispose() {
    disposed = true;
    generation++;
    super.dispose();
  }
}

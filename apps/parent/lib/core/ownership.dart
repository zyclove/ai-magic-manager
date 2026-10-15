import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

const ownershipStates = {
  'PENDING': '等待接收人确认',
  'ACCEPTED': '交接已完成',
  'DECLINED': '接收人已拒绝',
  'CANCELLED': '发起人已撤销',
  'EXPIRED': '申请已过期',
  'INVALIDATED': '申请已失效'
};
const ownershipConsequences =
    '交接生效后，原所有者未完成的成员邀请、设备配对、退出预览及临时授权将失效，未发布策略需重新预览。已发布策略和已确认的设备退出保留。支付与合同责任不会自动转移。';
const ownershipRoles = {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'};
const _invalid = ParentApiException(502, 'INVALID_OWNERSHIP_RESPONSE');
bool _uuid(dynamic v) =>
    v is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(v);
bool _actor(dynamic v) => v is String && v.trim().isNotEmpty && v.length <= 255;
bool _version(dynamic v) => v is int && v >= 0 && v <= 9007199254740991;
bool _date(dynamic v) => _version(v) && v <= 253402300799999;

Json readOwnership(dynamic raw, String tenant) {
  if (raw is! Json ||
      raw['tenantId'] != tenant ||
      !_uuid(raw['id']) ||
      !_actor(raw['sourceActorId']) ||
      !_actor(raw['targetActorId']) ||
      raw['sourceActorId'] == raw['targetActorId'] ||
      ![
        'sourceMemberVersion',
        'targetMemberVersion',
        'tenantVersion',
        'version'
      ].every((k) => _version(raw[k])) ||
      !const {'GUARDIAN', 'ORG_ADMIN'}.contains(raw['formerOwnerRole']) ||
      !(raw['targetRole'] == raw['formerOwnerRole'] ||
          raw['targetRole'] == 'AUDITOR') ||
      !ownershipStates.containsKey(raw['state']) ||
      !['createdAt', 'expiresAt', 'updatedAt'].every((k) => _date(raw[k])) ||
      raw['createdAt'] >= raw['expiresAt'] ||
      raw['updatedAt'] < raw['createdAt'] ||
      (raw['state'] == 'EXPIRED'
          ? raw['reason'] != 'TIME_EXPIRED'
          : raw['state'] == 'INVALIDATED'
              ? !const {'TENANT_CHANGED', 'MEMBERSHIP_CHANGED'}
                  .contains(raw['reason'])
              : raw['reason'] != null)) throw _invalid;
  return Map<String, dynamic>.unmodifiable(raw);
}

void validateOwnershipInput(Json input) {
  final start = input['operation'] == 'start';
  if (!const {'start', 'accept', 'decline', 'cancel'}
          .contains(input['operation']) ||
      !_version(input['version']) ||
      !setEquals(input.keys.toSet(),
          {'operation', 'version', start ? 'targetActorId' : 'transferId'}) ||
      (start ? !_actor(input['targetActorId']) : !_uuid(input['transferId']))) {
    throw const FormatException('交接操作记录不完整，请重新核对。');
  }
}

/// Only references and the exact request are stored; display names and contact data stay in memory.
class OwnershipStore {
  final ParentDurableStorage storage;
  OwnershipStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String key(String tenant, String actor) =>
      'parent.pending.ownership.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final value = await storage.read(key: key(tenant, actor));
    if (value == null) return null;
    if (value.length > 4096) throw const FormatException('交接恢复记录过大。');
    final row = jsonDecode(value);
    if (row is! Json ||
        !setEquals(row.keys.toSet(), {'requestId', 'input'}) ||
        !_uuid(row['requestId']) ||
        row['input'] is! Json) throw const FormatException('交接恢复记录无效。');
    validateOwnershipInput(row['input']);
    return row;
  }

  Future<void> save(String tenant, String actor, Json row) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对上一项交接操作。');
    validateOwnershipInput(row['input']);
    if (!_uuid(row['requestId']) ||
        !setEquals(row.keys.toSet(), {'requestId', 'input'})) {
      throw const FormatException('交接请求编号无效。');
    }
    await storage.write(key: key(tenant, actor), value: jsonEncode(row));
  }

  Future<void> clear(String tenant, String actor, String id) async {
    final row = await load(tenant, actor);
    if (row != null && row['requestId'] != id) throw StateError('交接恢复记录已变化。');
    await storage.delete(key: key(tenant, actor));
  }
}

class OwnershipOperation extends ChangeNotifier {
  final ParentApi api;
  final String tenant, actor;
  final OwnershipStore store;
  final bool Function() isCurrent;
  bool busy = false,
      loaded = false,
      queried = false,
      committed = false,
      _disposed = false;
  Json? pending, original, current;
  String? currentRole;
  Object? error;
  int _foregroundEpoch = 0;

  /// Losing foreground invalidates a write waiting for storage or token refresh.
  void suspend() {
    _foregroundEpoch++;
  }

  OwnershipOperation(
      {required this.api,
      required this.tenant,
      required this.actor,
      required this.store,
      required this.isCurrent});
  bool get active => !_disposed && isCurrent();
  String get path => '/tenants/$tenant/ownership-transfers';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    if (!active || busy) return;
    busy = true;
    loaded = false;
    error = null;
    _notify();
    try {
      final row = await store.load(tenant, actor);
      if (active) {
        pending = row;
        original = null;
        current = null;
        currentRole = null;
        queried = false;
        committed = false;
        loaded = true;
      }
    } catch (e) {
      if (active) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> submit(Json input) async {
    if (!active || busy || !loaded || pending != null) return;
    busy = true;
    error = null;
    final epoch = _foregroundEpoch;
    _notify();
    try {
      validateOwnershipInput(input);
      final row = <String, dynamic>{
        'requestId': const Uuid().v4(),
        'input': Map<String, dynamic>.from(input)
      };
      await store.save(tenant, actor, row);
      if (!active || epoch != _foregroundEpoch) {
        loaded = false;
        return;
      }
      pending = row;
      await _write(epoch);
    } catch (e) {
      if (active) {
        error = e;
        // A storage implementation may fail after writing; reload before allowing another request.
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  void _matches(Json value) {
    final input = pending!['input'] as Json;
    if (input['operation'] == 'start') {
      if (value['sourceActorId'] != actor ||
          value['targetActorId'] != input['targetActorId'] ||
          value['tenantVersion'] != input['version'] ||
          value['state'] != 'PENDING' ||
          value['version'] != 0) throw _invalid;
    } else if (value['id'] != input['transferId'] ||
        value['version'] < input['version'] ||
        (input['operation'] == 'cancel'
            ? value['sourceActorId'] != actor
            : value['targetActorId'] != actor)) {
      throw _invalid;
    }
    if (input['operation'] != 'start') {
      final expected = switch (input['operation']) {
        'accept' => 'ACCEPTED',
        'decline' => 'DECLINED',
        _ => 'CANCELLED'
      };
      if (!{expected, 'EXPIRED', 'INVALIDATED'}.contains(value['state'])) {
        throw _invalid;
      }
    }
  }

  Future<void> _write(int epoch) async {
    final input = pending!['input'] as Json,
        start = input['operation'] == 'start';
    final raw = await api.send('POST',
        start ? path : '$path/${input['transferId']}/${input['operation']}',
        body: start ? {'targetActorId': input['targetActorId']} : null,
        version: input['version'],
        idempotencyKey: pending!['requestId'],
        isCurrent: () => active && epoch == _foregroundEpoch);
    if (!active || epoch != _foregroundEpoch) return;
    final value = readOwnership(raw, tenant);
    _matches(value);
    original = value;
    committed = true;
    // A replay may contain a previous state. Read current state separately before displaying it.
    await _query();
  }

  Future<void> _query() async {
    final raw = await api.send(
        'POST', '$path/operation-results/${pending!['requestId']}/query',
        body: pending!['input'], isCurrent: () => active);
    if (!active) return;
    if (raw is! Json ||
        raw['requestId'] != pending!['requestId'] ||
        raw['actorId'] != actor ||
        raw['operation'] != pending!['input']['operation'] ||
        !ownershipRoles.contains(raw['currentRole'])) throw _invalid;
    final before = readOwnership(raw['original'], tenant),
        now = readOwnership(raw['current'], tenant);
    _matches(before);
    for (final k in [
      'id',
      'sourceActorId',
      'targetActorId',
      'sourceMemberVersion',
      'targetMemberVersion',
      'targetRole',
      'formerOwnerRole',
      'tenantVersion',
      'createdAt',
      'expiresAt'
    ]) {
      if (before[k] != now[k]) throw _invalid;
    }
    if (now['version'] < before['version'] ||
        now['updatedAt'] < before['updatedAt'] ||
        (now['version'] == before['version'] &&
            (now['state'] != before['state'] ||
                now['reason'] != before['reason']))) throw _invalid;
    original = before;
    current = now;
    currentRole = raw['currentRole'];
    committed = true;
    queried = true;
  }

  Future<void> recover({bool retry = false}) async {
    if (!active || busy || pending == null) return;
    busy = true;
    error = null;
    _notify();
    try {
      if (retry) {
        await _write(_foregroundEpoch);
      } else {
        await _query();
      }
    } catch (e) {
      if (active) {
        error = e;
        if (e is ParentApiException &&
            const {
              'OWNERSHIP_RESULT_UNAVAILABLE',
              'IDEMPOTENCY_RESPONSE_ERASED'
            }.contains(e.code)) queried = true;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> acknowledge() async {
    if (!active || busy || pending == null || !queried) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await store.clear(tenant, actor, pending!['requestId']);
      if (!active) return false;
      pending = null;
      original = null;
      current = null;
      currentRole = null;
      queried = false;
      committed = false;
      return true;
    } catch (e) {
      if (active) error = e;
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }
}

String ownershipError(Object error) {
  if (error is! ParentApiException) return '$error';
  final message = switch (error.code) {
    'OWNERSHIP_TRANSFER_PENDING' => '已有待确认交接，请先处理现有申请。',
    'OWNERSHIP_TARGET_INELIGIBLE' => '接收人资格已变化，请重新选择有效成人成员。',
    'OWNERSHIP_TRANSFER_UNAVAILABLE' => '申请已结束，请刷新核对最新状态。',
    'OWNERSHIP_RESULT_UNAVAILABLE' => '没有可读的原结果，不能据此判断从未提交。请核对交接记录。',
    'INVALID_OWNERSHIP_RESPONSE' => '交接结果未通过校验，请查询原结果后核对。',
    'IDEMPOTENCY_KEY_CONFLICT' => '原请求内容不匹配，请核对记录并联系管理员。',
    'IDEMPOTENCY_KEY_EXPIRED' => '原请求已过重试期，请查询结果并核对交接记录。',
    _ => error.message
  };
  return error.correlationId == null
      ? message
      : '$message\n问题编号：${error.correlationId}';
}

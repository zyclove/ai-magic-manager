import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
import 'operation_journal.dart';
import 'operation_result_terminal.dart';

const groupOperations = {
  'CREATE': '创建设备组',
  'RENAME': '重命名设备组',
  'ARCHIVE': '归档设备组',
  'ADD': '加入设备组',
  'REMOVE': '移出设备组',
};
const groupMemberStates = {
  'CURRENT': '当前有效',
  'STALE_REGISTRATION': '注册周期已变更',
  'DEVICE_INACTIVE': '设备未启用',
  'PROFILE_ARCHIVED': '儿童档案已归档',
};
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
bool groupUuid(dynamic value) => value is String && _uuid.hasMatch(value);

Json readDeviceGroup(dynamic value, {String? id}) {
  if (value is! Json ||
      !groupUuid(value['id']) ||
      id != null && value['id'] != id ||
      value['name'] is! String ||
      value['name'].isEmpty ||
      value['version'] is! int ||
      value['version'] < 0 ||
      value['deviceCount'] is! int ||
      value['deviceCount'] < 0 ||
      value['deviceCount'] > 5000 ||
      !const {'ACTIVE', 'ARCHIVED'}.contains(value['state'])) {
    throw const ParentApiException(502, 'INVALID_RESPONSE');
  }
  return value;
}

/// Only explicit, bounded registration targets are serialized. No dynamic group selector.
void validateGroupOperation(Json value) {
  final op = value['operation'];
  if (!groupOperations.containsKey(op)) throw const FormatException('设备组操作无效。');
  if (op == 'CREATE') {
    if (value['groupId'] != null || value['version'] != null) {
      throw const FormatException('新建参数无效。');
    }
  } else if (!groupUuid(value['groupId']) ||
      value['version'] is! int ||
      value['version'] < 0) {
    throw const FormatException('请重新读取设备组版本。');
  }
  if (op == 'CREATE' || op == 'RENAME') {
    final name = value['name'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.length > 100 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(name)) {
      throw const FormatException('请填写 1–100 字符的名称，不含控制字符。');
    }
  } else if (value['name'] != null) {
    throw const FormatException('操作包含多余名称。');
  }
  if (op == 'ADD' || op == 'REMOVE') {
    final devices = value['devices'];
    final seen = <String>{};
    if (devices is! List || devices.isEmpty || devices.length > 50) {
      throw const FormatException('每次请选择 1–50 台设备。');
    }
    for (final d in devices) {
      if (d is! Json ||
          !groupUuid(d['deviceId']) ||
          !groupUuid(d['registrationId']) ||
          !seen.add(d['deviceId'])) {
        throw const FormatException('设备注册信息无效或重复，请刷新后选择。');
      }
    }
  } else if (value['devices'] != null) {
    throw const FormatException('操作包含多余设备。');
  }
}

class GroupOperationStore {
  late final ParentOperationJournal journal = ParentOperationJournal(storage);
  final ParentDurableStorage storage;
  GroupOperationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'parent.pending.group_operation.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final raw = await journal.read(key: _key(tenant, actor));
    if (raw == null) return null;
    if (raw.length > 32768) throw const FormatException('设备组恢复记录过大。');
    final value = jsonDecode(raw);
    if (value is! Json ||
        !groupUuid(value['requestId']) ||
        value['body'] is! Json ||
        value['createdAt'] is! int ||
        value['createdAt'] <= 0) {
      throw const FormatException('设备组恢复记录无效，请联系管理员。');
    }
    validateGroupOperation(value['body']);
    return value;
  }

  Future<void> save(String tenant, String actor, Json marker) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对原设备组操作。');
    await journal.write(key: _key(tenant, actor), value: jsonEncode(marker));
  }

  Future<void> remove(String tenant, String actor, String key) async {
    final value = await load(tenant, actor);
    if (value != null && value['requestId'] != key) {
      throw StateError('原操作记录已变化。');
    }
    await journal.delete(key: _key(tenant, actor));
  }
}

/// A durable one-at-a-time command journal. Queries never replay a mutation.
class GroupOperationController extends ChangeNotifier with ParentTerminalOperation {
  @override
  ParentOperationJournal get operationJournal => store.journal;
  @override
  String get operationSlot => store._key(tenant, actor);
  @override
  Json? get operationPayload => pending;
  @override
  bool get operationCurrent => current;
  @override
  bool get operationHasSuccessfulResult => result != null;
  @override
  void forgetOperationPayload() {
    pending = null;
    result = null;
    queried = false;
    loaded = false;
  }
  final ParentApi api;
  final GroupOperationStore store;
  final String tenant, actor;
  final bool Function() isCurrent;
  final Future<bool> Function() reauthenticate;
  bool busy = false, loaded = false, queried = false, _disposed = false;
  Json? pending, result;
  Object? error;
  GroupOperationController(
      {required this.api,
      required this.store,
      required this.tenant,
      required this.actor,
      required this.isCurrent,
      required this.reauthenticate});
  bool get current => !_disposed && isCurrent();
  void changed() {
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
    changed();
    try {
      final value = await store.load(tenant, actor);
      if (current) {
        pending = value;
        result = null;
        queried = false;
        loaded = true;
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (current) error = e;
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> execute(Json input) async {
    if (operationBlocked) return;
    if (!current || busy || !loaded || pending != null) return;
    busy = true;
    error = null;
    result = null;
    queried = false;
    changed();
    try {
      final body = jsonDecode(jsonEncode(input)) as Json;
      validateGroupOperation(body);
      if (!await reauthenticate() || !current) return;
      final marker = <String, dynamic>{
        'requestId': const Uuid().v4(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'body': body
      };
      await store.save(tenant, actor, marker);
      if (!current) return;
      pending = marker;
      final root = '/tenants/$tenant/device-groups';
      final op = body['operation'];
      final path = switch (op) {
        'CREATE' => root,
        'RENAME' => '$root/${body['groupId']}',
        'ARCHIVE' => '$root/${body['groupId']}/archive',
        'ADD' => '$root/${body['groupId']}/devices/batches',
        _ => '$root/${body['groupId']}/devices/removals',
      };
      final payload = switch (op) {
        'CREATE' || 'RENAME' => <String, dynamic>{'name': body['name']},
        'ADD' || 'REMOVE' => <String, dynamic>{'devices': body['devices']},
        _ => null,
      };
      final raw = await api.send(op == 'RENAME' ? 'PATCH' : 'POST', path,
          body: payload,
          version: body['version'],
          idempotencyKey: marker['requestId'],
          isCurrent: () => current, beforeDispatch: operationBeforeWrite);
      if (!current) return;
      final committed = _committed(raw, body);
      result = {'operation': op, 'committed': committed, 'current': committed};
      queried = true;
      if (operationHasSuccessfulResult) await recordSuccessfulOperation();
    } catch (e) {
      await captureResultTerminal(e);
      if (current) {
        error = e;
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      changed();
    }
  }

  Json _committed(dynamic raw, Json input) {
    final value = readDeviceGroup(raw, id: input['groupId']);
    if (input['version'] != null && value['version'] < input['version'] ||
        const {'CREATE', 'RENAME'}.contains(input['operation']) &&
            value['name'] != input['name'] ||
        (input['operation'] == 'ARCHIVE'
            ? value['state'] != 'ARCHIVED'
            : value['state'] != 'ACTIVE')) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return value;
  }

  Future<void> query() async {
    if (operationBlocked) return;
    if (!current || busy || pending == null) return;
    busy = true;
    error = null;
    queried = false;
    result = null;
    changed();
    try {
      final value = await api.send('POST',
          '/tenants/$tenant/device-groups/operation-results/${pending!['requestId']}/query',
          body: pending!['body'], isCurrent: () => current, beforeDispatch: operationBeforeDispatch);
      if (!current) return;
      if (value is! Json ||
          value['operation'] != pending!['body']['operation']) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      final committed = _committed(value['committed'], pending!['body']);
      final now = readDeviceGroup(value['current'], id: committed['id']);
      if (now['version'] < committed['version']) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      result = value;
      queried = true;
      if (operationHasSuccessfulResult) await recordSuccessfulOperation();
    } on ParentApiException catch (e) {
      await captureResultTerminal(e);
      if (current) {
        if (e.status == 404 && e.code == 'DEVICE_GROUP_RESULT_UNAVAILABLE') {
          queried = true;
        } else {
          error = e;
        }
      }
    } catch (e) {
      await captureResultTerminal(e);
      if (current) error = e;
    } finally {
      busy = false;
      changed();
    }
  }

  Future<bool> acknowledge() async {
    if (operationBlocked) return false;
    if (!current || busy || pending == null || !queried) return false;
    busy = true;
    error = null;
    changed();
    try {
      await store.remove(tenant, actor, pending!['requestId']);
      if (!current) return false;
      pending = null;
      queried = false;
      return true;
    } catch (e) {
      await captureResultTerminal(e);
      if (current) error = e;
      return false;
    } finally {
      busy = false;
      changed();
    }
  }
}

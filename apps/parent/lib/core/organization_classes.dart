import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
import 'operation_journal.dart';
import 'operation_result_terminal.dart';

const classOperations = {
  'CREATE',
  'RENAME',
  'ADD',
  'REMOVE',
  'TRANSFER',
  'ARCHIVE'
};
const classOperationLabels = {
  'CREATE': '新建班级',
  'RENAME': '修改名称',
  'ADD': '添加学生',
  'REMOVE': '移出学生',
  'TRANSFER': '转班',
  'ARCHIVE': '归档班级'
};
final _id =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
bool _uuid(dynamic v) => v is String && _id.hasMatch(v);
bool _number(dynamic v, int max) => v is int && v >= 0 && v <= max;
bool _text(dynamic v) => v is String && v.trim().isNotEmpty && v.length <= 100;
const _invalid = ParentApiException(502, 'INVALID_RESPONSE');

Json readSchoolClass(dynamic raw) {
  if (raw is! Json ||
      !_uuid(raw['id']) ||
      !_text(raw['name']) ||
      !const {'ACTIVE', 'ARCHIVED'}.contains(raw['state']) ||
      !_number(raw['version'], 9007199254740991) ||
      !_number(raw['studentCount'], 500) ||
      !_number(raw['createdAt'], 253402300799999) ||
      !_number(raw['updatedAt'], 253402300799999)) throw _invalid;
  return Map<String, dynamic>.unmodifiable(raw);
}

void validateClassStudent(Json raw) {
  if (!_uuid(raw['id']) ||
      !_text(raw['nickname']) ||
      !const {'UNDER_7', 'AGE_7_12', 'AGE_13_17'}.contains(raw['ageBand']) ||
      raw['archived'] is! bool ||
      !_number(raw['addedAt'], 253402300799999)) throw _invalid;
}

/// Stable descriptor is both the recovery query and the source for original write arguments.
void validateClassOperation(Json input, Json? before, Json? target) {
  final op = input['operation'];
  if (!classOperations.contains(op)) throw const FormatException('请选择有效操作。');
  final create = op == 'CREATE', named = op == 'CREATE' || op == 'RENAME';
  final student = const {'ADD', 'REMOVE', 'TRANSFER'}.contains(op),
      transfer = op == 'TRANSFER';
  final fields = {
    'operation',
    if (named) 'name',
    if (!create) ...['classId', 'version'],
    if (student) 'subjectId',
    if (transfer) ...['targetClassId', 'targetVersion']
  };
  if (input.keys.toSet().difference(fields).isNotEmpty ||
      fields.difference(input.keys.toSet()).isNotEmpty ||
      (named && !_text(input['name'])) ||
      (student && !_uuid(input['subjectId']))) {
    throw const FormatException('请检查班级、学生及操作内容。');
  }
  if (create) {
    if (before != null || target != null) throw _invalid;
    return;
  }
  final source = readSchoolClass(before);
  if (source['id'] != input['classId'] ||
      source['version'] != input['version'] ||
      source['state'] != 'ACTIVE') throw _invalid;
  if (transfer) {
    final destination = readSchoolClass(target);
    if (destination['id'] != input['targetClassId'] ||
        destination['version'] != input['targetVersion'] ||
        destination['id'] == source['id'] ||
        destination['state'] != 'ACTIVE') throw _invalid;
  } else if (target != null) {
    throw _invalid;
  }
}

class ClassOperationStore {
  late final ParentOperationJournal journal = ParentOperationJournal(storage);
  final ParentDurableStorage storage;
  ClassOperationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'parent.pending.class.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final value = await journal.read(key: _key(tenant, actor));
    if (value == null) return null;
    if (value.length > 16384) throw const FormatException('班级恢复记录过大。');
    final row = jsonDecode(value);
    if (row is! Json ||
        !_uuid(row['requestId']) ||
        row['input'] is! Json ||
        (row['before'] != null && row['before'] is! Json) ||
        (row['target'] != null && row['target'] is! Json)) {
      throw const FormatException('班级恢复记录损坏，请联系管理员。');
    }
    validateClassOperation(row['input'], row['before'], row['target']);
    return row;
  }

  Future<void> save(String tenant, String actor, Json value) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对上一次班级操作。');
    final encoded = jsonEncode(value);
    if (encoded.length > 16384) throw const FormatException('班级恢复记录过大。');
    await journal.write(key: _key(tenant, actor), value: encoded);
  }

  Future<void> clear(String tenant, String actor, String key) async {
    final row = await load(tenant, actor);
    if (row == null) return;
    if (row['requestId'] != key) throw StateError('恢复记录已变化，请重新读取。');
    await journal.delete(key: _key(tenant, actor));
  }
}

/// Network uncertainty never generates a new request or drops the two transfer versions.
class ClassOperationController extends ChangeNotifier with ParentTerminalOperation {
  @override
  ParentOperationJournal get operationJournal => store.journal;
  @override
  String get operationSlot => store._key(tenant, actor);
  @override
  Json? get operationPayload => pending;
  @override
  bool get operationCurrent => current;
  @override
  bool get operationHasSuccessfulResult => committed != null;
  @override
  void forgetOperationPayload() {
    pending = null;
    committed = null;
    latest = null;
    queried = false;
    loaded = false;
  }
  final ParentApi api;
  final String tenant, actor;
  final ClassOperationStore store;
  final bool Function() isCurrent;
  bool busy = false, loaded = false, queried = false, _disposed = false;
  Json? pending;
  List<Json>? committed, latest;
  Object? error;
  ClassOperationController(
      {required this.api,
      required this.tenant,
      required this.actor,
      required this.store,
      required this.isCurrent});
  bool get current => !_disposed && isCurrent();
  bool get canSubmit => current && loaded && !busy && pending == null;
  String get path => '/tenants/$tenant/classes';
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
        queried = false;
        loaded = true;
      }
    } catch (failure) {
      await captureResultTerminal(failure);
      if (current) error = failure;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> submit(Json input, {Json? before, Json? target}) async {
    if (operationBlocked) return;
    if (!canSubmit) return;
    busy = true;
    error = null;
    _changed();
    try {
      validateClassOperation(input, before, target);
      final row = jsonDecode(jsonEncode({
        'requestId': const Uuid().v4(),
        'input': input,
        'before': before,
        'target': target
      })) as Json;
      await store.save(tenant, actor, row);
      if (!current) return;
      pending = row;
      await _send();
    } catch (failure) {
      await captureResultTerminal(failure);
      if (current) {
        error = failure;
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      _changed();
    }
  }

  List<Json> _validateCommitted(dynamic raw) {
    final p = pending!, input = p['input'] as Json, op = input['operation'];
    if (raw is! List || raw.length != (op == 'TRANSFER' ? 2 : 1)) {
      throw _invalid;
    }
    final rows = raw.map(readSchoolClass).toList();
    final first = rows.first;
    if (op == 'CREATE') {
      if (first['name'] != (input['name'] as String).trim() ||
          first['version'] != 0 ||
          first['state'] != 'ACTIVE' ||
          first['studentCount'] != 0) throw _invalid;
    } else {
      final before = p['before'] as Json;
      if (first['id'] != before['id'] ||
          first['version'] < before['version'] ||
          first['version'] > before['version'] + 1 ||
          first['state'] != (op == 'ARCHIVE' ? 'ARCHIVED' : 'ACTIVE')) {
        throw _invalid;
      }
      if (op == 'RENAME' && first['name'] != (input['name'] as String).trim()) {
        throw _invalid;
      }
      if (op != 'RENAME' && first['name'] != before['name']) throw _invalid;
      final delta = first['studentCount'] - before['studentCount'];
      if ((op == 'ADD' && delta != 0 && delta != 1) ||
          (op == 'REMOVE' && delta != 0 && delta != -1) ||
          (const {'RENAME', 'ARCHIVE'}.contains(op) && delta != 0)) {
        throw _invalid;
      }
      if (op == 'TRANSFER') {
        final target = p['target'] as Json, second = rows.last;
        if (delta != -1 ||
            first['version'] != before['version'] + 1 ||
            second['id'] != target['id'] ||
            second['name'] != target['name'] ||
            second['state'] != 'ACTIVE' ||
            second['version'] < target['version'] ||
            second['version'] > target['version'] + 1 ||
            second['studentCount'] < target['studentCount'] ||
            second['studentCount'] > target['studentCount'] + 1) throw _invalid;
      }
    }
    return rows;
  }

  Future<void> _send() async {
    final p = pending!, input = p['input'] as Json, op = input['operation'];
    String method = 'POST', route = path;
    Json? body;
    switch (op) {
      case 'CREATE':
        body = {'name': input['name']};
      case 'RENAME':
        method = 'PATCH';
        route = '$path/${input['classId']}';
        body = {'name': input['name']};
      case 'ADD':
        route = '$path/${input['classId']}/students';
        body = {'subjectId': input['subjectId']};
      case 'REMOVE':
        method = 'DELETE';
        route = '$path/${input['classId']}/students/${input['subjectId']}';
      case 'ARCHIVE':
        route = '$path/${input['classId']}/archive';
      case 'TRANSFER':
        route =
            '$path/${input['classId']}/students/${input['subjectId']}/transfer';
        body = {
          'targetClassId': input['targetClassId'],
          'targetVersion': input['targetVersion']
        };
    }
    final result = await api.send(method, route,
        body: body,
        version: input['version'],
        idempotencyKey: p['requestId'],
        isCurrent: () => current, beforeDispatch: operationBeforeWrite);
    if (!current) return;
    if (result is! Json) throw _invalid;
    committed = _validateCommitted(
        op == 'TRANSFER' ? [result['source'], result['target']] : [result]);
    if (operationHasSuccessfulResult) await recordSuccessfulOperation();
    await _query();
  }

  Future<void> _query() async {
    final p = pending!;
    try {
      final result = await api.send(
          'POST', '$path/operation-results/${p['requestId']}/query',
          body: p['input'], isCurrent: () => current, beforeDispatch: operationBeforeDispatch);
      if (!current) return;
      if (result is! Json ||
          result['requestId'] != p['requestId'] ||
          result['operation'] != p['input']['operation'] ||
          result['current'] is! List) throw _invalid;
      final original = _validateCommitted(result['committed']);
      final now = (result['current'] as List).map(readSchoolClass).toList();
      if (now.length != original.length) throw _invalid;
      for (var i = 0; i < now.length; i++) {
        if (now[i]['id'] != original[i]['id'] ||
            now[i]['version'] < original[i]['version']) throw _invalid;
      }
      committed = original;
      latest = now;
      queried = true;
      if (operationHasSuccessfulResult) await recordSuccessfulOperation();
    } on ParentApiException catch (failure) {
      await captureResultTerminal(failure);
      if (current &&
          failure.status == 404 &&
          failure.code == 'CLASS_RESULT_UNAVAILABLE') {
        queried = true;
        latest = null;
      } else {
        rethrow;
      }
    }
  }

  Future<void> recover({bool retry = false}) async {
    if (operationBlocked) return;
    if (!current || busy || pending == null || (retry && (committed != null || operationKnownSuccessful))) {
      return;
    }
    busy = true;
    error = null;
    latest = null;
    _changed();
    try {
      if (retry) {
        await _send();
      } else {
        if (operationHasSuccessfulResult) await recordSuccessfulOperation();
        await _query();
      }
    } catch (failure) {
      await captureResultTerminal(failure);
      if (current) error = failure;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<bool> acknowledge() async {
    if (operationBlocked) return false;
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
      queried = false;
      return true;
    } catch (failure) {
      await captureResultTerminal(failure);
      if (current) error = failure;
      return false;
    } finally {
      busy = false;
      _changed();
    }
  }
}

String classFailure(Object error) => error is ParentApiException
    ? switch (error.code) {
        'CLASS_CAPACITY_REACHED' => '班级已达到 500 人上限，请选择其他班级。',
        'CLASS_ARCHIVED' => '班级已归档，请核对原操作并刷新列表。',
        'CLASS_STUDENT_NOT_ENROLLED' => '学生已不在原班级，请刷新名册。',
        'CLASS_TRANSFER_SAME_TARGET' => '请选择不同的目标班级。',
        'IDEMPOTENCY_KEY_EXPIRED' => '原请求已超过重试期限，请查询结果并核对名册。',
        _ => error.toString(),
      }
    : error.toString();

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

final _id =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
bool _uuid(dynamic value) => value is String && _id.hasMatch(value);
bool _text(dynamic value, int max) =>
    value is String && value.trim().isNotEmpty && value.length <= max;
bool _integer(dynamic value, int min, int max) =>
    value is int && value >= min && value <= max;
const _invalid = ParentApiException(502, 'INVALID_RESPONSE');

bool quotaDate(dynamic value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return false;
  }
  final date = DateTime.tryParse('${value}T00:00:00Z');
  return date != null &&
      date.year >= 1900 &&
      date.year <= 2200 &&
      date.toIso8601String().substring(0, 10) == value;
}

/// Validate ledger arithmetic before drawing balances; zero is never a fallback for missing data.
Json readQuota(dynamic raw) {
  if (raw is! Json ||
      !_uuid(raw['id']) ||
      !_uuid(raw['subjectId']) ||
      !_text(raw['name'], 100) ||
      !_text(raw['timeZone'], 100) ||
      !quotaDate(raw['periodId']) ||
      !const {'TOTAL', 'APPLICATION'}.contains(raw['scope']) ||
      (raw['scope'] == 'TOTAL'
          ? raw['applicationId'] != null
          : !_uuid(raw['applicationId'])) ||
      !_integer(raw['version'], 0, 9007199254740991) ||
      !_integer(raw['periodStart'], 0, 9007199254740991) ||
      !_integer(raw['periodEnd'], 1, 9007199254740991) ||
      raw['periodStart'] >= raw['periodEnd'] ||
      raw['status'] != 'CONFIGURED' ||
      raw['evidenceStatus'] != 'LEDGER_ONLY') throw _invalid;
  for (final key in [
    'limitSeconds',
    'usedSeconds',
    'reservedSeconds',
    'availableSeconds'
  ]) {
    if (!_integer(raw[key], 0, 86400)) throw _invalid;
  }
  if (raw['limitSeconds'] !=
      raw['usedSeconds'] + raw['reservedSeconds'] + raw['availableSeconds']) {
    throw _invalid;
  }
  return Map<String, dynamic>.unmodifiable(raw);
}

String quotaTime(int seconds) => seconds % 60 == 0
    ? '${seconds ~/ 60} 分钟'
    : '${seconds ~/ 60} 分 ${seconds % 60} 秒';

void validateQuotaEntity(Json row, {required bool subject}) {
  if (!_uuid(row['id']) ||
      !_text(row[subject ? 'nickname' : 'displayName'], 100) ||
      (!subject &&
          (!_text(row['packageName'], 255) || !_text(row['profile'], 100)))) {
    throw _invalid;
  }
}

void validateQuotaLedger(Json row) {
  if (!_uuid(row['id']) ||
      !_text(row['kind'], 80) ||
      !_integer(row['occurredAt'], 0, 253402300799999)) throw _invalid;
  for (final key in ['limitDelta', 'usedDelta', 'reservedDelta']) {
    if (!_integer(row[key], -86400, 86400)) throw _invalid;
  }
}

String quotaDelta(int seconds) =>
    '${seconds > 0 ? '+' : seconds < 0 ? '−' : ''}${quotaTime(seconds.abs())}';

void validateQuotaInput(String operation, Json body, Json? before) {
  if (operation == 'CREATE') {
    if (!_text(body['name'], 100) ||
        !_uuid(body['subjectId']) ||
        !const {'TOTAL', 'APPLICATION'}.contains(body['scope']) ||
        (body['scope'] == 'TOTAL'
            ? body['applicationId'] != null
            : !_uuid(body['applicationId'])) ||
        !quotaDate(body['periodId']) ||
        !_text(body['timeZone'], 100) ||
        !_integer(body['limitSeconds'], 0, 86400) ||
        before != null) throw const FormatException('请检查儿童、日期和额度。');
  } else if (operation == 'ADJUST') {
    if (before == null) throw _invalid;
    readQuota(before);
    if (!_integer(body['deltaSeconds'], -86400, 86400) ||
        body['deltaSeconds'] == 0 ||
        !const {'EXTRA_TIME', 'CORRECTION'}.contains(body['reason']) ||
        (body['reason'] == 'EXTRA_TIME' && body['deltaSeconds'] < 0)) {
      throw const FormatException('请输入有效的增减额度。');
    }
    final next = before['limitSeconds'] + body['deltaSeconds'];
    if (next > 86400 ||
        next < before['usedSeconds'] + before['reservedSeconds']) {
      throw const FormatException('调整后须覆盖已结算和待确认预留，总额不超过 1440 分钟。');
    }
  } else {
    throw _invalid;
  }
}

class QuotaOperationStore {
  final ParentDurableStorage storage;
  QuotaOperationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'parent.pending.quota.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final text = await storage.read(key: _key(tenant, actor));
    if (text == null) return null;
    if (text.length > 16384) throw const FormatException('额度恢复记录过大。');
    final value = jsonDecode(text);
    if (value is! Json ||
        !_uuid(value['requestId']) ||
        value['operation'] is! String ||
        value['body'] is! Json ||
        (value['before'] != null && value['before'] is! Json) ||
        !_integer(value['createdAt'], 1, 9007199254740991)) {
      throw const FormatException('额度恢复记录损坏，请联系管理员。');
    }
    validateQuotaInput(value['operation'], value['body'], value['before']);
    return value;
  }

  Future<void> save(String tenant, String actor, Json value) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对原额度操作。');
    final encoded = jsonEncode(value);
    if (encoded.length > 16384) throw const FormatException('额度恢复记录过大。');
    await storage.write(key: _key(tenant, actor), value: encoded);
  }

  Future<void> remove(String tenant, String actor, String requestId) async {
    final value = await load(tenant, actor);
    if (value == null) return;
    if (value['requestId'] != requestId) throw StateError('待核对记录已变化，请重新读取。');
    await storage.delete(key: _key(tenant, actor));
  }
}

/// Explicit same-request retries retain the original key and version. No automatic retry occurs.
class QuotaOperationController extends ChangeNotifier {
  final ParentApi api;
  final QuotaOperationStore store;
  final String tenant, actor;
  final bool Function() isCurrent;
  bool busy = false, loaded = false, queried = false, _disposed = false;
  Json? pending, committed, latest;
  Object? error;
  QuotaOperationController(
      {required this.api,
      required this.store,
      required this.tenant,
      required this.actor,
      required this.isCurrent});
  bool get current => !_disposed && isCurrent();
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
      final value = await store.load(tenant, actor);
      if (current) {
        pending = value;
        committed = null;
        latest = null;
        queried = false;
        loaded = true;
      }
    } catch (failure) {
      if (current) error = failure;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> submit(String operation, Json body, {Json? before}) async {
    if (!current || busy || !loaded || pending != null) return;
    busy = true;
    error = null;
    _changed();
    try {
      validateQuotaInput(operation, body, before);
      final value = jsonDecode(jsonEncode({
        'requestId': const Uuid().v4(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'operation': operation,
        'body': body,
        'before': before
      })) as Json;
      await store.save(tenant, actor, value);
      if (!current) return;
      pending = value;
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

  String get _path => '/tenants/$tenant/quota-pools';
  Json _checkCommitted(dynamic raw) {
    final result = readQuota(raw), body = pending!['body'] as Json;
    if (pending!['operation'] == 'CREATE') {
      for (final key in [
        'subjectId',
        'scope',
        'applicationId',
        'periodId',
        'timeZone',
        'limitSeconds'
      ]) {
        if (result[key] != body[key]) throw _invalid;
      }
      if (result['name'] != (body['name'] as String).trim() ||
          result['version'] != 0) throw _invalid;
    } else {
      final before = pending!['before'] as Json;
      for (final key in [
        'id',
        'subjectId',
        'scope',
        'applicationId',
        'periodId',
        'timeZone'
      ]) {
        if (result[key] != before[key]) throw _invalid;
      }
      if (result['version'] != before['version'] + 1 ||
          result['limitSeconds'] !=
              before['limitSeconds'] + body['deltaSeconds']) throw _invalid;
    }
    return result;
  }

  Future<void> _send() async {
    final p = pending!, before = p['before'] as Json?;
    final raw = await api.send(
        'POST', before == null ? _path : '$_path/${before['id']}/adjustments',
        body: p['body'],
        version: before?['version'],
        idempotencyKey: p['requestId'],
        isCurrent: () => current);
    if (!current) return;
    committed = _checkCommitted(raw);
    await _query();
  }

  Future<void> retry() async {
    if (!current || busy || pending == null || committed != null) return;
    busy = true;
    error = null;
    _changed();
    try {
      await _send();
    } catch (failure) {
      if (current) error = failure;
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> _query() async {
    final p = pending!, before = p['before'] as Json?;
    final path = before == null
        ? '$_path/creation-results/${p['requestId']}/query'
        : '$_path/${before['id']}/adjustment-results/${p['requestId']}/query';
    try {
      final raw = await api.send('POST', path,
          body: p['body'],
          version: before?['version'],
          isCurrent: () => current);
      if (!current) return;
      if (raw is! Json ||
          raw['requestId'] != p['requestId'] ||
          raw['operation'] != p['operation']) throw _invalid;
      final original = _checkCommitted(raw['committed']),
          now = readQuota(raw['current']);
      for (final key in [
        'id',
        'subjectId',
        'scope',
        'applicationId',
        'periodId',
        'timeZone'
      ]) {
        if (now[key] != original[key]) throw _invalid;
      }
      if (now['version'] < original['version']) throw _invalid;
      committed = original;
      latest = now;
      queried = true;
    } on ParentApiException catch (failure) {
      if (current &&
          failure.status == 404 &&
          failure.code == 'QUOTA_RESULT_UNAVAILABLE') {
        queried = true;
        latest = null;
      } else {
        rethrow;
      }
    }
  }

  Future<void> query() async {
    if (!current || busy || pending == null) return;
    busy = true;
    error = null;
    latest = null;
    _changed();
    try {
      await _query();
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
      await store.remove(tenant, actor, pending!['requestId']);
      if (!current) return false;
      pending = null;
      committed = null;
      latest = null;
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

String quotaFailure(Object failure) => failure is ParentApiException
    ? switch (failure.code) {
        'QUOTA_BALANCE_CONFLICT' => '余额已变化，减少后不能低于已结算与预留之和。请先核对原操作，再读取最新额度。',
        'QUOTA_PERIOD_CLOSED' ||
        'QUOTA_PERIOD_UNAVAILABLE' =>
          '该日期已结束或超出可设置范围，请核对原操作。',
        'QUOTA_POOL_EXISTS' => '该儿童、日期和应用范围已有额度，请先查看现有账本。',
        'QUOTA_TIME_ZONE_LOCKED' => '额度时区已经确定，请重新选择儿童以读取当前时区。',
        'QUOTA_SCOPE_ALREADY_USED' => '该日期已有使用记录，不能补建会重置使用约束的额度。请核对账本。',
        'QUOTA_RESULT_UNAVAILABLE' => '未找到原操作结果，请核对账本；这不代表从未提交。',
        'IDEMPOTENCY_KEY_EXPIRED' => '原请求已超过重试期限，请查询原结果并核对账本。',
        _ => failure.toString(),
      }
    : failure.toString();

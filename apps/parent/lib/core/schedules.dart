import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

const scheduleDays = [
  'MONDAY',
  'TUESDAY',
  'WEDNESDAY',
  'THURSDAY',
  'FRIDAY',
  'SATURDAY',
  'SUNDAY'
];
const scheduleDayNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _time = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');

/// Shape and calendar validation only. IANA/DST evaluation belongs to java.time.
void validateScheduleDefinition(dynamic definition) {
  if (definition is! Json ||
      definition['timeZone'] is! String ||
      (definition['timeZone'] as String).trim().isEmpty ||
      (definition['timeZone'] as String).length > 100 ||
      definition['weekly'] is! List ||
      (definition['weekly'] as List).length > 56 ||
      definition['exceptions'] is! List ||
      (definition['exceptions'] as List).length > 366) {
    throw const FormatException('时间计划格式异常，请检查时区、每周时段和例外日期。');
  }
  void window(dynamic row) {
    if (row is! Json ||
        row['start'] is! String ||
        row['end'] is! String ||
        !_time.hasMatch(row['start']) ||
        !_time.hasMatch(row['end']) ||
        row['start'] == row['end']) {
      throw const FormatException('起止时间必须不同，并使用 24 小时制的时:分。');
    }
  }

  for (final row in definition['weekly']) {
    window(row);
    if (!scheduleDays.contains(row['day'])) {
      throw const FormatException('星期选项无效。');
    }
  }
  final dates = <String>{};
  for (final row in definition['exceptions']) {
    if (row is! Json ||
        row['date'] is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(row['date']) ||
        row['windows'] is! List ||
        (row['windows'] as List).length > 8) {
      throw const FormatException('例外日期或时段格式无效。');
    }
    final date = DateTime.tryParse('${row['date']}T00:00:00Z');
    if (date == null ||
        date.year < 1900 ||
        date.year > 2200 ||
        date.toIso8601String().substring(0, 10) != row['date'] ||
        !dates.add(row['date'])) throw const FormatException('例外日期无效或重复。');
    for (final value in row['windows']) {
      window(value);
    }
  }
}

Json readSchedule(dynamic raw) {
  if (raw is! Json ||
      raw['id'] is! String ||
      !_uuid.hasMatch(raw['id']) ||
      raw['name'] is! String ||
      raw['name'].isEmpty ||
      raw['name'].length > 100) {
    throw const ParentApiException(502, 'INVALID_RESPONSE');
  }
  validateScheduleDefinition(raw['definition']);
  return raw;
}

String scheduleWindowLabel(Json row) =>
    '${row['start']}–${(row['end'] as String).compareTo(row['start']) < 0 ? '次日 ' : ''}${row['end']}';

void validateScheduleDecision(Json result, String zone, DateTime at) {
  bool futureInstant(dynamic value) {
    final date = value is String ? DateTime.tryParse(value) : null;
    return date != null && date.isUtc && date.isAfter(at);
  }

  if (result['allowed'] is! bool ||
      result['timeZone'] != zone ||
      result['previewDays'] != 8 ||
      result['localDate'] is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(result['localDate']) ||
      (result['allowed'] == true
          ? result['reasonCode'] != 'WITHIN_ALLOWED_WINDOW' ||
              !futureInstant(result['currentUntil']) ||
              result['nextAllowedAt'] != null
          : result['currentUntil'] != null ||
              !const {'OUTSIDE_ALLOWED_WINDOW', 'NO_WINDOW_IN_PREVIEW_HORIZON'}
                  .contains(result['reasonCode']) ||
              (result['reasonCode'] == 'OUTSIDE_ALLOWED_WINDOW'
                  ? !futureInstant(result['nextAllowedAt'])
                  : result['nextAllowedAt'] != null))) {
    throw const ParentApiException(502, 'INVALID_RESPONSE');
  }
}

class ScheduleCreationStore {
  final ParentDurableStorage storage;
  ScheduleCreationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'parent.pending.schedule_creation.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final raw = await storage.read(key: _key(tenant, actor));
    if (raw == null) return null;
    if (raw.length > 512 * 1024) {
      throw const FormatException('时间计划恢复记录过大，请联系管理员。');
    }
    final value = jsonDecode(raw);
    if (value is! Json ||
        value['requestId'] is! String ||
        !_uuid.hasMatch(value['requestId']) ||
        value['createdAt'] is! int ||
        value['createdAt'] <= 0 ||
        value['body'] is! Json ||
        value['body']['name'] is! String ||
        value['body']['name'].trim().isEmpty ||
        value['body']['name'].length > 100) {
      throw const FormatException('时间计划恢复记录无法读取，请联系管理员。');
    }
    validateScheduleDefinition(value['body']['definition']);
    return value;
  }

  Future<void> save(String tenant, String actor, Json value) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对原时间计划创建。');
    final encoded = jsonEncode(value);
    if (encoded.length > 512 * 1024) throw const FormatException('时间计划过大。');
    await storage.write(key: _key(tenant, actor), value: encoded);
  }

  Future<void> remove(String tenant, String actor, String requestId) async {
    final item = await load(tenant, actor);
    if (item == null) return;
    if (item['requestId'] != requestId) throw StateError('恢复记录已变化，请重新读取。');
    await storage.delete(key: _key(tenant, actor));
  }
}

/// Immutable schedule creation, with durable pre-send journaling and read-only recovery.
class ScheduleCreationController extends ChangeNotifier {
  final ParentApi api;
  final ScheduleCreationStore store;
  final String tenant, actor;
  final bool Function() isCurrent;
  Json? pending, result;
  Object? error;
  bool busy = false, loaded = false, queried = false, _disposed = false;
  ScheduleCreationController(
      {required this.api,
      required this.store,
      required this.tenant,
      required this.actor,
      required this.isCurrent});
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
      final item = await store.load(tenant, actor);
      if (current) {
        pending = item;
        result = null;
        queried = false;
        loaded = true;
      }
    } catch (failure) {
      if (current) error = failure;
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> create(String name, Json definition) async {
    if (!current || busy || !loaded || pending != null) return;
    busy = true;
    error = null;
    result = null;
    queried = false;
    changed();
    try {
      validateScheduleDefinition(definition);
      if (name.trim().isEmpty || name.trim().length > 100) {
        throw const FormatException('请填写不超过 100 字符的名称。');
      }
      final body = jsonDecode(
          jsonEncode({'name': name.trim(), 'definition': definition})) as Json;
      final item = <String, dynamic>{
        'requestId': const Uuid().v4(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'body': body
      };
      await store.save(tenant, actor, item);
      if (!current) return;
      pending = item;
      final raw = await api.send('POST', '/tenants/$tenant/schedules',
          body: body,
          idempotencyKey: item['requestId'],
          isCurrent: () => current);
      if (!current) return;
      result = _originalResult(raw, body);
      queried = true;
    } catch (failure) {
      if (current) {
        error = failure;
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> query() async {
    if (!current || busy || pending == null) return;
    busy = true;
    error = null;
    result = null;
    queried = false;
    changed();
    try {
      final raw = await api.send('POST',
          '/tenants/$tenant/schedules/creation-results/${pending!['requestId']}/query',
          body: pending!['body'] as Json, isCurrent: () => current);
      if (!current) return;
      result = _originalResult(raw, pending!['body'] as Json);
      queried = true;
    } on ParentApiException catch (failure) {
      if (current) {
        if (failure.status == 404 &&
            failure.code == 'SCHEDULE_CREATION_RESULT_UNAVAILABLE') {
          queried = true;
        } else {
          error = failure;
        }
      }
    } catch (failure) {
      if (current) error = failure;
    } finally {
      busy = false;
      changed();
    }
  }

  Future<bool> acknowledge() async {
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
    } catch (failure) {
      if (current) error = failure;
      return false;
    } finally {
      busy = false;
      changed();
    }
  }

  Json _originalResult(dynamic raw, Json original) {
    final entry = readSchedule(raw);
    if (entry['name'] != original['name'] ||
        !const DeepCollectionEquality()
            .equals(entry['definition'], original['definition'])) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return entry;
  }
}

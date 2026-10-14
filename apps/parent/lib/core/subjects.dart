import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

const subjectAges = {
  'UNDER_7': '7 岁以下',
  'AGE_7_12': '7–12 岁',
  'AGE_13_17': '13–17 岁'
};
const subjectOperations = {
  'CREATE': '添加档案',
  'UPDATE': '修改档案',
  'ARCHIVE': '归档档案'
};
bool subjectIdValid(dynamic value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);
bool subjectNameValid(dynamic value) =>
    value is String &&
    value.trim().isNotEmpty &&
    value == value.trim() &&
    value.length <= 60 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f\u00ad\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]')
        .hasMatch(value);

void validateSubjectChange(Json value) {
  final op = value['operation'];
  if (!subjectOperations.containsKey(op) ||
      value.keys.any((k) => !{
            'operation',
            'subjectId',
            'version',
            'nickname',
            'ageBand'
          }.contains(k))) {
    throw const FormatException('档案操作无效。');
  }
  if (op == 'CREATE') {
    if (value['subjectId'] != null || value['version'] != null) {
      throw const FormatException('新建参数无效。');
    }
  } else if (!subjectIdValid(value['subjectId']) ||
      value['version'] is! int ||
      value['version'] < 0 ||
      value['version'] >= 9007199254740991) {
    throw const FormatException('请重新读取档案版本。');
  }
  if (op == 'ARCHIVE') {
    if (value['nickname'] != null || value['ageBand'] != null) {
      throw const FormatException('归档参数无效。');
    }
  } else if (!subjectNameValid(value['nickname']) ||
      !subjectAges.containsKey(value['ageBand'])) {
    throw const FormatException('请填写 1–60 字的昵称并选择年龄段，不含控制字符。');
  }
}

Json readSubject(dynamic value, {String? id}) {
  if (value is! Json ||
      !subjectIdValid(value['id']) ||
      id != null && value['id'] != id ||
      value['nickname'] is! String ||
      value['nickname'].isEmpty ||
      !subjectAges.containsKey(value['ageBand']) ||
      value['version'] is! int ||
      value['version'] < 0 ||
      value['version'] > 9007199254740991 ||
      !{'ACTIVE', 'ARCHIVED'}.contains(value['state'])) {
    throw const ParentApiException(502, 'INVALID_RESPONSE');
  }
  return value;
}

/// Per-adult/workspace encrypted journal. Persist before dispatch; never replay automatically.
class SubjectChangeStore {
  final ParentDurableStorage storage;
  SubjectChangeStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'parent.pending.subject.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final raw = await storage.read(key: _key(tenant, actor));
    if (raw == null) return null;
    if (raw.length > 8192) throw const FormatException('档案恢复记录过大。');
    final v = jsonDecode(raw);
    if (v is! Json ||
        !subjectIdValid(v['requestId']) ||
        v['body'] is! Json ||
        v['createdAt'] is! int ||
        v['createdAt'] <= 0) {
      throw const FormatException('档案恢复记录无法识别，请联系管理员。');
    }
    validateSubjectChange(v['body']);
    return v;
  }

  Future<void> save(String tenant, String actor, Json marker) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对原档案操作。');
    await storage.write(key: _key(tenant, actor), value: jsonEncode(marker));
  }

  Future<void> remove(String tenant, String actor, String request) async {
    final saved = await load(tenant, actor);
    if (saved != null && saved['requestId'] != request) {
      throw StateError('原操作记录已变化。');
    }
    await storage.delete(key: _key(tenant, actor));
  }
}

class SubjectChangeController extends ChangeNotifier {
  final ParentApi api;
  final SubjectChangeStore store;
  final String tenant, actor;
  final bool Function() isCurrent, foreground;
  final Future<bool> Function() reauthenticate;
  bool busy = false, loaded = false, queried = false, _disposed = false;
  int _generation = 0;
  Json? pending, result;
  Object? error;
  SubjectChangeController(
      {required this.api,
      required this.store,
      required this.tenant,
      required this.actor,
      required this.isCurrent,
      required this.foreground,
      required this.reauthenticate});
  bool get available => !_disposed && isCurrent() && foreground();
  String get root => '/tenants/$tenant/subjects';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _valid(int g) => available && g == _generation;
  Future<void> load() async {
    if (!available || busy) return;
    final g = ++_generation;
    busy = true;
    loaded = false;
    queried = false;
    result = null;
    error = null;
    _notify();
    try {
      final marker = await store.load(tenant, actor);
      if (_valid(g)) {
        pending = marker;
        loaded = true;
      }
    } catch (e) {
      if (_valid(g)) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  Json _committed(dynamic raw, Json body) {
    final v = readSubject(raw, id: body['subjectId']);
    if (v['version'] !=
            (body['operation'] == 'CREATE' ? 0 : body['version'] + 1) ||
        (body['operation'] == 'ARCHIVE'
            ? v['state'] != 'ARCHIVED'
            : v['state'] != 'ACTIVE' ||
                v['nickname'] != body['nickname'] ||
                v['ageBand'] != body['ageBand'])) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return v;
  }

  Future<void> execute(Json input) async {
    if (!available || busy || !loaded || pending != null) return;
    busy = true;
    error = null;
    result = null;
    queried = false;
    _notify();
    try {
      final body = jsonDecode(jsonEncode(input)) as Json;
      validateSubjectChange(body);
      if (!await reauthenticate() || !available) return;
      final g = _generation;
      if (body['operation'] != 'CREATE') {
        final now = readSubject(
            await api.send('GET', '$root/${body['subjectId']}/management',
                isCurrent: () => _valid(g)),
            id: body['subjectId']);
        if (!_valid(g)) return;
        if (now['state'] != 'ACTIVE' || now['version'] != body['version']) {
          throw const ParentApiException(412, 'RESOURCE_VERSION_CONFLICT');
        }
      }
      final marker = <String, dynamic>{
        'requestId': const Uuid().v4(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'body': body
      };
      await store.save(tenant, actor, marker);
      if (!_valid(g)) return;
      pending = marker;
      loaded = false;
      _notify();
      final raw = await api.send('POST', '$root/changes',
          body: body,
          idempotencyKey: marker['requestId'],
          isCurrent: () => _valid(g));
      if (!_valid(g)) return;
      _committed(raw, body);
      await _recover(g);
    } catch (e) {
      if (available) {
        error = e;
        loaded = false;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _recover(int g) async {
    final marker = pending!;
    final raw = await api.send(
        'POST', '$root/operation-results/${marker['requestId']}/query',
        body: marker['body'], isCurrent: () => _valid(g));
    if (!_valid(g)) return;
    if (raw is! Json || raw['operation'] != marker['body']['operation']) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    final committed = _committed(raw['committed'], marker['body']);
    final current = readSubject(raw['current'], id: committed['id']);
    if (current['version'] < committed['version'] ||
        current['version'] == committed['version'] &&
            ['nickname', 'ageBand', 'state']
                .any((key) => current[key] != committed[key]) ||
        committed['state'] == 'ARCHIVED' && current['state'] != 'ARCHIVED') {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    result = {
      'operation': raw['operation'],
      'committed': committed,
      'current': current
    };
    queried = true;
  }

  Future<void> query() async {
    if (!available || busy || pending == null) return;
    final g = ++_generation;
    busy = true;
    error = null;
    result = null;
    queried = false;
    _notify();
    try {
      await _recover(g);
    } on ParentApiException catch (e) {
      if (_valid(g)) {
        error = e;
        queried = (e.status == 404 && e.code == 'SUBJECT_RESULT_UNAVAILABLE') ||
            (e.status == 410 && e.code == 'IDEMPOTENCY_RESPONSE_ERASED');
      }
    } catch (e) {
      if (_valid(g)) error = e;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> acknowledge() async {
    if (!available || busy || !queried || pending == null) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await store.remove(tenant, actor, pending!['requestId']);
      if (!available) return false;
      pending = null;
      result = null;
      queried = false;
      loaded = false;
      return true;
    } catch (e) {
      if (available) error = e;
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  void hide() {
    _generation++;
    result = null;
    error = null;
    loaded = false;
    queried = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}

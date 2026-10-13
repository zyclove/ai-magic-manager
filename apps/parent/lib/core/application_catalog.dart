import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:usage_reporting/usage_reporting.dart';
import 'package:uuid/uuid.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';
export 'package:usage_reporting/usage_reporting.dart'
    show ApplicationClassification, applicationCategories;

const appPlatforms = {'ANDROID': 'Android 手机/平板', 'ANDROID_TV': 'Android TV'};
const appProfiles = {
  'PRIMARY': '主资料',
  'WORK': '工作资料',
  'SECONDARY': '其他用户资料',
  'UNKNOWN': '资料未知'
};
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
bool _validId(dynamic id) => id is String && _uuid.hasMatch(id);
ApplicationClassificationIdentity appIdentity(Json app) =>
    ApplicationClassificationIdentity(
        app['platform'], app['profile'], app['packageName']);
void validateApplication(Json value) {
  if (value['displayName'] is! String ||
      value['displayName'].trim().isEmpty ||
      value['displayName'].length > 100 ||
      value['platform'] is! String ||
      value['profile'] is! String ||
      value['packageName'] is! String ||
      !appIdentity(value).valid ||
      value['signingDigests'] is! List ||
      value['signingDigests'].length > 8) {
    throw const FormatException('请核对名称、平台、资料、包名和签名摘要。');
  }
  final seen = <String>{};
  for (final digest in value['signingDigests']) {
    if (digest is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        !seen.add(digest)) {
      throw const FormatException('每份签名须为不重复的 SHA-256 摘要（64 位十六进制），最多 8 份。');
    }
  }
}

Json readApplication(dynamic value, {String? id}) {
  if (value is! Json ||
      !_validId(value['id']) ||
      id != null && value['id'] != id ||
      value['evidenceStatus'] != 'ADMIN_DECLARED') {
    throw const ParentApiException(502, 'INVALID_RESPONSE');
  }
  validateApplication(value);
  return value;
}

ApplicationClassification readClassification(dynamic value, Json app) {
  try {
    return ApplicationClassification.parse(value, appIdentity(app));
  } on UsageReportFailure catch (e) {
    throw ParentApiException(e.status, e.code);
  }
}

void _validateOperation(Json value) {
  if (value['operation'] == 'DECLARE' && value['definition'] is Json) {
    validateApplication(value['definition']);
  } else if (value['operation'] == 'CLASSIFY' &&
      value['application'] is Json &&
      value['version'] is int &&
      value['version'] >= 0 &&
      value['version'] < 9007199254740991 &&
      applicationCategories.containsKey(value['category'])) {
    readApplication(value['application']);
  } else {
    throw const FormatException('应用目录操作记录无效。');
  }
}

class CatalogOperationStore {
  final ParentDurableStorage storage;
  CatalogOperationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'parent.pending.catalog_operation.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final raw = await storage.read(key: _key(tenant, actor));
    if (raw == null) return null;
    if (raw.length > 16384) throw const FormatException('应用恢复记录过大。');
    final value = jsonDecode(raw);
    if (value is! Json ||
        !_validId(value['requestId']) ||
        value['body'] is! Json ||
        value['createdAt'] is! int ||
        value['createdAt'] <= 0) {
      throw const FormatException('应用恢复记录无法读取，请联系管理员。');
    }
    _validateOperation(value['body']);
    return value;
  }

  Future<void> save(String tenant, String actor, Json value) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对原应用目录操作。');
    await storage.write(key: _key(tenant, actor), value: jsonEncode(value));
  }

  Future<void> remove(String tenant, String actor, String requestId) async {
    final previous = await load(tenant, actor);
    if (previous != null && previous['requestId'] != requestId) {
      throw StateError('待核对记录已变化。');
    }
    await storage.delete(key: _key(tenant, actor));
  }
}

/// Exact declaration/classification recovery. No automatic cross-session replay.
class CatalogOperationController extends ChangeNotifier {
  final ParentApi api;
  final CatalogOperationStore store;
  final String tenant, actor;
  final bool Function() isCurrent;
  bool busy = false, loaded = false, queried = false, _disposed = false;
  Json? pending, result;
  Object? error;
  CatalogOperationController(
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
      final value = await store.load(tenant, actor);
      if (current) {
        pending = value;
        result = null;
        queried = false;
        loaded = true;
      }
    } catch (e) {
      if (current) error = e;
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> execute(Json input) async {
    if (!current || busy || !loaded || pending != null) return;
    busy = true;
    error = null;
    result = null;
    queried = false;
    changed();
    try {
      final body = jsonDecode(jsonEncode(input)) as Json;
      _validateOperation(body);
      final marker = <String, dynamic>{
        'requestId': const Uuid().v4(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        'body': body
      };
      await store.save(tenant, actor, marker);
      if (!current) return;
      pending = marker;
      final declare = body['operation'] == 'DECLARE';
      final root = '/tenants/$tenant/applications';
      final raw = await api.send(declare ? 'POST' : 'PUT',
          declare ? root : '$root/${body['application']['id']}/classification',
          body: declare ? body['definition'] : {'category': body['category']},
          version: declare ? null : body['version'],
          idempotencyKey: marker['requestId'],
          isCurrent: () => current);
      if (!current) return;
      result =
          _result(body, declare ? raw : {'committed': raw, 'current': raw});
      queried = true;
    } catch (e) {
      if (current) {
        error = e;
        if (pending == null) loaded = false;
      }
    } finally {
      busy = false;
      changed();
    }
  }

  Json _result(Json body, dynamic raw) {
    if (body['operation'] == 'DECLARE') {
      final app = readApplication(raw);
      final expected = body['definition'] as Json;
      final digests = List<String>.from(expected['signingDigests'])..sort();
      if (app['displayName'] != expected['displayName'] ||
          !appIdentity(expected).matches({
            'platform': app['platform'],
            'profile': app['profile'],
            'packageName': app['packageName']
          }) ||
          !const ListEquality<String>()
              .equals(List<String>.from(app['signingDigests']), digests)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      return {'application': app};
    }
    if (raw is! Json) throw const ParentApiException(502, 'INVALID_RESPONSE');
    final app = body['application'] as Json;
    final committed = readClassification(raw['committed'], app),
        now = readClassification(raw['current'], app);
    if (committed.version != body['version'] + 1 ||
        committed.category != body['category'] ||
        now.version < committed.version) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return {
      'application': app,
      'committed': raw['committed'],
      'current': raw['current']
    };
  }

  Future<void> query() async {
    if (!current || busy || pending == null) return;
    busy = true;
    queried = false;
    result = null;
    error = null;
    changed();
    final body = pending!['body'] as Json;
    final declare = body['operation'] == 'DECLARE';
    try {
      final root = '/tenants/$tenant/applications';
      final key = pending!['requestId'];
      final raw = await api.send(
          'POST',
          declare
              ? '$root/creation-results/$key/query'
              : '$root/${body['application']['id']}/classification/operation-results/$key/query',
          body: declare
              ? body['definition']
              : {'version': body['version'], 'category': body['category']},
          isCurrent: () => current);
      if (current) {
        result = _result(body, raw);
        queried = true;
      }
    } on ParentApiException catch (e) {
      if (current) {
        if (e.status == 404 &&
            e.code ==
                (declare
                    ? 'APPLICATION_CREATION_RESULT_UNAVAILABLE'
                    : 'CLASSIFICATION_RESULT_UNAVAILABLE')) {
          queried = true;
        } else {
          error = e;
        }
      }
    } catch (e) {
      if (current) error = e;
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
    } catch (e) {
      if (current) error = e;
      return false;
    } finally {
      busy = false;
      changed();
    }
  }
}

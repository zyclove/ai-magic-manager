import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'parent_api.dart';
import 'parent_durable_storage.dart';

final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// Original request metadata only; no tokens, device inventories or rule bodies.
/// The title is encrypted locally and sent in a POST body, never a query string.
class PendingPolicyCreation {
  final String requestId, name, kind;
  final String? templateId;
  final int? templateRevision;
  final int createdAt;
  const PendingPolicyCreation(
      {required this.requestId,
      required this.name,
      required this.kind,
      required this.createdAt,
      this.templateId,
      this.templateRevision});
  String get operation => templateId == null ? 'EMPTY_DRAFT' : 'TEMPLATE_COPY';
  Json get query => {
        'operation': operation,
        'name': name,
        'kind': kind,
        if (templateId != null) 'templateId': templateId,
        if (templateRevision != null) 'templateRevision': templateRevision
      };
  Json toJson() => {...query, 'requestId': requestId, 'createdAt': createdAt};

  static PendingPolicyCreation parse(dynamic raw) {
    if (raw is! Json ||
        raw['requestId'] is! String ||
        !_uuid.hasMatch(raw['requestId']) ||
        raw['name'] is! String ||
        (raw['name'] as String).trim().isEmpty ||
        (raw['name'] as String).length > 100 ||
        !const {'POLICY', 'TEMPLATE'}.contains(raw['kind']) ||
        raw['createdAt'] is! int ||
        raw['createdAt'] <= 0) {
      throw const FormatException('创建恢复记录无法读取，请联系管理员处理。');
    }
    final copy = raw['operation'] == 'TEMPLATE_COPY';
    if (copy
        ? raw['kind'] != 'POLICY' ||
            raw['templateId'] is! String ||
            !_uuid.hasMatch(raw['templateId']) ||
            raw['templateRevision'] is! int ||
            raw['templateRevision'] < 0
        : raw['operation'] != 'EMPTY_DRAFT' ||
            raw['templateId'] != null ||
            raw['templateRevision'] != null) {
      throw const FormatException('创建恢复记录格式异常，请联系管理员处理。');
    }
    return PendingPolicyCreation(
        requestId: raw['requestId'],
        name: raw['name'],
        kind: raw['kind'],
        createdAt: raw['createdAt'],
        templateId: raw['templateId'],
        templateRevision: raw['templateRevision']);
  }
}

/// One unresolved creation per local tenant/actor prevents accidental duplicates.
class PolicyCreationStore {
  final ParentDurableStorage storage;
  PolicyCreationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'parent.pending.policy_creation.$tenant.$actor';
  Future<PendingPolicyCreation?> load(String tenant, String actor) async {
    final raw = await storage.read(key: _key(tenant, actor));
    return raw == null ? null : PendingPolicyCreation.parse(jsonDecode(raw));
  }

  Future<void> save(
      String tenant, String actor, PendingPolicyCreation item) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对已有创建记录。');
    PendingPolicyCreation.parse(item.toJson());
    await storage.write(
        key: _key(tenant, actor), value: jsonEncode(item.toJson()));
  }

  Future<void> remove(String tenant, String actor, String requestId) async {
    final item = await load(tenant, actor);
    if (item == null) return;
    if (item.requestId != requestId) throw StateError('恢复记录已变化，请重新读取。');
    await storage.delete(key: _key(tenant, actor));
  }
}

/// Shared creation/recovery state. Queries never invoke the original mutation.
class PolicyCreationController extends ChangeNotifier {
  final ParentApi api;
  final PolicyCreationStore store;
  final String tenant, actor;
  final bool Function() isCurrent;
  PendingPolicyCreation? pending;
  Json? result;
  Object? error;
  bool loaded = false, busy = false, queried = false, sourceStale = false;
  bool _disposed = false;
  PolicyCreationController(
      {required this.api,
      required this.store,
      required this.tenant,
      required this.actor,
      required this.isCurrent});
  bool get _current => !_disposed && isCurrent();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    if (!_current || busy) return;
    busy = true;
    loaded = false;
    error = null;
    _notify();
    try {
      final item = await store.load(tenant, actor);
      if (!_current) return;
      pending = item;
      result = null;
      queried = false;
      loaded = true;
    } catch (failure) {
      if (_current) error = failure;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> create(
      {required String name,
      required String kind,
      String? templateId,
      int? templateRevision}) async {
    if (!_current || busy || !loaded || pending != null || sourceStale) return;
    busy = true;
    error = null;
    result = null;
    queried = false;
    _notify();
    try {
      final item = PendingPolicyCreation(
          requestId: const Uuid().v4(),
          name: name.trim(),
          kind: kind,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          templateId: templateId,
          templateRevision: templateRevision);
      // A durable barrier must finish before the first byte of the POST leaves.
      await store.save(tenant, actor, item);
      if (!_current) return;
      pending = item;
      final raw = await api.send(
          'POST',
          templateId == null
              ? '/tenants/$tenant/policies'
              : '/tenants/$tenant/policies/$templateId/copies',
          version: templateRevision,
          idempotencyKey: item.requestId,
          isCurrent: () => _current,
          body: templateId == null
              ? {'name': item.name, 'kind': kind, 'rules': <Json>[]}
              : {'name': item.name});
      if (!_current) return;
      result = _draft(raw, item, newlyCreated: true);
      queried = true;
      // Retain the journal until the user opens the result successfully.
    } catch (failure) {
      if (!_current) return;
      error = failure;
      sourceStale = failure is ParentApiException && failure.status == 412;
      if (pending == null) {
        // A failed storage flush may still have written. Do not allow overwrite.
        loaded = false;
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> query() async {
    if (!_current || busy || pending == null) return;
    final item = pending!;
    busy = true;
    error = null;
    result = null;
    queried = false;
    _notify();
    try {
      final raw = await api.send('POST',
          '/tenants/$tenant/policy-draft-creation-results/${item.requestId}/query',
          body: item.query, isCurrent: () => _current);
      if (!_current) return;
      result = _draft(raw, item);
      queried = true;
    } on ParentApiException catch (failure) {
      if (!_current) return;
      if (failure.status == 404 &&
          failure.code == 'POLICY_CREATION_RESULT_UNAVAILABLE') {
        queried = true;
      } else {
        error = failure;
      }
    } catch (failure) {
      if (_current) error = failure;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> acknowledge() async {
    if (!_current || busy || pending == null || !queried) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await store.remove(tenant, actor, pending!.requestId);
      if (!_current) return false;
      pending = null;
      queried = false;
      return true;
    } catch (failure) {
      if (_current) error = failure;
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Json _draft(dynamic raw, PendingPolicyCreation item,
      {bool newlyCreated = false}) {
    if (raw is! Json ||
        raw['id'] is! String ||
        !_uuid.hasMatch(raw['id']) ||
        raw['kind'] != item.kind ||
        raw['name'] is! String ||
        raw['rules'] is! List ||
        raw['revision'] is! int ||
        raw['revision'] < 0 ||
        (newlyCreated && raw['revision'] != 0)) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return raw;
  }
}

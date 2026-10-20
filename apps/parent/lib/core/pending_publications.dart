import 'dart:convert';

import 'parent_durable_storage.dart';
import 'parent_api.dart';
import 'operation_journal.dart';
import 'operation_result_terminal.dart';
import 'package:flutter/foundation.dart';

/// Minimal non-secret reference saved durably before a configuration POST.
/// It permits an exact creator-only result lookup without replaying the POST.
class PendingPublication {
  final String policyId;
  final int revision;
  final String previewId;
  final String previewHash;
  final String idempotencyKey;
  final int createdAt;

  const PendingPublication({
    required this.policyId,
    required this.revision,
    required this.previewId,
    required this.previewHash,
    required this.idempotencyKey,
    required this.createdAt,
  });

  Map<String, Object> toJson() => {
        'policyId': policyId,
        'revision': revision,
        'previewId': previewId,
        'previewHash': previewHash,
        'idempotencyKey': idempotencyKey,
        'createdAt': createdAt,
      };

  static PendingPublication? fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['policyId'] is! String ||
        value['revision'] is! int ||
        value['previewId'] is! String ||
        value['previewHash'] is! String ||
        value['idempotencyKey'] is! String ||
        value['createdAt'] is! int) return null;
    final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
    if (!uuid.hasMatch(value['policyId'] as String) ||
        !uuid.hasMatch(value['previewId'] as String) ||
        !uuid.hasMatch(value['idempotencyKey'] as String) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['previewHash'] as String) ||
        (value['revision'] as int) < 0 ||
        (value['createdAt'] as int) <= 0) return null;
    return PendingPublication(
      policyId: value['policyId'] as String,
      revision: value['revision'] as int,
      previewId: value['previewId'] as String,
      previewHash: value['previewHash'] as String,
      idempotencyKey: value['idempotencyKey'] as String,
      createdAt: value['createdAt'] as int,
    );
  }
}

/// Per-tenant, per-actor journal. A pending policy blocks another publication
/// of the same draft until the adult reconciles the original result.
class PendingPublicationStore {
  final ParentDurableStorage storage;
  late final ParentOperationJournal journal = ParentOperationJournal(storage);
  PendingPublicationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();

  String collection(String tenantId, String actorId) =>
      'parent.pending.publications.$tenantId.$actorId';
  String slot(String tenantId, String actorId, String policyId) =>
      '${collection(tenantId, actorId)}.$policyId';

  Future<List<PendingPublication>> load(String tenantId, String actorId) async {
    final raw = await journal.readCollection(collection(tenantId, actorId), (payload) {
      final marker = PendingPublication.fromJson(payload);
      if (marker == null) throw const FormatException('待核对发布记录无效。');
      return slot(tenantId, actorId, marker.policyId);
    });
    final result = <PendingPublication>[];
    final requests = <String>{};
    for (final wire in raw) {
      final item = PendingPublication.fromJson(jsonDecode(wire));
      if (item == null || !requests.add(item.idempotencyKey)) {
        throw const FormatException('待核对发布记录无法校验。');
      }
      result.add(item);
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<void> add(String tenantId, String actorId, PendingPublication item) async {
    if (PendingPublication.fromJson(item.toJson()) == null) {
      throw const FormatException('待核对发布记录无效。');
    }
    // The native transaction enforces both the 20-entry cap and one pending
    // publication per policy. A list/read race cannot overwrite another tab.
    await journal.write(key: slot(tenantId, actorId, item.policyId),
        value: jsonEncode(item.toJson()), collection: collection(tenantId, actorId));
  }

  Future<void> remove(String tenantId, String actorId, String key) async {
    final rows = await load(tenantId, actorId);
    final matching = rows.where((row) => row.idempotencyKey == key);
    if (matching.isEmpty) return;
    await journal.delete(key: slot(tenantId, actorId, matching.single.policyId));
  }

  Future<bool> beforeWrite(String tenantId, String actorId,
      PendingPublication item, bool Function() current) async {
    if (!current()) return false;
    final key = slot(tenantId, actorId, item.policyId);
    if (journal.snapshot(key)?['knownSuccessful'] == true) return false;
    await journal.assertCurrent(key, Map<String, dynamic>.from(item.toJson()));
    return current();
  }

  Future<void> confirmed(String tenantId, String actorId, PendingPublication item) =>
      journal.confirmed(slot(tenantId, actorId, item.policyId));

  Future<void> capture(String tenantId, String actorId,
      PendingPublication item, Object failure) async {
    if (failure is! ParentResultTerminalFailure ||
        !failure.matchesRequest(item.idempotencyKey)) return;
    await journal.terminal(slot(tenantId, actorId, item.policyId), item.idempotencyKey,
        failure.code == 'IDEMPOTENCY_RESPONSE_ERASED' ? 'ERASED' : 'EXPIRED');
  }
}

/// A publication result remains CONFIGURE_ONLY; a terminal check never changes
/// publication mode, targets, draft rules or device enforcement.
class PendingPublicationRecovery extends ChangeNotifier with ParentTerminalOperation {
  final ParentApi api;
  final PendingPublicationStore store;
  final String tenant, actor;
  final PendingPublication marker;
  final bool Function() isCurrent;
  PendingPublication? pending;
  Json? result;
  bool busy = false, loaded = true, queried = false, _disposed = false;
  Object? error;
  PendingPublicationRecovery({required this.api, required this.store,
      required this.tenant, required this.actor, required this.marker,
      required this.isCurrent}) : pending = marker;
  @override
  ParentOperationJournal get operationJournal => store.journal;
  @override
  String get operationSlot => store.slot(tenant, actor, marker.policyId);
  @override
  Json? get operationPayload => pending == null ? null :
      Map<String, dynamic>.from(pending!.toJson());
  @override
  String? get operationRequestId => pending?.idempotencyKey;
  @override
  bool get operationCurrent => !_disposed && isCurrent();
  @override
  bool get operationHasSuccessfulResult => result != null;
  @override
  void forgetOperationPayload() {
    pending = null;
    result = null;
    queried = false;
    loaded = false;
  }
  void _notify() { if (!_disposed) notifyListeners(); }
  @override
  Future<void> load() async {
    if (!operationCurrent || busy) return;
    busy = true;
    loaded = false;
    error = null;
    _notify();
    try {
      final rows = await store.load(tenant, actor);
      if (!operationCurrent) return;
      final matches = rows.where((row) => row.idempotencyKey == marker.idempotencyKey);
      pending = matches.isEmpty ? null : matches.single;
      result = null;
      queried = false;
      loaded = true;
    } catch (failure) {
      if (operationCurrent) error = failure;
    } finally { busy = false; _notify(); }
  }
  Future<void> query() async {
    if (!operationCurrent || busy || pending == null || operationBlocked) return;
    busy = true;
    queried = false;
    error = null;
    result = null;
    _notify();
    try {
      final query = Uri(queryParameters: {
        'mode': 'CONFIGURE_ONLY', 'revision': '${marker.revision}',
        'previewId': marker.previewId, 'previewHash': marker.previewHash,
      }).query;
      final raw = await api.object(
          '/tenants/$tenant/policies/${marker.policyId}/publication-results/${marker.idempotencyKey}?$query',
          isCurrent: () => operationCurrent, beforeDispatch: operationBeforeDispatch);
      if (!operationCurrent) return;
      if (raw['id'] is! String || raw['versionId'] is! String ||
          raw['sequence'] is! int || raw['mode'] != 'CONFIGURE_ONLY' ||
          raw['state'] != 'CONFIGURED_NOT_ENFORCED') {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      result = raw;
      await recordSuccessfulOperation();
      queried = true;
    } catch (failure) {
      await captureResultTerminal(failure);
      if (operationCurrent) {
        error = failure;
        queried = failure is ParentApiException && failure.status == 404 &&
            failure.code == 'POLICY_PUBLICATION_RESULT_UNAVAILABLE';
      }
    } finally { busy = false; _notify(); }
  }
  Future<bool> acknowledge() async {
    if (!operationCurrent || busy || !queried || pending == null || operationBlocked) return false;
    busy = true;
    error = null;
    _notify();
    try {
      await store.remove(tenant, actor, marker.idempotencyKey);
      if (!operationCurrent) return false;
      forgetOperationPayload();
      return true;
    } catch (failure) {
      if (operationCurrent) error = failure;
      return false;
    } finally { busy = false; _notify(); }
  }
  @override
  void dispose() { _disposed = true; super.dispose(); }
}

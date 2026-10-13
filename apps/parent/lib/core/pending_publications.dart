import 'dart:convert';

import 'parent_durable_storage.dart';

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
  PendingPublicationStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();

  String _key(String tenantId, String actorId) =>
      'parent.pending.publications.$tenantId.$actorId';

  Future<List<PendingPublication>> load(String tenantId, String actorId) async {
    final raw = await storage.read(key: _key(tenantId, actorId));
    if (raw == null) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('待核对发布记录无法读取，请联系管理员处理。');
    }
    if (decoded is! List || decoded.length > 20) {
      throw const FormatException('待核对发布记录格式异常，请联系管理员处理。');
    }
    final result = <PendingPublication>[];
    final keys = <String>{};
    final policies = <String>{};
    for (final value in decoded) {
      final item = PendingPublication.fromJson(value);
      if (item == null ||
          !keys.add(item.idempotencyKey) ||
          !policies.add(item.policyId)) {
        throw const FormatException('待核对发布记录格式异常，请联系管理员处理。');
      }
      result.add(item);
    }
    return result;
  }

  Future<void> add(
      String tenantId, String actorId, PendingPublication item) async {
    final rows = await load(tenantId, actorId);
    if (rows.length >= 20) {
      throw const FormatException('待核对发布已达 20 条，请先核对已有记录。');
    }
    if (rows.any((row) =>
        row.policyId == item.policyId ||
        row.idempotencyKey == item.idempotencyKey)) {
      throw const FormatException('该策略已有待核对发布，请先查询原结果。');
    }
    await storage.write(
        key: _key(tenantId, actorId),
        value: jsonEncode([...rows.map((row) => row.toJson()), item.toJson()]));
  }

  Future<void> remove(String tenantId, String actorId, String key) async {
    final rows = await load(tenantId, actorId);
    final remaining = rows.where((row) => row.idempotencyKey != key).toList();
    if (remaining.length == rows.length) return;
    if (remaining.isEmpty) {
      await storage.delete(key: _key(tenantId, actorId));
    } else {
      await storage.write(
          key: _key(tenantId, actorId),
          value: jsonEncode(remaining.map((row) => row.toJson()).toList()));
    }
  }
}

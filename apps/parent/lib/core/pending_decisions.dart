import 'dart:convert';

import 'parent_durable_storage.dart';

/// Non-secret operation reference kept until an adult explicitly reconciles it.
/// A marker is written before POST so process death cannot erase uncertainty.
class PendingDecision {
  final String requestId;
  final int version;
  final String idempotencyKey;
  final String choice;
  final int createdAt;

  const PendingDecision({
    required this.requestId,
    required this.version,
    required this.idempotencyKey,
    required this.choice,
    required this.createdAt,
  });

  Map<String, Object> toJson() => {
        'requestId': requestId,
        'version': version,
        'idempotencyKey': idempotencyKey,
        'choice': choice,
        'createdAt': createdAt,
      };

  static PendingDecision? fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['requestId'] is! String ||
        value['version'] is! int ||
        value['idempotencyKey'] is! String ||
        value['createdAt'] is! int ||
        !const {'APPROVE', 'DENY'}.contains(value['choice'])) {
      return null;
    }
    final id = value['requestId'] as String;
    final key = value['idempotencyKey'] as String;
    if (id.isEmpty || key.isEmpty) return null;
    return PendingDecision(
      requestId: id,
      version: value['version'] as int,
      idempotencyKey: key,
      choice: value['choice'] as String,
      createdAt: value['createdAt'] as int,
    );
  }
}

/// Per-tenant, per-actor journal. It contains no access token, request reason,
/// child name, application name, or device credential.
class PendingDecisionStore {
  final ParentDurableStorage storage;
  PendingDecisionStore({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();

  String _key(String tenantId, String actorId) =>
      'parent.pending.decisions.$tenantId.$actorId';

  Future<List<PendingDecision>> load(String tenantId, String actorId) async {
    final raw = await storage.read(key: _key(tenantId, actorId));
    if (raw == null) return const [];
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const FormatException('待核对审批记录无法读取，请联系管理员处理。');
    }
    if (decoded is! List || decoded.length > 20) {
      throw const FormatException('待核对审批记录格式异常，请联系管理员处理。');
    }
    final records = <PendingDecision>[];
    final keys = <String>{};
    for (final item in decoded) {
      final record = PendingDecision.fromJson(item);
      if (record == null || !keys.add(record.idempotencyKey)) {
        throw const FormatException('待核对审批记录格式异常，请联系管理员处理。');
      }
      records.add(record);
    }
    return records;
  }

  Future<void> add(
      String tenantId, String actorId, PendingDecision record) async {
    final records = await load(tenantId, actorId);
    if (records.length >= 20) {
      throw const FormatException('待核对审批已达 20 条，请先核对已有记录。');
    }
    if (records.any((item) =>
        item.idempotencyKey == record.idempotencyKey ||
        (item.requestId == record.requestId &&
            item.version == record.version))) {
      throw const FormatException('同一申请已有待核对操作，请先查询原记录。');
    }
    await storage.write(
        key: _key(tenantId, actorId),
        value: jsonEncode(
            [...records.map((item) => item.toJson()), record.toJson()]));
  }

  Future<void> remove(String tenantId, String actorId, String key) async {
    final records = await load(tenantId, actorId);
    final remaining =
        records.where((item) => item.idempotencyKey != key).toList();
    if (remaining.length == records.length) return;
    if (remaining.isEmpty) {
      await storage.delete(key: _key(tenantId, actorId));
    } else {
      await storage.write(
          key: _key(tenantId, actorId),
          value: jsonEncode(remaining.map((item) => item.toJson()).toList()));
    }
  }
}

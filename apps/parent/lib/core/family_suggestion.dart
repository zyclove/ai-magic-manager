import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'family.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

/// The exact consented request is encrypted before a potentially chargeable POST.
class FamilySuggestionCoordinator {
  final FamilyService service;
  final String actor, subjectId, task;
  final ParentDurableStorage storage;
  Json? pending;
  bool loaded = false, busy = false;
  FamilySuggestionCoordinator(
      {required this.service,
      required this.actor,
      required this.subjectId,
      required this.task,
      ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String get key =>
      'parent.family.suggestion.${service.tenantId}.$actor.$subjectId.$task';
  String? get pendingPrompt => pending?['prompt'] as String?;
  Future<void> restore() async {
    service.check();
    final raw = await storage.read(key: key);
    service.check();
    if (raw != null) {
      if (raw.length > 8192) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      final value = jsonDecode(raw);
      if (value is! Json ||
          value['idempotencyKey'] is! String ||
          value['idempotencyKey'].isEmpty ||
          value['prompt'] is! String ||
          value['prompt'].isEmpty ||
          value['prompt'].length > 500 ||
          value['subjectId'] != subjectId ||
          value['task'] != task ||
          value['cloudConsent'] != true ||
          (value['deviceId'] != null && value['deviceId'] is! String)) {
        throw const ParentApiException(502, 'INVALID_RESPONSE');
      }
      pending = value;
    }
    loaded = true;
  }

  Future<Json> submit(
      {required String prompt,
      required bool cloudConsent,
      String? deviceId}) async {
    service.check();
    if (!loaded || busy) throw StateError('请先核对上次助手请求。');
    if (!cloudConsent) {
      throw const ParentApiException(400, 'AI_CONSENT_REQUIRED');
    }
    final text = prompt.trim();
    if (text.isEmpty || text.length > 500) throw StateError('请填写需要助手整理的内容。');
    if (pending != null &&
        (pending!['prompt'] != text || pending!['deviceId'] != deviceId)) {
      throw StateError('原建议请求结果待核对，不能替换为新的内容。');
    }
    busy = true;
    try {
      if (pending == null) {
        final value = {
          'idempotencyKey': const Uuid().v4(),
          'task': task,
          'subjectId': subjectId,
          'prompt': text,
          'cloudConsent': true,
          if (deviceId != null) 'deviceId': deviceId
        };
        await storage.write(key: key, value: jsonEncode(value));
        service.check();
        pending = value;
      }
      final value = await service.suggest(
          task: task,
          subjectId: subjectId,
          prompt: pending!['prompt'],
          cloudConsent: true,
          idempotencyKey: pending!['idempotencyKey'],
          deviceId: pending!['deviceId']);
      await storage.delete(key: key);
      service.check();
      pending = null;
      return value;
    } on ParentApiException catch (error) {
      if (error.status >= 400 &&
          error.status < 500 &&
          error.status != 408 &&
          !const {'IDEMPOTENCY_IN_PROGRESS', 'UNAUTHENTICATED', 'SCOPE_DENIED'}
              .contains(error.code)) {
        await storage.delete(key: key);
        service.check();
        pending = null;
      }
      rethrow;
    } finally {
      busy = false;
    }
  }
}

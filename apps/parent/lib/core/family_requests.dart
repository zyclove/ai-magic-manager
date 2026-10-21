import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'family.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

class FamilyAccessRequest {
  final String id, subjectId, deviceId, state, reason;
  final int requestedSeconds, expiresAt, version;
  final int? grantedSeconds, notAfter;
  FamilyAccessRequest.fromJson(Json value)
      : id = value['id'] as String,
        subjectId = value['subjectId'] as String,
        deviceId = value['deviceId'] as String,
        state = value['state'] as String,
        reason = value['reason'] as String,
        requestedSeconds = value['requestedSeconds'] as int,
        expiresAt = value['expiresAt'] as int,
        version = value['version'] as int,
        grantedSeconds = value['grantedSeconds'] as int?,
        notAfter = value['notAfter'] as int? {
    if (![id, subjectId, deviceId]
            .every((v) => Uuid.isValidUUID(fromString: v)) ||
        !{'PENDING', 'APPROVED', 'DENIED', 'EXPIRED', 'REVOKED'}
            .contains(state) ||
        requestedSeconds < 60 ||
        requestedSeconds > 3600 ||
        version < 0 ||
        reason.length > 300 ||
        expiresAt < 1 ||
        grantedSeconds != null &&
            (grantedSeconds! < 60 || grantedSeconds! > requestedSeconds) ||
        notAfter != null && notAfter! < 1) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
  }
}

/// Contains only the original command, never a child's name or request text.
class FamilyDecisionJournal {
  final ParentDurableStorage storage;
  FamilyDecisionJournal({ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String _key(String tenant, String actor) =>
      'family.pending.decision.$tenant.$actor';
  Future<Json?> load(String tenant, String actor) async {
    final text = await storage.read(key: _key(tenant, actor));
    if (text == null) return null;
    final value = jsonDecode(text);
    if (value is! Json ||
        value.keys.toSet().difference({
          'id',
          'version',
          'key',
          'decision',
          'grantedSeconds'
        }).isNotEmpty ||
        value['id'] is! String ||
        !Uuid.isValidUUID(fromString: value['id']) ||
        value['key'] is! String ||
        !Uuid.isValidUUID(fromString: value['key']) ||
        value['version'] is! int ||
        value['version'] < 0 ||
        !{'APPROVE', 'DENY'}.contains(value['decision']) ||
        value['grantedSeconds'] is! int ||
        value['grantedSeconds'] < 0 ||
        value['grantedSeconds'] > 3600 ||
        value['decision'] == 'APPROVE' && value['grantedSeconds'] < 60 ||
        value['decision'] == 'DENY' && value['grantedSeconds'] != 0) {
      throw const FormatException('原操作记录无法读取，请通过帮助入口处理。');
    }
    return value;
  }

  Future<Json> begin(String tenant, String actor, FamilyAccessRequest request,
      {required bool approve, required int seconds}) async {
    if (await load(tenant, actor) != null) throw StateError('请先核对原操作。');
    if (request.state != 'PENDING' ||
        approve && (seconds < 60 || seconds > request.requestedSeconds)) {
      throw StateError('申请状态或放行时间已变化，请重新读取。');
    }
    final Json value = {
      'id': request.id,
      'version': request.version,
      'key': const Uuid().v4(),
      'decision': approve ? 'APPROVE' : 'DENY',
      'grantedSeconds': approve ? seconds : 0
    };
    await storage.write(key: _key(tenant, actor), value: jsonEncode(value));
    return value;
  }

  Future<void> clear(String tenant, String actor) =>
      storage.delete(key: _key(tenant, actor));
}

class FamilyRequests {
  final FamilyService family;
  FamilyRequests(this.family);
  Future<FamilyAccessRequest> read(String id) async {
    final result = FamilyAccessRequest.fromJson(await family
        .object('/family-access-requests/${Uri.encodeComponent(id)}'));
    if (result.id != id) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return result;
  }

  Future<FamilyAccessRequest> submit(Json pending) async {
    final result = FamilyAccessRequest.fromJson(await family.write('POST',
        '/family-access-requests/${Uri.encodeComponent(pending['id'])}/decision',
        version: pending['version'],
        idempotencyKey: pending['key'],
        body: {
          'decision': pending['decision'],
          'grantedSeconds': pending['grantedSeconds']
        }));
    if (result.id != pending['id'] ||
        result.version != pending['version'] + 1 ||
        result.state !=
            (pending['decision'] == 'APPROVE' ? 'APPROVED' : 'DENIED')) {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
    return result;
  }
}

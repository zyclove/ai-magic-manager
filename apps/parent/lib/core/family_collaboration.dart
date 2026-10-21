import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:uuid/uuid.dart';
import 'family.dart';
import 'parent_api.dart';
import 'parent_durable_storage.dart';

Never _invalid() => throw const ParentApiException(502, 'INVALID_RESPONSE');
String _id(dynamic value) =>
    value is String && Uuid.isValidUUID(fromString: value) ? value : _invalid();
String _text(dynamic value, {int max = 100}) => value is String &&
        value.trim().isNotEmpty &&
        value.length <= max &&
        !RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]').hasMatch(value)
    ? value
    : _invalid();
int _number(dynamic value) =>
    value is int && value >= 0 && value <= 9007199254740991
        ? value
        : _invalid();
final _journalTails = <String, Future<void>>{};
Future<T> _journalOperation<T>(String key, Future<T> Function() action) {
  final result =
      (_journalTails[key] ?? Future<void>.value()).then((_) => action());
  late final Future<void> tail;
  tail = result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
    if (identical(_journalTails[key], tail)) _journalTails.remove(key);
  });
  _journalTails[key] = tail;
  return result;
}

bool _secret(dynamic value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    return false;
  }
  try {
    return base64Url.decode('$value=').length == 32 &&
        base64UrlEncode(base64Url.decode('$value=')).replaceAll('=', '') ==
            value;
  } catch (_) {
    return false;
  }
}

String normalizeFamilyPhone(String phone) {
  final clean = phone.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^(\+86)?1[3-9][0-9]{9}$').hasMatch(clean)) {
    throw const FormatException('请输入中国大陆手机号。');
  }
  return clean.startsWith('+86') ? clean : '+86$clean';
}

class FamilyInvitationIntent {
  final String id, token;
  FamilyInvitationIntent(this.id, this.token) {
    if (!Uuid.isValidUUID(fromString: id) || !_secret(token)) {
      throw const FormatException('邀请链接格式不正确。');
    }
  }
  String get link => Uri(
      scheme: 'aimanager',
      host: 'family-invitation',
      queryParameters: {'id': id, 'token': token}).toString();
  factory FamilyInvitationIntent.parse(String input) {
    try {
      final uri = Uri.parse(input.trim()),
          params = Uri.parse(input.trim()).queryParametersAll;
      if (uri.scheme != 'aimanager' ||
          uri.host != 'family-invitation' ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.path.isNotEmpty ||
          uri.hasFragment ||
          params.length != 2 ||
          params['id']?.length != 1 ||
          params['token']?.length != 1) throw const FormatException();
      return FamilyInvitationIntent(
          params['id']!.single, params['token']!.single);
    } catch (_) {
      throw const FormatException('请粘贴家人分享的完整邀请链接。');
    }
  }
}

class FamilyInvitationSummary {
  final String id, targetPhoneMasked, state;
  final int expiresAt;
  FamilyInvitationSummary.fromJson(Json value)
      : id = _id(value['id']),
        targetPhoneMasked = _text(value['targetPhoneMasked'], max: 32),
        expiresAt = _number(value['expiresAt']),
        state = _text(value['state']) {
    if (value['role'] != 'GUARDIAN' ||
        !{'PENDING', 'ACCEPTED', 'EXPIRED', 'REVOKED'}.contains(state) ||
        !targetPhoneMasked.contains('*') ||
        RegExp(r'1[3-9][0-9]{9}').hasMatch(targetPhoneMasked)) _invalid();
  }
}

class FamilyMember {
  final String memberKey, displayName, role;
  final int version;
  final bool self, canRemove;
  FamilyMember.fromJson(Json value)
      : memberKey = _text(value['memberKey']),
        displayName = _text(value['displayName']),
        role = _text(value['role']),
        version = _number(value['version']),
        self = value['self'] is bool ? value['self'] : _invalid(),
        canRemove =
            value['canRemove'] is bool ? value['canRemove'] : _invalid() {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(memberKey) ||
        !{'OWNER', 'GUARDIAN'}.contains(role) ||
        role == 'OWNER' && canRemove) _invalid();
  }
}

class FamilyMembersSnapshot {
  final String currentRole;
  final bool guardianDeclarationRequired;
  final List<FamilyMember> members;
  FamilyMembersSnapshot.fromJson(Json value, {required String tenantId})
      : currentRole = _text(value['currentRole']),
        guardianDeclarationRequired =
            value['guardianDeclarationRequired'] is bool
                ? value['guardianDeclarationRequired']
                : _invalid(),
        members = List.unmodifiable(value['members'] is List
            ? (value['members'] as List)
                .map((v) => FamilyMember.fromJson(v is Json ? v : _invalid()))
            : _invalid()) {
    if (value['tenantId'] != tenantId ||
        !{'OWNER', 'GUARDIAN'}.contains(currentRole) ||
        members.map((m) => m.memberKey).toSet().length != members.length ||
        members.where((m) => m.self).length > 1 ||
        members.any((m) => m.self && m.role != currentRole) ||
        members.any((m) => m.canRemove && (currentRole != 'OWNER' || m.self))) {
      _invalid();
    }
  }
}

Future<FamilyMembersSnapshot> readFamilyMembersSnapshot(
        FamilyService service) async =>
    FamilyMembersSnapshot.fromJson(await service.object('/family-members'),
        tenantId: service.tenantId);
Future<List<FamilyMember>> readFamilyMembers(FamilyService service) async =>
    (await readFamilyMembersSnapshot(service)).members;

bool _definite(ParentApiException error) =>
    error.status >= 400 &&
    error.status < 500 &&
    !{401, 403, 408}.contains(error.status) &&
    !{
      'IDEMPOTENCY_IN_PROGRESS',
      'REQUEST_IN_PROGRESS',
      'WORKSPACE_CHANGED',
      'SCOPE_DENIED'
    }.contains(error.code);

/// 邀请密钥只存本机加密日志。成功后保留分享能力，同时移除原手机号。
class FamilyInviteCoordinator {
  final FamilyService service;
  final String actor;
  final ParentDurableStorage storage;
  bool loaded = false, busy = false;
  Json? pending;
  FamilyInvitationIntent? shareIntent;
  int? shareExpiresAt;
  List<FamilyInvitationSummary> invitations = [];
  String? _serialized;
  FamilyInviteCoordinator(
      {required this.service,
      required this.actor,
      ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String get _key => 'parent.family.invite.${service.tenantId}.$actor';
  Future<void> load() => _journalOperation(_key, _load);
  Future<void> _load() async {
    service.check();
    if (busy) throw StateError('正在核对邀请。');
    busy = true;
    loaded = false;
    try {
      final raw = await storage.read(key: _key);
      service.check();
      pending = null;
      shareIntent = null;
      shareExpiresAt = null;
      if (raw != null) {
        if (raw.length > 8192) throw const FormatException('本机邀请进度无法读取。');
        final value = jsonDecode(raw);
        if (value is! Json || value['schema'] != 1) {
          throw const FormatException('本机邀请进度无法读取。');
        }
        if (value['stage'] == 'PENDING' &&
            value.length == 4 &&
            value['body'] is Json &&
            value['key'] is String &&
            Uuid.isValidUUID(fromString: value['key'])) {
          final body = value['body'] as Json;
          if (body.length != 3 ||
              body['targetPhone'] is! String ||
              normalizeFamilyPhone(body['targetPhone']) !=
                  body['targetPhone']) {
            throw const FormatException();
          }
          FamilyInvitationIntent(_id(body['invitationId']), body['token']);
          pending = Map.unmodifiable(value);
        } else if (value['stage'] == 'READY' && value.length == 5) {
          shareIntent =
              FamilyInvitationIntent(_id(value['id']), value['token']);
          shareExpiresAt = _number(value['expiresAt']);
        } else {
          throw const FormatException('本机邀请进度无法读取。');
        }
      }
      final value = await service.object('/family-invitations');
      if (value['tenantId'] != service.tenantId || value['items'] is! List) {
        _invalid();
      }
      final list = (value['items'] as List)
          .map((v) =>
              FamilyInvitationSummary.fromJson(v is Json ? v : _invalid()))
          .toList();
      if (list.map((i) => i.id).toSet().length != list.length) _invalid();
      service.check();
      invitations = List.unmodifiable(list);
      _serialized = raw;
      loaded = true;
    } finally {
      busy = false;
    }
  }

  Future<FamilyInvitationSummary> create(String phone) =>
      _journalOperation(_key, () => _create(phone));
  Future<FamilyInvitationSummary> _create(String phone) async {
    service.check();
    if (!loaded || busy || pending != null || shareIntent != null) {
      throw StateError('请先核对或完成上次邀请。');
    }
    final normalized = normalizeFamilyPhone(phone);
    busy = true;
    try {
      if (await storage.read(key: _key) != _serialized) {
        loaded = false;
        throw StateError('邀请进度发生变化，请重新读取。');
      }
      service.check();
      final random = Random.secure();
      final token =
          base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
              .replaceAll('=', '');
      final command = {
        'schema': 1,
        'stage': 'PENDING',
        'key': const Uuid().v4(),
        'body': {
          'invitationId': const Uuid().v4(),
          'targetPhone': normalized,
          'token': token
        }
      };
      loaded = false;
      await storage.write(key: _key, value: jsonEncode(command));
      service.check();
      pending = Map.unmodifiable(command);
      _serialized = jsonEncode(command);
      loaded = true;
      return await _send();
    } finally {
      busy = false;
    }
  }

  Future<FamilyInvitationSummary> retry() => _journalOperation(_key, _retry);
  Future<FamilyInvitationSummary> _retry() async {
    service.check();
    if (!loaded || busy || pending == null) throw StateError('请先核对原邀请。');
    busy = true;
    try {
      if (await storage.read(key: _key) != _serialized) {
        loaded = false;
        throw StateError('邀请进度发生变化，请重新读取。');
      }
      return await _send();
    } finally {
      busy = false;
    }
  }

  Future<FamilyInvitationSummary> _send() async {
    final original = pending!, body = original['body'] as Json;
    try {
      final value = FamilyInvitationSummary.fromJson(await service.write(
          'POST', '/family-invitations',
          body: body, idempotencyKey: original['key']));
      if (value.id != body['invitationId']) _invalid();
      final ready = {
        'schema': 1,
        'stage': 'READY',
        'id': value.id,
        'token': body['token'],
        'expiresAt': value.expiresAt
      };
      await storage.write(key: _key, value: jsonEncode(ready));
      service.check();
      _serialized = jsonEncode(ready);
      shareIntent = FamilyInvitationIntent(value.id, body['token']);
      shareExpiresAt = value.expiresAt;
      pending = null;
      return value;
    } on ParentApiException catch (error) {
      if (_definite(error)) {
        service.check();
        await storage.delete(key: _key);
        service.check();
        pending = null;
        _serialized = null;
        loaded = false;
      }
      rethrow;
    }
  }

  Future<void> finishSharing() => _journalOperation(_key, _finishSharing);
  Future<void> _finishSharing() async {
    service.check();
    if (busy || pending != null || !loaded) throw StateError('请先核对原邀请。');
    if (await storage.read(key: _key) != _serialized) {
      loaded = false;
      throw StateError('邀请进度发生变化，请重新读取。');
    }
    await storage.delete(key: _key);
    service.check();
    shareIntent = null;
    shareExpiresAt = null;
    _serialized = null;
  }
}

/// 撤销和移除都是单向操作，未知结果仍使用原目标、版本和幂等键。
class FamilyCollaborationChange {
  final FamilyService service;
  final String actor;
  final ParentDurableStorage storage;
  Json? pending;
  bool loaded = false, busy = false;
  FamilyCollaborationChange(
      {required this.service,
      required this.actor,
      ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String get _key =>
      'parent.family.collaboration-change.${service.tenantId}.$actor';
  Future<void> load() => _journalOperation(_key, _load);
  Future<void> _load() async {
    service.check();
    loaded = false;
    final raw = await storage.read(key: _key);
    service.check();
    pending = null;
    if (raw != null) {
      if (raw.length > 2048) throw const FormatException('原家庭操作无法读取。');
      final value = jsonDecode(raw);
      if (value is! Json ||
          value.length != 4 ||
          !{'REVOKE_INVITATION', 'REMOVE_MEMBER'}.contains(value['kind']) ||
          value['key'] is! String ||
          !Uuid.isValidUUID(fromString: value['key']) ||
          value['target'] is! String) throw const FormatException();
      if (value['kind'] == 'REMOVE_MEMBER') {
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value['target'])) {
          throw const FormatException();
        }
        _number(value['version']);
      } else if (!Uuid.isValidUUID(fromString: value['target']) ||
          value['version'] != null) {
        throw const FormatException();
      }
      pending = Map.unmodifiable(value);
    }
    loaded = true;
  }

  Future<void> start(
          {required String kind, required String target, int? version}) =>
      _journalOperation(
          _key, () => _start(kind: kind, target: target, version: version));
  Future<void> _start(
      {required String kind, required String target, int? version}) async {
    service.check();
    if (!loaded || busy || pending != null) throw StateError('请先核对原家庭操作。');
    if (kind == 'REMOVE_MEMBER'
        ? !RegExp(r'^[a-f0-9]{64}$').hasMatch(target) || version == null
        : kind != 'REVOKE_INVITATION' ||
            !Uuid.isValidUUID(fromString: target) ||
            version != null) throw const FormatException();
    busy = true;
    try {
      if (await storage.read(key: _key) != null) {
        loaded = false;
        throw StateError('原家庭操作尚未核对，请重新读取。');
      }
      service.check();
      final command = {
        'key': const Uuid().v4(),
        'kind': kind,
        'target': target,
        'version': version
      };
      loaded = false;
      await storage.write(key: _key, value: jsonEncode(command));
      service.check();
      pending = Map.unmodifiable(command);
      loaded = true;
      await _send();
    } finally {
      busy = false;
    }
  }

  Future<void> retry() => _journalOperation(_key, _retry);
  Future<void> _retry() async {
    service.check();
    if (!loaded || busy || pending == null) throw StateError('请先读取原家庭操作。');
    busy = true;
    try {
      if (await storage.read(key: _key) != jsonEncode(pending)) {
        loaded = false;
        throw StateError('家庭操作进度发生变化，请重新读取。');
      }
      await _send();
    } finally {
      busy = false;
    }
  }

  Future<void> _send() async {
    final original = pending!;
    try {
      final endpoint = original['kind'] == 'REMOVE_MEMBER'
          ? 'family-members'
          : 'family-invitations';
      await service.api.send(
          'DELETE', '${service.root}/$endpoint/${original['target']}',
          version: original['version'],
          idempotencyKey: original['key'],
          isCurrent: service.available,
          expectedStatus: 204);
      service.check();
      await storage.delete(key: _key);
      service.check();
      pending = null;
    } on ParentApiException catch (error) {
      if (_definite(error)) {
        service.check();
        await storage.delete(key: _key);
        service.check();
        pending = null;
        loaded = false;
      }
      rethrow;
    }
  }
}

class FamilyInvitationPreview {
  final String invitationId, tenantId, tenantName, state;
  final int expiresAt;
  FamilyInvitationPreview.fromJson(Json value)
      : invitationId = _id(value['invitationId']),
        tenantId = _id(value['tenantId']),
        tenantName = _text(value['tenantName']),
        state = _text(value['state']),
        expiresAt = _number(value['expiresAt']) {
    if (value['role'] != 'GUARDIAN' ||
        !{'PENDING', 'ACCEPTED', 'EXPIRED', 'REVOKED'}.contains(state)) {
      _invalid();
    }
  }
}

/// 首次家庭尚未创建时也可接受邀请，所有网络仍绑定同一个已登录成人。
class FamilyInviteAcceptance {
  final ParentApi api;
  final String actor;
  final bool Function() available;
  final ParentDurableStorage storage;
  bool busy = false, loaded = false, revoked = false;
  Json? pending;
  FamilyInvitationIntent? intent;
  FamilyInvitationPreview? details;
  String? acceptedTenant;
  FamilyInviteAcceptance(
      {required this.api,
      required this.actor,
      required this.available,
      ParentDurableStorage? storage})
      : storage = storage ?? ParentDurableStorage();
  String get _key => 'parent.family.invitation-accept.$actor';
  void _check() {
    if (!available()) throw const ParentApiException(409, 'SCOPE_DENIED');
  }

  Future<void> load() => _journalOperation(_key, _load);
  Future<void> _load() async {
    _check();
    loaded = false;
    final raw = await storage.read(key: _key);
    _check();
    pending = null;
    if (raw != null) {
      if (raw.length > 4096) throw const FormatException('上次加入进度无法读取。');
      final value = jsonDecode(raw);
      if (value is! Json ||
          value.length != 2 ||
          value['body'] is! Json ||
          value['key'] is! String ||
          !Uuid.isValidUUID(fromString: value['key'])) {
        throw const FormatException();
      }
      final body = value['body'] as Json;
      if (body.length != 4 ||
          body['adultGuardian'] != true ||
          body['declarationVersion'] != 'family-guardian-v1') {
        throw const FormatException();
      }
      intent = FamilyInvitationIntent(_id(body['invitationId']), body['token']);
      pending = Map.unmodifiable(value);
    }
    loaded = true;
  }

  Future<void> preview(FamilyInvitationIntent value) async {
    _check();
    if (!loaded || busy || pending != null) throw StateError('请先核对上次加入进度。');
    busy = true;
    details = null;
    try {
      final result = FamilyInvitationPreview.fromJson(
          await api.objectPreview(value, available));
      _check();
      if (result.invitationId != value.id) _invalid();
      intent = value;
      details = result;
    } finally {
      busy = false;
    }
  }

  Future<void> accept({required bool adultGuardian}) =>
      _journalOperation(_key, () => _accept(adultGuardian: adultGuardian));
  Future<void> _accept({required bool adultGuardian}) async {
    _check();
    if (!loaded ||
        busy ||
        pending != null ||
        details == null ||
        intent == null ||
        !adultGuardian ||
        details!.state != 'PENDING') throw StateError('请阅读邀请并确认成人监护声明。');
    busy = true;
    try {
      if (await storage.read(key: _key) != null) {
        loaded = false;
        throw StateError('上次加入进度尚未核对，请重新读取。');
      }
      _check();
      final body = {
        'invitationId': intent!.id,
        'token': intent!.token,
        'adultGuardian': true,
        'declarationVersion': 'family-guardian-v1'
      };
      final original = {'key': const Uuid().v4(), 'body': body};
      loaded = false;
      await storage.write(key: _key, value: jsonEncode(original));
      _check();
      pending = Map.unmodifiable(original);
      loaded = true;
      await _send();
    } finally {
      busy = false;
    }
  }

  Future<void> retry() => _journalOperation(_key, _retry);
  Future<void> _retry() async {
    _check();
    if (!loaded || busy || pending == null) throw StateError('请先读取原加入进度。');
    busy = true;
    try {
      if (await storage.read(key: _key) != jsonEncode(pending)) {
        loaded = false;
        throw StateError('加入进度发生变化，请重新读取。');
      }
      await _send();
    } finally {
      busy = false;
    }
  }

  Future<void> _send() async {
    final original = pending!;
    try {
      final value = await api.send('POST', '/family-invitations/accept',
          body: original['body'],
          idempotencyKey: original['key'],
          isCurrent: available);
      _check();
      if (value is! Json ||
          value['invitationId'] != (original['body'] as Json)['invitationId'] ||
          value['role'] != 'GUARDIAN' ||
          !{'ACTIVE', 'REVOKED'}.contains(value['currentState'])) _invalid();
      final tenant = _id(value['tenantId']);
      _number(value['memberVersion']);
      await storage.delete(key: _key);
      _check();
      pending = null;
      acceptedTenant = value['currentState'] == 'ACTIVE' ? tenant : null;
      revoked = value['currentState'] == 'REVOKED';
    } on ParentApiException catch (error) {
      if (_definite(error)) {
        _check();
        await storage.delete(key: _key);
        _check();
        pending = null;
        details = null;
        loaded = false;
      }
      rethrow;
    }
  }
}

extension on ParentApi {
  Future<Json> objectPreview(
      FamilyInvitationIntent intent, bool Function() available) async {
    final value = await send('POST', '/family-invitations/preview',
        body: {'invitationId': intent.id, 'token': intent.token},
        isCurrent: available);
    return value is Json ? value : _invalid();
  }
}

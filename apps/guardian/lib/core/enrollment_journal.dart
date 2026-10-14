import 'dart:convert';

import 'api.dart';

const _invalidCode = 'ENROLLMENT_RECOVERY_STORAGE_INVALID';
const _storageCode = 'ENROLLMENT_RECOVERY_STORAGE_FAILED';
const _pendingCode = 'ENROLLMENT_RECOVERY_PENDING';
const _roles = {'OWNER', 'GUARDIAN', 'ORG_ADMIN'};
const _platforms = {'ANDROID', 'ANDROID_TV'};
const _maximumSafeInteger = 9007199254740991;
const _fields = {
  'version',
  'actorId',
  'tenantId',
  'role',
  'requestId',
  'subjectId',
  'platform',
  'requestedMode',
  'createdAt',
};
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _requestUuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
final _controlCharacters = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

Never _invalid() => throw const ApiFailure(409, _invalidCode);

void _validateScope(EnrollmentScope scope) {
  if (scope.actorId.trim().isEmpty ||
      scope.actorId.length > 200 ||
      _controlCharacters.hasMatch(scope.actorId) ||
      scope.tenantId.length != 36 ||
      !_uuid.hasMatch(scope.tenantId) ||
      !_roles.contains(scope.role)) {
    _invalid();
  }
}

bool _sameScope(EnrollmentScope first, EnrollmentScope second) =>
    first.actorId == second.actorId &&
    first.tenantId == second.tenantId &&
    first.role == second.role;

bool _sameIntent(EnrollmentIntent first, EnrollmentIntent second) =>
    _sameScope(first.scope, second.scope) &&
    first.requestId == second.requestId &&
    first.subjectId == second.subjectId &&
    first.platform == second.platform &&
    first.createdAt == second.createdAt;

/// Immutable, non-secret enrollment recovery metadata.
class EnrollmentScope {
  final String actorId, tenantId, role;

  const EnrollmentScope({
    required this.actorId,
    required this.tenantId,
    required this.role,
  });

  String get key {
    _validateScope(this);
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode([actorId, tenantId, role])))
        .replaceAll('=', '');
    return 'ai-manager.enrollment.pending.v1.$encoded';
  }
}

class EnrollmentIntent {
  final EnrollmentScope scope;
  final String requestId, subjectId, platform;
  final int createdAt;

  const EnrollmentIntent({
    required this.scope,
    required this.requestId,
    required this.subjectId,
    required this.platform,
    required this.createdAt,
  });

  String get requestedMode => 'BYOD';

  void _validate() {
    _validateScope(scope);
    if (requestId.length != 36 ||
        !_requestUuid.hasMatch(requestId) ||
        subjectId.length != 36 ||
        !_uuid.hasMatch(subjectId) ||
        !_platforms.contains(platform) ||
        createdAt < 0 ||
        createdAt > _maximumSafeInteger) {
      _invalid();
    }
  }

  String encode() {
    _validate();
    return jsonEncode({
      'version': 1,
      'actorId': scope.actorId,
      'tenantId': scope.tenantId,
      'role': scope.role,
      'requestId': requestId,
      'subjectId': subjectId,
      'platform': platform,
      'requestedMode': requestedMode,
      'createdAt': createdAt,
    });
  }

  static EnrollmentIntent decode(String text,
      {required EnrollmentScope scope}) {
    _validateScope(scope);
    if (text.isEmpty || text.length > 4096) _invalid();
    try {
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic> ||
          value.length != _fields.length ||
          !value.keys.every(_fields.contains) ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['actorId'] is! String ||
          value['tenantId'] is! String ||
          value['role'] is! String ||
          value['requestId'] is! String ||
          value['subjectId'] is! String ||
          value['platform'] is! String ||
          value['requestedMode'] != 'BYOD' ||
          value['createdAt'] is! int) {
        _invalid();
      }
      final owner = EnrollmentScope(
          actorId: value['actorId'],
          tenantId: value['tenantId'],
          role: value['role']);
      if (!_sameScope(owner, scope)) _invalid();
      final intent = EnrollmentIntent(
          scope: owner,
          requestId: value['requestId'],
          subjectId: value['subjectId'],
          platform: value['platform'],
          createdAt: value['createdAt']);
      intent._validate();
      return intent;
    } catch (_) {
      // Stored text is untrusted. Never include its contents in the exception.
      _invalid();
    }
  }
}

abstract interface class EnrollmentJournal {
  Future<EnrollmentIntent?> read(EnrollmentScope scope);
  Future<void> write(EnrollmentIntent intent);
  Future<void> remove(EnrollmentIntent intent);
}

/// Synchronous string port lets one browser-tab mutation finish before awaiting.
abstract interface class EnrollmentStringStorage {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

class StoredEnrollmentJournal implements EnrollmentJournal {
  final EnrollmentStringStorage storage;

  const StoredEnrollmentJournal(this.storage);

  String? _read(String key) {
    try {
      return storage.read(key);
    } catch (_) {
      throw const ApiFailure(0, _storageCode);
    }
  }

  @override
  Future<EnrollmentIntent?> read(EnrollmentScope scope) async {
    final raw = _read(scope.key);
    // No TTL: an old unknown request must not become a new creation implicitly.
    return raw == null ? null : EnrollmentIntent.decode(raw, scope: scope);
  }

  @override
  Future<void> write(EnrollmentIntent intent) async {
    final encoded = intent.encode();
    final key = intent.scope.key;
    final existing = _read(key);
    if (existing != null &&
        !_sameIntent(
            EnrollmentIntent.decode(existing, scope: intent.scope), intent)) {
      throw const ApiFailure(409, _pendingCode);
    }
    // This entire read/check/write/readback sequence is synchronous in one tab.
    try {
      storage.write(key, encoded);
    } catch (_) {
      throw const ApiFailure(0, _storageCode);
    }
    if (_read(key) != encoded) throw const ApiFailure(0, _storageCode);
  }

  @override
  Future<void> remove(EnrollmentIntent intent) async {
    intent._validate();
    final key = intent.scope.key;
    final existing = _read(key);
    if (existing == null) return;
    final saved = EnrollmentIntent.decode(existing, scope: intent.scope);
    if (!_sameIntent(saved, intent)) return;
    try {
      storage.remove(key);
    } catch (_) {
      throw const ApiFailure(0, _storageCode);
    }
    if (_read(key) != null) throw const ApiFailure(0, _storageCode);
  }
}

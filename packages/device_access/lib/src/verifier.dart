import 'dart:convert';
import 'package:jose/jose.dart';
import 'models.dart';

class AccessWindowVerifier {
  final DeviceAccessScope scope;
  final int Function() nowMillis;
  final Map<String, JsonWebKey> _keys = {};
  AccessWindowVerifier(
      {required this.scope,
      required Map<String, dynamic> trustedKeys,
      required this.nowMillis}) {
    if (scope.issuer.isEmpty ||
        scope.issuer.length > 200 ||
        ![scope.tenantId, scope.subjectId, scope.deviceId, scope.registrationId]
            .every(accessId)) {
      throw ArgumentError('Invalid provisioned access scope');
    }
    try {
      final keys = trustedKeys['keys'];
      if (keys is! List || keys.isEmpty || keys.length > 32) {
        throw const FormatException();
      }
      for (final raw in keys) {
        if (raw is! Map<String, dynamic> ||
            raw['kty'] != 'EC' ||
            raw['crv'] != 'P-256' ||
            raw.keys
                .any({'d', 'p', 'q', 'dp', 'dq', 'qi', 'oth', 'k'}.contains) ||
            (raw['alg'] != null && raw['alg'] != 'ES256') ||
            (raw['use'] != null && raw['use'] != 'sig') ||
            raw['kid'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(raw['kid']) ||
            _keys.containsKey(raw['kid'])) throw const FormatException();
        final ops = raw['key_ops'];
        if (ops != null &&
            (ops is! List || ops.length != 1 || ops.single != 'verify')) {
          throw const FormatException();
        }
        _keys[raw['kid']] = JsonWebKey.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (_) {
      throw ArgumentError('Invalid public access trust ring');
    }
  }
  Future<VerifiedAccessWindow> verify(String compact,
      {bool restoration = false}) async {
    if (compact.length > 131072) {
      throw const AccessFailure('UNSUPPORTED_SCHEMA');
    }
    Map<String, dynamic> body;
    try {
      if (!RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')
          .hasMatch(compact)) throw const FormatException();
      final jws = JsonWebSignature.fromCompactSerialization(compact);
      final header = jws.unverifiedPayload.protectedHeader!.toJson();
      if (header['alg'] != 'ES256' ||
          header['typ'] != 'aimanager-access-window+jws' ||
          header.keys.any((k) => !{'alg', 'typ', 'kid'}.contains(k))) {
        throw const FormatException();
      }
      final key = _keys[header['kid']];
      if (key == null) throw const FormatException();
      final payload = await jws.getPayload(JsonWebKeyStore()..addKey(key),
          allowedAlgorithms: ['ES256']);
      final decoded = jsonDecode(payload.stringContent);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      body = decoded;
    } catch (_) {
      throw const AccessFailure('SIGNATURE_INVALID');
    }
    if (body['issuer'] != scope.issuer ||
        body['tenantId'] != scope.tenantId ||
        body['subjectId'] != scope.subjectId ||
        body['deviceId'] != scope.deviceId ||
        body['registrationId'] != scope.registrationId) {
      throw const AccessFailure('WRONG_DEVICE');
    }
    final rules = body['ruleIds'];
    if (body['schemaVersion'] is! int ||
        body['schemaVersion'] != 1 ||
        body['mode'] != 'CONFIGURE_ONLY' ||
        body['quotaEffect'] != 'UNCHANGED' ||
        !accessActions.contains(body['action']) ||
        !accessInteger(body['approvalVersion'], 1) ||
        ![
          'documentId',
          'requestId',
          'policyId',
          'baseVersionId',
          'applicationId'
        ].every((f) => accessId(body[f])) ||
        !['grantIssuedAt', 'absoluteNotAfter', 'documentIssuedAt']
            .every((f) => accessInteger(body[f], 0)) ||
        rules is! List ||
        rules.isEmpty ||
        rules.length > 20 ||
        rules.toSet().length != rules.length ||
        rules.any((r) =>
            r is! String || !RegExp(r'^[a-z][a-z0-9_-]{0,49}$').hasMatch(r)) ||
        body.keys.any((k) => !_fields.contains(k))) {
      throw const AccessFailure('UNSUPPORTED_SCHEMA');
    }
    final removal = body['action'] == 'REMOVE_ACCESS_WINDOW';
    final duration =
        (body['absoluteNotAfter'] as int) - (body['grantIssuedAt'] as int);
    if (duration < 1000 ||
        duration > 3600000 ||
        duration % 1000 != 0 ||
        body['documentIssuedAt'] < body['grantIssuedAt'] ||
        (removal
            ? !{'REVOKED', 'EXPIRED'}.contains(body['approvalState'])
            : body['approvalState'] != 'APPROVED_PENDING_DELIVERY')) {
      throw const AccessFailure('UNSUPPORTED_SCHEMA');
    }
    final value = VerifiedAccessWindow.internal(compact, body);
    if (!restoration && !removal) {
      try {
        value.requireCurrent(nowMillis());
      } on AccessFailure {
        rethrow;
      } catch (_) {
        throw const AccessFailure('CLOCK_UNTRUSTED');
      }
    }
    return value;
  }
}

const _fields = {
  'schemaVersion',
  'issuer',
  'documentId',
  'tenantId',
  'requestId',
  'approvalVersion',
  'approvalState',
  'subjectId',
  'deviceId',
  'registrationId',
  'policyId',
  'baseVersionId',
  'applicationId',
  'ruleIds',
  'action',
  'mode',
  'quotaEffect',
  'grantIssuedAt',
  'absoluteNotAfter',
  'documentIssuedAt'
};

import 'dart:convert';
import 'package:jose/jose.dart';
import 'models.dart';

/// Accepts an externally authenticated, pinned public ring. It never follows
/// key URLs or imports keys embedded in a received message. Hosts own ring
/// provisioning/rotation; revoking a key also affects restoration.
class ConfigurationVerifier {
  final DevicePolicyScope scope;
  final int Function() nowMillis;
  final Map<String, JsonWebKey> _keys = {};
  ConfigurationVerifier(
      {required this.scope,
      required Map<String, dynamic> trustedKeys,
      required this.nowMillis}) {
    if (scope.issuer.isEmpty ||
        scope.issuer.length > 200 ||
        ![scope.tenantId, scope.deviceId, scope.registrationId]
            .every(validId)) {
      throw ArgumentError('Invalid provisioned device scope');
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
            raw.containsKey('d') ||
            (raw['alg'] != null && raw['alg'] != 'ES256') ||
            (raw['use'] != null && raw['use'] != 'sig') ||
            raw['kid'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(raw['kid']) ||
            _keys.containsKey(raw['kid'])) {
          throw const FormatException();
        }
        final ops = raw['key_ops'];
        if (ops != null &&
            (ops is! List || ops.length != 1 || ops.single != 'verify')) {
          throw const FormatException();
        }
        _keys[raw['kid']] = JsonWebKey.fromJson(Map<String, dynamic>.from(raw));
      }
    } catch (_) {
      throw ArgumentError('Invalid public configuration trust ring');
    }
  }

  Future<VerifiedConfiguration> verify(String compact,
      {bool restoration = false}) async {
    if (compact.length > 1048576) {
      throw const ConfigurationFailure('UNSUPPORTED_SCHEMA');
    }
    Map<String, dynamic> body;
    try {
      if (!RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')
          .hasMatch(compact)) {
        throw const FormatException();
      }
      final jws = JsonWebSignature.fromCompactSerialization(compact);
      final header = jws.unverifiedPayload.protectedHeader!.toJson();
      if (header['alg'] != 'ES256' ||
          header['typ'] != 'aimanager-configuration+jws' ||
          header.keys.any((k) => !{'alg', 'typ', 'kid'}.contains(k))) {
        throw const FormatException();
      }
      final key = _keys[header['kid']];
      if (key == null) {
        throw const FormatException();
      }
      final payload = await jws.getPayload(JsonWebKeyStore()..addKey(key),
          allowedAlgorithms: ['ES256']);
      final decoded = jsonDecode(payload.stringContent);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException();
      }
      body = decoded;
    } catch (_) {
      throw const ConfigurationFailure('SIGNATURE_INVALID');
    }
    if (body['issuer'] != scope.issuer ||
        body['tenantId'] != scope.tenantId ||
        body['deviceId'] != scope.deviceId ||
        body['registrationId'] != scope.registrationId) {
      throw const ConfigurationFailure('IDENTITY_MISMATCH');
    }
    bool integer(dynamic n, int minimum) =>
        n is int && n >= minimum && n <= maxSafeInteger;
    if (body['schemaVersion'] != 1 ||
        body['purpose'] != 'CONFIGURATION' ||
        body['mode'] != 'CONFIGURE_ONLY' ||
        body['effectiveUntil'] != null ||
        !['policyId', 'versionId', 'deliveryId']
            .every((f) => validId(body[f])) ||
        !['cursor', 'sourceSequence'].every((f) => integer(body[f], 1)) ||
        !['issuedAt', 'deliveryExpiresAt'].every((f) => integer(body[f], 0)) ||
        !['UPSERT_CONFIGURATION', 'REMOVE_CONFIGURATION']
            .contains(body['action'])) {
      throw const ConfigurationFailure('UNSUPPORTED_SCHEMA');
    }
    if (body['deliveryExpiresAt'] <= body['issuedAt'] ||
        body['deliveryExpiresAt'] - body['issuedAt'] > 86400000) {
      throw const ConfigurationFailure('EXPIRED');
    }
    final document = body['document'];
    if (body['action'] == 'REMOVE_CONFIGURATION') {
      if (document != null) {
        throw const ConfigurationFailure('UNSUPPORTED_SCHEMA');
      }
    } else {
      if (document is! Map<String, dynamic> ||
          document['name'] is! String ||
          !['rules', 'applications', 'schedules', 'protectedPackageExemptions']
              .every((f) => document[f] is List)) {
        throw const ConfigurationFailure('UNSUPPORTED_SCHEMA');
      }
      for (final rule in document['rules']) {
        if (rule is! Map<String, dynamic> || rule['effectiveEffect'] != null) {
          throw const ConfigurationFailure('UNSUPPORTED_RULES');
        }
      }
    }
    final value = VerifiedConfiguration.internal(compact, freezeJson(body));
    if (!restoration) {
      value.requireFirstDelivery(nowMillis());
    }
    return value;
  }
}

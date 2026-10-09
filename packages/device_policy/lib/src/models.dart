import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Stable machine code only: parser errors must not echo signed child data.
class ConfigurationFailure implements Exception {
  final String code;
  const ConfigurationFailure(this.code);
  @override
  String toString() => 'ConfigurationFailure($code)';
}

/// Provisioned over the authenticated enrollment channel, never from a JWS.
class DevicePolicyScope {
  final String issuer, tenantId, deviceId, registrationId;
  const DevicePolicyScope(
      {required this.issuer,
      required this.tenantId,
      required this.deviceId,
      required this.registrationId});
  String get storageKey => sha256
      .convert(
          utf8.encode(jsonEncode([issuer, tenantId, deviceId, registrationId])))
      .toString();
}

/// Produced by the verifier in this package's receive path. The journal always
/// accepts raw compact JWS, so callers cannot bypass validation with this model.
/// No native execution or access allowance is derived from this object.
class VerifiedConfiguration {
  final String compact, envelopeHash;
  final Map<String, dynamic> fields;
  VerifiedConfiguration.internal(this.compact, this.fields)
      : envelopeHash = sha256.convert(utf8.encode(compact)).toString();
  String get policyId => fields['policyId'];
  String get versionId => fields['versionId'];
  String get deliveryId => fields['deliveryId'];
  String get action => fields['action'];
  int get cursor => fields['cursor'];
  int get sourceSequence => fields['sourceSequence'];
  int get issuedAt => fields['issuedAt'];
  int get deliveryExpiresAt => fields['deliveryExpiresAt'];
  Map<String, dynamic>? get document => fields['document'];
  bool get systemEnforced => false;
  void requireFirstDelivery(int nowMillis) {
    if (issuedAt > nowMillis || deliveryExpiresAt <= nowMillis) {
      throw const ConfigurationFailure('EXPIRED');
    }
  }
}

const maxSafeInteger = 9007199254740991;
bool validId(Object? value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);

dynamic freezeJson(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k, freezeJson(v))));
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(value.map(freezeJson));
  }
  return value;
}

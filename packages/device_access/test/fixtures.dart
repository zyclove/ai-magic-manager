import 'dart:convert';
import 'package:jose/jose.dart';
import 'package:device_access/device_access.dart';

const now = 1791528000000;
const tenant = '11111111-1111-4111-8111-111111111111';
const device = '22222222-2222-4222-8222-222222222222';
const registration = '33333333-3333-4333-8333-333333333333';
const subject = '77777777-7777-4777-8777-777777777777';
const policy = '44444444-4444-4444-8444-444444444444';
const version = '55555555-5555-4555-8555-555555555555';
const document = '66666666-6666-4666-8666-666666666666';
const request = '88888888-8888-4888-8888-888888888888';
const application = '99999999-9999-4999-8999-999999999999';
const scope = DeviceAccessScope(
    issuer: 'ai-manager',
    tenantId: tenant,
    subjectId: subject,
    deviceId: device,
    registrationId: registration);
JsonWebKey newKey([String id = 'access-test']) => JsonWebKey.fromJson({
      ...JsonWebKey.generate('ES256').toJson(),
      'kid': id,
      'alg': 'ES256',
      'use': 'sig'
    });
Map<String, dynamic> publicRing(JsonWebKey key) {
  final fields = Map<String, dynamic>.from(key.toJson())..remove('d');
  fields['key_ops'] = ['verify'];
  return {
    'keys': [fields]
  };
}

Map<String, dynamic> envelope([Map<String, dynamic> changes = const {}]) => {
      'schemaVersion': 1,
      'issuer': 'ai-manager',
      'documentId': document,
      'tenantId': tenant,
      'requestId': request,
      'approvalVersion': 1,
      'approvalState': 'APPROVED_PENDING_DELIVERY',
      'subjectId': subject,
      'deviceId': device,
      'registrationId': registration,
      'policyId': policy,
      'baseVersionId': version,
      'applicationId': application,
      'ruleIds': ['game'],
      'action': 'UPSERT_ACCESS_WINDOW',
      'mode': 'CONFIGURE_ONLY',
      'quotaEffect': 'UNCHANGED',
      'grantIssuedAt': now - 1000,
      'absoluteNotAfter': now + 299000,
      'documentIssuedAt': now - 500,
      ...changes
    };
String sign(JsonWebKey key, Map<String, dynamic> payload,
    {String type = 'aimanager-access-window+jws',
    Map<String, dynamic> headers = const {}}) {
  final builder = JsonWebSignatureBuilder()
    ..stringContent = jsonEncode(payload);
  builder.setProtectedHeader('typ', type);
  for (final e in headers.entries) {
    builder.setProtectedHeader(e.key, e.value);
  }
  builder.addRecipient(key, algorithm: 'ES256');
  return builder.build().toCompactSerialization();
}

AccessDocument transport(String compact,
    {Map<String, dynamic> fields = const {}, Map<String, dynamic>? payload}) {
  final e = payload ?? envelope();
  return AccessDocument.fromJson({
    'documentId': e['documentId'],
    'requestId': e['requestId'],
    'approvalVersion': e['approvalVersion'],
    'action': e['action'],
    'signedDocument': compact,
    'documentIssuedAt': e['documentIssuedAt'],
    'deliveryAttempt': 1,
    'deliveryState': 'SIGNED',
    'reasonCode': null,
    'retryStatus': 'NOT_NEEDED',
    'retryAfter': null,
    ...fields
  });
}

import 'dart:convert';
import 'package:jose/jose.dart';
import 'package:device_policy/device_policy.dart';

const now = 1791528000000;
const tenant = '11111111-1111-4111-8111-111111111111';
const device = '22222222-2222-4222-8222-222222222222';
const registration = '33333333-3333-4333-8333-333333333333';
const policy = '44444444-4444-4444-8444-444444444444';
const version = '55555555-5555-4555-8555-555555555555';
const delivery = '66666666-6666-4666-8666-666666666666';
const scope = DevicePolicyScope(
    issuer: 'ai-manager',
    tenantId: tenant,
    deviceId: device,
    registrationId: registration);

JsonWebKey newKey([String kid = 'test-key']) => JsonWebKey.fromJson({
      ...JsonWebKey.generate('ES256').toJson(),
      'kid': kid,
      'alg': 'ES256',
      'use': 'sig'
    });
Map<String, dynamic> publicRing(JsonWebKey key) {
  final value = Map<String, dynamic>.from(key.toJson())..remove('d');
  value['key_ops'] = ['verify'];
  return {
    'keys': [value]
  };
}

Map<String, dynamic> envelope([Map<String, dynamic> changes = const {}]) => {
      'schemaVersion': 1,
      'issuer': 'ai-manager',
      'purpose': 'CONFIGURATION',
      'mode': 'CONFIGURE_ONLY',
      'action': 'UPSERT_CONFIGURATION',
      'tenantId': tenant,
      'deviceId': device,
      'registrationId': registration,
      'policyId': policy,
      'versionId': version,
      'sourceSequence': 1,
      'cursor': 1,
      'deliveryId': delivery,
      'issuedAt': now - 1000,
      'deliveryExpiresAt': now + 60000,
      'effectiveUntil': null,
      'document': {
        'name': '学习时间',
        'rules': [],
        'applications': [],
        'schedules': [],
        'protectedPackageExemptions': ['com.example.emergency']
      },
      ...changes
    };
String sign(JsonWebKey key, Map<String, dynamic> payload,
    {String type = 'aimanager-configuration+jws',
    Map<String, dynamic> headers = const {}}) {
  final builder = JsonWebSignatureBuilder()
    ..stringContent = jsonEncode(payload);
  builder.setProtectedHeader('typ', type);
  for (final entry in headers.entries) {
    builder.setProtectedHeader(entry.key, entry.value);
  }
  builder.addRecipient(key, algorithm: 'ES256');
  return builder.build().toCompactSerialization();
}

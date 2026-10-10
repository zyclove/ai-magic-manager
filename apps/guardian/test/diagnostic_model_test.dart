import 'package:flutter_test/flutter_test.dart';
import '../lib/core/api.dart';
import '../lib/core/device_diagnostic.dart';

import 'fixtures/diagnostic.dart';

DeviceDiagnostic parse(Object? value,
        {String expectedRegistration = registration}) =>
    DeviceDiagnostic.parse(value,
        tenantId: tenant,
        deviceId: device,
        registrationId: expectedRegistration);

final invalid = isA<ApiFailure>()
    .having((e) => e.code, 'code', 'INVALID_DIAGNOSTIC_RESPONSE');

void main() {
  test('parses typed immutable diagnostic evidence', () {
    final result = parse(fixture());
    expect(result.agent.value, '1.2.3');
    expect(result.server.status, 'UNREPORTED');
    expect(result.capabilities.single.reportedSupported, isTrue);
    expect(
        result.configurations.single.deliveryState, 'DEVICE_REPORTED_STORED');
    expect(() => result.capabilities.clear(), throwsUnsupportedError);
    expect(() => result.configurations.clear(), throwsUnsupportedError);
  });
  test('rejects old registration, other workspace and other device', () {
    expect(() => parse(fixture(), expectedRegistration: correlation),
        throwsA(invalid));
    for (final key in ['tenantId', 'deviceId', 'registrationId']) {
      final value = fixture();
      (value['scope'] as Map)[key] = correlation;
      expect(() => parse(value), throwsA(invalid));
    }
  });
  test('rejects unsupported schema and fabricated execution proof', () {
    for (final field in ['schemaVersion', 'evidenceStatus']) {
      final value = fixture();
      value[field] = field == 'schemaVersion' ? 2 : 'ENFORCED';
      expect(() => parse(value), throwsA(invalid));
    }
  });
  test('does not retain additional free text fields', () {
    final value = fixture();
    value['privateText'] = 'SECRET';
    (value['device'] as Map)['displayName'] = 'SECRET';
    final result = parse(value);
    expect(result.platform, 'ANDROID');
    expect(result.toString(), isNot(contains('SECRET')));
  });
  test('rejects free text version and inconsistent redaction', () {
    for (final version in [
      {'value': '14 https://private.example', 'status': 'REPORTED'},
      {'value': '14', 'status': 'REDACTED'},
      {'value': null, 'status': 'REPORTED'},
    ]) {
      final value = fixture();
      (value['versions'] as Map)['os'] = version;
      expect(() => parse(value), throwsA(invalid));
    }
  });
  test('rejects unknown or duplicate capability keys', () {
    final unknown = fixture();
    (unknown['capabilities'][0] as Map)['key'] = 'private.text';
    expect(() => parse(unknown), throwsA(invalid));
    final duplicate = fixture();
    (duplicate['capabilities'] as List).add(duplicate['capabilities'][0]);
    expect(() => parse(duplicate), throwsA(invalid));
  });
  test('rejects unknown enum and unsafe evidence timestamp', () {
    for (final entry in {
      'grantStatus': 'SECRET',
      'checkedAt': now + 60000,
      'reportedSupported': 'true'
    }.entries) {
      final value = fixture();
      (value['capabilities'][0] as Map)[entry.key] = entry.value;
      expect(() => parse(value), throwsA(invalid));
    }
  });
  test('rejects malformed policy hash and unknown rejection text', () {
    for (final entry in {
      'policyHash': 'SECRET',
      'rejectionCode': 'SECRET_ERROR',
      'sourceSequence': 0
    }.entries) {
      final value = fixture();
      (value['configurations'][0] as Map)[entry.key] = entry.value;
      expect(() => parse(value), throwsA(invalid));
    }
  });
  test('rejects duplicate configuration and oversized collection', () {
    for (final count in [2, 101]) {
      final value = fixture();
      value['configurations'] = List.filled(count, value['configurations'][0]);
      expect(() => parse(value), throwsA(invalid));
    }
  });
  test('rejects malformed identity, omitted count and generation time', () {
    for (final entry in {
      'correlationId': 'https://private.example',
      'omittedCapabilityCount': -1,
      'generatedAt': 9007199254740992
    }.entries) {
      final value = fixture();
      value[entry.key] = entry.value;
      expect(() => parse(value), throwsA(invalid));
    }
  });
}

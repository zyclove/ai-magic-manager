import 'dart:convert';
import 'package:device_access/device_access.dart';
import 'package:jose/jose.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

Matcher failure(String code) =>
    isA<AccessFailure>().having((e) => e.code, 'code', code);
void main() {
  late JsonWebKey key;
  late AccessWindowVerifier verifier;
  setUpAll(() => key = newKey());
  setUp(() => verifier = AccessWindowVerifier(
      scope: scope, trustedKeys: publicRing(key), nowMillis: () => now));
  test('valid scoped access configuration is immutable and never enforced',
      () async {
    final value = await verifier.verify(sign(key, envelope()));
    expect(value.requestId, request);
    expect(value.ruleIds, ['game']);
    expect(value.systemEnforced, isFalse);
    expect(() => value.fields['mode'] = 'ENFORCE', throwsUnsupportedError);
    expect(() => value.ruleIds.add('other'), throwsUnsupportedError);
  });
  test('payload tampering is rejected before schema processing', () async {
    final segments = sign(key, envelope()).split('.');
    segments[1] = base64Url
        .encode(utf8.encode(jsonEncode(envelope({'applicationId': tenant}))))
        .replaceAll('=', '');
    await expectLater(verifier.verify(segments.join('.')),
        throwsA(failure('SIGNATURE_INVALID')));
  });
  test('configuration documents and embedded keys cannot cross JOSE purpose',
      () async {
    for (final compact in [
      sign(key, envelope(), type: 'aimanager-configuration+jws'),
      sign(key, envelope(), headers: {'jku': 'https://invalid.example/key'}),
      sign(newKey('unknown'), envelope())
    ]) {
      await expectLater(
          verifier.verify(compact), throwsA(failure('SIGNATURE_INVALID')));
    }
  });
  for (final field in [
    'issuer',
    'tenantId',
    'subjectId',
    'deviceId',
    'registrationId'
  ]) {
    test('provisioned $field is checked independently', () async {
      await expectLater(
          verifier.verify(sign(key,
              envelope({field: field == 'issuer' ? 'foreign' : application}))),
          throwsA(failure('WRONG_DEVICE')));
    });
  }
  final invalid = <String, Map<String, dynamic>>{
    'mode': {'mode': 'ENFORCE'},
    'quota': {'quotaEffect': 'EXTEND'},
    'version': {'approvalVersion': 0},
    'unsafe number': {'approvalVersion': 9007199254740992},
    'fractional': {'documentIssuedAt': 1.5},
    'rules': {'ruleIds': []},
    'duplicate rules': {
      'ruleIds': ['game', 'game']
    },
    'rule syntax': {
      'ruleIds': ['GAME']
    },
    'approval state': {'approvalState': 'REVOKED'},
    'duration': {'absoluteNotAfter': now + 3600001},
    'document before grant': {'documentIssuedAt': now - 2000},
    'UUID': {'baseVersionId': 'INVALID'}
  };
  for (final e in invalid.entries) {
    test('rejects malformed ${e.key}', () async {
      await expectLater(verifier.verify(sign(key, envelope(e.value))),
          throwsA(failure('UNSUPPORTED_SCHEMA')));
    });
  }
  test('upsert expires exactly at its original fixed deadline', () async {
    final v = AccessWindowVerifier(
        scope: scope,
        trustedKeys: publicRing(key),
        nowMillis: () => now + 299000);
    await expectLater(
        v.verify(sign(key, envelope())), throwsA(failure('EXPIRED')));
    expect(
        (await v.verify(sign(key, envelope()), restoration: true))
            .absoluteNotAfter,
        now + 299000);
  });
  test('removal remains meaningful after expiry and during a clock rollback',
      () async {
    final payload = envelope({
      'action': 'REMOVE_ACCESS_WINDOW',
      'approvalState': 'REVOKED',
      'approvalVersion': 2,
      'documentIssuedAt': now + 600000
    });
    expect((await verifier.verify(sign(key, payload))).isRemoval, isTrue);
  });
  test('private, duplicate and ambiguous verification rings are rejected', () {
    final public = publicRing(key)['keys'][0];
    for (final ring in [
      {
        'keys': [key.toJson()]
      },
      {
        'keys': [public, public]
      },
      {
        'keys': [
          {
            ...public,
            'key_ops': ['sign']
          }
        ]
      }
    ]) {
      expect(
          () => AccessWindowVerifier(
              scope: scope, trustedKeys: ring, nowMillis: () => now),
          throwsArgumentError);
    }
  });
  test(
      'authenticated transport metadata must still match the verified document',
      () async {
    final raw = sign(key, envelope());
    final verified = await verifier.verify(raw);
    expect(
        () => transport(raw, fields: {'requestId': application})
            .requireMatch(verified),
        throwsA(failure('TRANSPORT_MISMATCH')));
    expect(() => transport(raw, fields: {'deliveryAttempt': 11}),
        throwsA(failure('TRANSPORT_INVALID')));
    expect(() => transport(raw, fields: {'deliveryState': 'REJECTED'}),
        throwsA(failure('TRANSPORT_INVALID')));
  });
}

import 'dart:convert';
import 'package:device_policy/device_policy.dart';
import 'package:jose/jose.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

Matcher failure(String code) =>
    isA<ConfigurationFailure>().having((e) => e.code, 'code', code);
void main() {
  late JsonWebKey key;
  late ConfigurationVerifier verifier;
  setUpAll(() {
    key = newKey();
  });
  setUp(() {
    verifier = ConfigurationVerifier(
        scope: scope, trustedKeys: publicRing(key), nowMillis: () => now);
  });
  test(
      'valid ES256 configuration retains device scope and never reports enforcement',
      () async {
    final value = await verifier.verify(sign(key, envelope()));
    expect(value.policyId, policy);
    expect(value.cursor, 1);
    expect(value.systemEnforced, isFalse);
    expect(value.document!['name'], '学习时间');
  });
  test('payload substitution fails actual signature verification', () async {
    final parts = sign(key, envelope()).split('.');
    parts[1] = base64Url
        .encode(utf8.encode(jsonEncode(envelope({'cursor': 2}))))
        .replaceAll('=', '');
    await expectLater(verifier.verify(parts.join('.')),
        throwsA(failure('SIGNATURE_INVALID')));
  });
  test('unknown key and foreign signature are rejected', () async {
    await expectLater(verifier.verify(sign(newKey('foreign'), envelope())),
        throwsA(failure('SIGNATURE_INVALID')));
  });
  test('unsigned and symmetric tokens cannot reuse an EC trust identity',
      () async {
    for (final algorithm in ['none', 'HS256']) {
      final builder = JsonWebSignatureBuilder()
        ..stringContent = jsonEncode(envelope());
      builder.setProtectedHeader('typ', 'aimanager-configuration+jws');
      builder.setProtectedHeader('kid', 'test-key');
      final symmetric = algorithm == 'none'
          ? null
          : JsonWebKey.fromJson(
              {...JsonWebKey.generate('HS256').toJson(), 'kid': 'test-key'});
      builder.addRecipient(symmetric, algorithm: algorithm);
      await expectLater(
          verifier.verify(builder.build().toCompactSerialization()),
          throwsA(failure('SIGNATURE_INVALID')));
    }
  });
  test('cleanup and quota signatures cannot be reused as configuration',
      () async {
    for (final type in [
      'aimanager-cleanup-command+jws',
      'aimanager-quota-lease+jws'
    ]) {
      await expectLater(verifier.verify(sign(key, envelope(), type: type)),
          throwsA(failure('SIGNATURE_INVALID')));
    }
  });
  test('untrusted embedded keys and unsupported critical headers are refused',
      () async {
    for (final headers in [
      {'jku': 'https://attacker.invalid/keys'},
      {
        'crit': ['custom'],
        'custom': true
      },
      {'b64': false}
    ]) {
      await expectLater(
          verifier.verify(sign(key, envelope(), headers: headers)),
          throwsA(failure('SIGNATURE_INVALID')));
    }
  });
  test('all registration identifiers and issuer must match', () async {
    for (final field in ['tenantId', 'deviceId', 'registrationId', 'issuer']) {
      await expectLater(
          verifier.verify(sign(
              key, envelope({field: field == 'issuer' ? 'other' : policy}))),
          throwsA(failure('IDENTITY_MISMATCH')));
    }
  });
  test('unknown schema or enforcement mode cannot enter the current protocol',
      () async {
    for (final change in [
      {'schemaVersion': 2},
      {'mode': 'ENFORCE'},
      {'purpose': 'CLEANUP'},
      {'effectiveUntil': now + 5000}
    ]) {
      await expectLater(verifier.verify(sign(key, envelope(change))),
          throwsA(failure('UNSUPPORTED_SCHEMA')));
    }
  });
  test(
      'first delivery expiry does not expire an already cached persistent configuration',
      () async {
    final compact = sign(key, envelope({'deliveryExpiresAt': now}));
    await expectLater(verifier.verify(compact), throwsA(failure('EXPIRED')));
    expect(
        (await verifier.verify(compact, restoration: true)).policyId, policy);
  });
  test('future issuance and invalid lifetimes fail', () async {
    for (final change in [
      {'issuedAt': now + 1},
      {'deliveryExpiresAt': now - 2000},
      {'issuedAt': now - 90000000}
    ]) {
      await expectLater(verifier.verify(sign(key, envelope(change))),
          throwsA(failure('EXPIRED')));
    }
  });
  test('unsafe integers, malformed IDs and unknown action fail', () async {
    for (final change in [
      {'cursor': 9007199254740992},
      {'sourceSequence': 1.5},
      {'policyId': 'invalid'},
      {'action': 'WIPE_DEVICE'}
    ]) {
      await expectLater(verifier.verify(sign(key, envelope(change))),
          throwsA(failure('UNSUPPORTED_SCHEMA')));
    }
  });
  test('remove action has no document and is limited to one configuration',
      () async {
    expect(
        (await verifier.verify(sign(
                key,
                envelope(
                    {'action': 'REMOVE_CONFIGURATION', 'document': null}))))
            .document,
        isNull);
    await expectLater(
        verifier
            .verify(sign(key, envelope({'action': 'REMOVE_CONFIGURATION'}))),
        throwsA(failure('UNSUPPORTED_SCHEMA')));
  });
  test('non-null effective effects are never silently executed', () async {
    final doc = Map<String, dynamic>.from(envelope()['document']);
    doc['rules'] = [
      {'kind': 'APPLICATION', 'effectiveEffect': 'BLOCK'}
    ];
    await expectLater(verifier.verify(sign(key, envelope({'document': doc}))),
        throwsA(failure('UNSUPPORTED_RULES')));
  });
  test('oversized messages fail before JOSE parsing', () async {
    await expectLater(
        verifier.verify('x' * 1048577), throwsA(failure('UNSUPPORTED_SCHEMA')));
  });
  test('private or ambiguous verification rings are not accepted', () {
    for (final ring in [
      {
        'keys': [key.toJson()]
      },
      {
        'keys': [...publicRing(key)['keys'], ...publicRing(key)['keys']]
      }
    ]) {
      expect(
          () => ConfigurationVerifier(
              scope: scope, trustedKeys: ring, nowMillis: () => now),
          throwsArgumentError);
    }
  });
}

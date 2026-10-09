import 'dart:convert';
import 'package:device_identity/device_identity.dart';
import 'package:jose/jose.dart';
import 'package:test/test.dart';

void main() {
  const keys = JoseDeviceEnrollmentKeys();
  const id = '11111111-1111-4111-8111-111111111111';
  final secret = 'T' * 43;
  const now = 1791528000000;
  test(
      'proof model refuses private key material before a transport can send it',
      () async {
    final handle = await keys.generateHandle();
    expect(() => EnrollmentProof(handle, 'x.y.z'),
        throwsA(isA<DeviceIdentityFailure>()));
  });
  test(
      'standard-width key and public VERIFY-only proof validate with mature JOSE',
      () async {
    final handle = await keys.generateHandle();
    final private = jsonDecode(handle);
    for (final name in ['x', 'y', 'd']) {
      expect(private[name].length, 43);
      expect(
          base64Url.decode(base64Url.normalize(private[name])), hasLength(32));
    }
    final proof = await keys.proof(
        handle, id, secret, 'ai-manager:enrollment-claim', now);
    final public = Map<String, dynamic>.from(jsonDecode(proof.publicKeyJwk));
    expect(public.containsKey('d'), isFalse);
    expect(public['key_ops'], ['verify']);
    final ring = JsonWebKeyStore()..addKey(JsonWebKey.fromJson(public));
    expect(
        await JsonWebSignature.fromCompactSerialization(proof.compact)
            .verify(ring),
        isTrue);
    final header = jsonDecode(utf8.decode(
        base64Url.decode(base64Url.normalize(proof.compact.split('.').first))));
    expect(header, {'alg': 'ES256', 'typ': 'JWT'});
    expect(proof.toString(), isNot(contains(secret)));
  });
  test('same-key recovery uses a fresh UUID and dedicated audience', () async {
    final handle = await keys.generateHandle();
    final a = await keys.proof(
        handle, id, secret, 'ai-manager:enrollment-claim', now);
    final b = await keys.proof(
        handle, id, secret, 'ai-manager:enrollment-recover', now);
    final ac = jsonDecode(JsonWebSignature.fromCompactSerialization(a.compact)
        .unverifiedPayload
        .stringContent);
    final bc = jsonDecode(JsonWebSignature.fromCompactSerialization(b.compact)
        .unverifiedPayload
        .stringContent);
    expect(a.publicKeyJwk, b.publicKeyJwk);
    expect(bc['jti'], isNot(ac['jti']));
    expect(bc['aud'], ['ai-manager:enrollment-recover']);
    expect(bc['exp'] - bc['iat'], 60);
  });
  test(
      'unsupported purpose and corrupted private handle fail without exposing material',
      () async {
    final handle = await keys.generateHandle();
    await expectLater(keys.proof(handle, id, secret, 'admin', now),
        throwsA(isA<DeviceIdentityFailure>()));
    await expectLater(
        keys.proof(
            '{"d":"$secret"}', id, secret, 'ai-manager:enrollment-claim', now),
        throwsA(isA<DeviceIdentityFailure>()
            .having((e) => e.toString(), 'redacted', isNot(contains(secret)))));
  });
  test('ticket validates canonical identifiers and never prints its secret',
      () {
    final ticket = EnrollmentTicket(
        tenantId: id, enrollmentId: id, token: secret, expiresAt: now);
    expect(ticket.toString(), isNot(contains(secret)));
    expect(
        () => EnrollmentTicket(
            tenantId: 'tenant',
            enrollmentId: id,
            token: secret,
            expiresAt: now),
        throwsArgumentError);
    expect(
        () => EnrollmentTicket(
            tenantId: id, enrollmentId: id, token: 'jwt', expiresAt: now),
        throwsArgumentError);
    expect(
        () => EnrollmentTicket(
            tenantId: id,
            enrollmentId: id,
            token: secret,
            expiresAt: maxSafeInteger + 1),
        throwsArgumentError);
  });
}

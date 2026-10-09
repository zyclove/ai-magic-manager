import 'dart:convert';
import 'package:jose/jose.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';

class EnrollmentProof {
  final String publicKeyJwk, compact;
  EnrollmentProof(this.publicKeyJwk, this.compact) {
    try {
      if (publicKeyJwk.length > 2048 || compact.length > 8192) {
        throw const FormatException('Proof limit');
      }
      final key = Map<String, dynamic>.from(jsonDecode(publicKeyJwk));
      final operations = key['key_ops'];
      if (key['kty'] != 'EC' ||
          key['crv'] != 'P-256' ||
          !validSecret(key['x']) ||
          !validSecret(key['y']) ||
          key.keys.any((field) => !const {
                'kty',
                'crv',
                'x',
                'y',
                'alg',
                'use',
                'kid',
                'key_ops'
              }.contains(field)) ||
          key['alg'] != null && key['alg'] != 'ES256' ||
          key['use'] != null && key['use'] != 'sig' ||
          key['kid'] != null && !boundedText(key['kid'], 100) ||
          operations != null &&
              (operations is! List ||
                  operations.isEmpty ||
                  operations.any((op) => op != 'verify'))) {
        throw const FormatException('Public signing key required');
      }
      final segments = compact.split('.');
      if (segments.length != 3 ||
          segments.any((p) => !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(p))) {
        throw const FormatException('Compact proof required');
      }
      final header = Map<String, dynamic>.from(jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(segments.first)))));
      if (header['alg'] != 'ES256' ||
          header['typ'] != 'JWT' ||
          header.keys
              .any((key) => !const {'alg', 'typ', 'kid'}.contains(key))) {
        throw const FormatException('Unsupported proof type');
      }
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }
  @override
  String toString() => 'EnrollmentProof(redacted)';
}

/// A native provider may keep only an alias in the encrypted identity record.
/// Its handle must remain usable after host/process recreation.
abstract interface class DeviceEnrollmentKeys {
  Future<String> generateHandle();
  Future<EnrollmentProof> proof(String handle, String enrollmentId,
      String token, String purpose, int nowMillis);
}

/// Mature JOSE software-key adapter. The handle contains PRIVATE JWK material;
/// the manager writes it only to DeviceSecretStore. This is not non-exportable
/// hardware key generation, attestation or a device-owner capability.
class JoseDeviceEnrollmentKeys implements DeviceEnrollmentKeys {
  const JoseDeviceEnrollmentKeys();
  @override
  Future<String> generateHandle() async {
    try {
      final value =
          Map<String, dynamic>.from(JsonWebKey.generate('ES256').toJson());
      // This SDK exports padded/minimal integers. JWK P-256 coordinates are
      // fixed 32-byte base64url values; normalize SERIALIZATION, not ECDSA.
      for (final field in ['x', 'y', 'd']) {
        final bytes = base64Url.decode(base64Url.normalize(value[field]));
        if (bytes.isEmpty || bytes.length > 32) {
          throw const FormatException('Invalid P-256 width');
        }
        value[field] = base64Url.encode([
          ...List<int>.filled(32 - bytes.length, 0),
          ...bytes
        ]).replaceAll('=', '');
      }
      return jsonEncode(value);
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }

  @override
  Future<EnrollmentProof> proof(String handle, String enrollmentId,
      String token, String purpose, int nowMillis) async {
    if (!validUuid(enrollmentId) ||
        !validSecret(token) ||
        !safeInteger(nowMillis, minimum: 1) ||
        !const {'ai-manager:enrollment-claim', 'ai-manager:enrollment-recover'}
            .contains(purpose)) {
      throw const DeviceIdentityFailure('IDENTITY_STATE_INVALID');
    }
    try {
      final map = Map<String, dynamic>.from(jsonDecode(handle));
      if (map['kty'] != 'EC' ||
          map['crv'] != 'P-256' ||
          !validSecret(map['d']) ||
          !validSecret(map['x']) ||
          !validSecret(map['y'])) {
        throw const FormatException('Invalid private key');
      }
      final key = JsonWebKey.fromJson(map);
      final public = Map<String, dynamic>.from(map)..remove('d');
      public['key_ops'] = ['verify'];
      final issued = nowMillis ~/ 1000;
      final builder = JsonWebSignatureBuilder()
        ..stringContent = jsonEncode({
          'sub': enrollmentId,
          'aud': [purpose],
          'nonce': token,
          'iat': issued,
          'exp': issued + 60,
          'jti': const Uuid().v4()
        });
      builder.setProtectedHeader('typ', 'JWT');
      builder.addRecipient(key, algorithm: 'ES256');
      return EnrollmentProof(
          jsonEncode(public), builder.build().toCompactSerialization());
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }
}

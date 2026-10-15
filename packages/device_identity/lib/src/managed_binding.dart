import 'dart:convert';
import 'dart:math' show min;
import 'package:jose/jose.dart';
import 'package:uuid/uuid.dart';
import 'models.dart';

const managedAgentAudience = 'ai-manager:managed-agent-binding';
const managedAgentFeedbackKey = 'ai_manager.binding.v1';
final _bindingUuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// Server-issued one-use challenge. Never log, persist, or show its nonce.
final class ManagedAgentChallenge {
  final String id, nonce;
  final int createdAt, expiresAt;
  ManagedAgentChallenge._(this.id, this.nonce, this.createdAt, this.expiresAt);
  factory ManagedAgentChallenge.fromJson(Map<String, dynamic> value) {
    try {
      const fields = {
        'challengeId',
        'nonce',
        'audience',
        'createdAt',
        'expiresAt'
      };
      if (value.length != fields.length ||
          !value.keys.every(fields.contains) ||
          value['challengeId'] is! String ||
          !_bindingUuid.hasMatch(value['challengeId']) ||
          value['audience'] != managedAgentAudience ||
          value['nonce'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value['nonce']) ||
          base64Url
                  .encode(base64Url.decode(base64Url.normalize(value['nonce'])))
                  .replaceAll('=', '') !=
              value['nonce'] ||
          !safeInteger(value['createdAt']) ||
          !safeInteger(value['expiresAt']) ||
          value['expiresAt'] <= value['createdAt'] ||
          value['expiresAt'] - value['createdAt'] > 600000) {
        throw const FormatException();
      }
      return ManagedAgentChallenge._(value['challengeId'], value['nonce'],
          value['createdAt'], value['expiresAt']);
    } catch (_) {
      throw const DeviceIdentityFailure('MANAGED_CHALLENGE_INVALID');
    }
  }
  void requireCurrent(int nowMillis) {
    if (!safeInteger(nowMillis, minimum: 1) || nowMillis < createdAt - 30000) {
      throw const DeviceIdentityFailure('CLOCK_UNTRUSTED');
    }
    // JWT exp has second precision: never round beyond the server deadline.
    if (nowMillis >= (expiresAt ~/ 1000) * 1000) {
      throw const DeviceIdentityFailure('MANAGED_CHALLENGE_EXPIRED');
    }
  }

  @override
  String toString() => 'ManagedAgentChallenge(redacted)';
}

/// Minimal, short-lived feedback data. Identity verification remains server-side.
final class ManagedAgentBindingProof {
  final String compact, challengeId;
  final int expiresAt;
  ManagedAgentBindingProof(
      this.compact, ManagedAgentChallenge challenge, int nowMillis)
      : challengeId = challenge.id,
        expiresAt = _validate(compact, challenge, nowMillis);
  static int _validate(
      String compact, ManagedAgentChallenge challenge, int now) {
    challenge.requireCurrent(now);
    try {
      if (compact.length > 1000) throw const FormatException();
      final parts = compact.split('.');
      if (parts.length != 3) throw const FormatException();
      List<int> bytes(String part) {
        if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(part)) {
          throw const FormatException();
        }
        final result = base64Url.decode(base64Url.normalize(part));
        if (base64Url.encode(result).replaceAll('=', '') != part) {
          throw const FormatException();
        }
        return result;
      }

      final header = jsonDecode(utf8.decode(bytes(parts[0])));
      final claims = jsonDecode(utf8.decode(bytes(parts[1])));
      const fields = {'sub', 'nonce', 'aud', 'iat', 'exp', 'jti'};
      if (bytes(parts[2]).length != 64 ||
          header is! Map<String, dynamic> ||
          header.length != 2 ||
          header['alg'] != 'ES256' ||
          header['typ'] != 'JWT' ||
          claims is! Map<String, dynamic> ||
          claims.length != fields.length ||
          !claims.keys.every(fields.contains) ||
          claims['sub'] != challenge.id ||
          claims['nonce'] != challenge.nonce ||
          claims['aud'] is! List ||
          (claims['aud'] as List).length != 1 ||
          claims['aud'][0] != managedAgentAudience ||
          claims['jti'] is! String ||
          !_bindingUuid.hasMatch(claims['jti']) ||
          !safeInteger(claims['iat']) ||
          !safeInteger(claims['exp']) ||
          claims['iat'] != now ~/ 1000 ||
          claims['exp'] <= claims['iat'] ||
          claims['exp'] - claims['iat'] > 600 ||
          claims['exp'] * 1000 > challenge.expiresAt) {
        throw const FormatException();
      }
      return (claims['exp'] as int) * 1000;
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }

  @override
  String toString() => 'ManagedAgentBindingProof(redacted)';
}

/// Optional original-registration-key operation. Never generate a replacement key.
abstract interface class DeviceManagedBindingKeys {
  Future<ManagedAgentBindingProof> managedBindingProof(
      String handle, ManagedAgentChallenge challenge, int nowMillis);
}

/// JOSE adapter for existing encrypted software-key registrations and local checks.
/// Android registrations use the native AndroidKeyStore adapter instead.
class JoseManagedBindingSigner {
  static Future<ManagedAgentBindingProof> sign(
      String handle, ManagedAgentChallenge challenge, int nowMillis) async {
    challenge.requireCurrent(nowMillis);
    try {
      final material = Map<String, dynamic>.from(jsonDecode(handle));
      if (material['kty'] != 'EC' ||
          material['crv'] != 'P-256' ||
          !validSecret(material['d']) ||
          !validSecret(material['x']) ||
          !validSecret(material['y'])) throw const FormatException();
      // The binding protocol permits no kid or caller-provided header fields.
      final key = JsonWebKey.fromJson({
        for (final name in ['kty', 'crv', 'x', 'y', 'd']) name: material[name]
      });
      final issued = nowMillis ~/ 1000;
      final builder = JsonWebSignatureBuilder()
        ..stringContent = jsonEncode({
          'sub': challenge.id,
          'nonce': challenge.nonce,
          'aud': [managedAgentAudience],
          'iat': issued,
          'exp': min(challenge.expiresAt ~/ 1000, issued + 600),
          'jti': const Uuid().v4()
        });
      builder.setProtectedHeader('typ', 'JWT');
      builder.addRecipient(key, algorithm: 'ES256');
      final signed = builder.build();
      final ring = JsonWebKeyStore()..addKey(key);
      if (!await signed.verify(ring)) throw const FormatException();
      return ManagedAgentBindingProof(
          signed.toCompactSerialization(), challenge, nowMillis);
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }
}

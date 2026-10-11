import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:device_identity/device_identity.dart'
    show validUuid, validSecret, safeInteger, maxSafeInteger;
import 'package:jose/jose.dart';
import 'models.dart';

/// Evidence that a specific signed command was verified. It authorizes only
/// the fixed actions on this app's own data, never system management or wipe.
class VerifiedCleanupCommand {
  final CleanupScope scope;
  final String operationId, commandId, commandHash;
  final int issuedAt, notAfter;
  const VerifiedCleanupCommand._(this.scope, this.operationId, this.commandId,
      this.commandHash, this.issuedAt, this.notAfter);
  @override
  String toString() => 'VerifiedCleanupCommand(redacted)';
}

/// Verifies a command against an authenticated public key ring and the exact
/// original registration. The caller must obtain the ring over its configured
/// authenticated TLS origin; never follow JWS URLs or trust embedded keys.
class CleanupCommandVerifier {
  final CleanupScope scope;
  final int Function() nowMillis;
  final Map<String, JsonWebKey> _keys = {};
  CleanupCommandVerifier(
      {required this.scope,
      required Map<String, dynamic> trustedKeys,
      required this.nowMillis}) {
    try {
      final keys = trustedKeys['keys'];
      if (trustedKeys.length != 1 ||
          keys is! List ||
          keys.isEmpty ||
          keys.length > 32) {
        throw const FormatException();
      }
      for (final value in keys) {
        if (value is! Map<String, dynamic> ||
            value['kty'] != 'EC' ||
            value['crv'] != 'P-256' ||
            !validSecret(value['x']) ||
            !validSecret(value['y']) ||
            value.keys.any((name) => !const {
                  'kty',
                  'crv',
                  'x',
                  'y',
                  'kid',
                  'alg',
                  'use',
                  'key_ops'
                }.contains(name)) ||
            value['alg'] != null && value['alg'] != 'ES256' ||
            value['use'] != null && value['use'] != 'sig' ||
            value['kid'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value['kid']) ||
            _keys.containsKey(value['kid'])) {
          throw const FormatException();
        }
        final operations = value['key_ops'];
        if (operations != null &&
            (operations is! List ||
                operations.length != 1 ||
                operations.single != 'verify')) {
          throw const FormatException();
        }
        _keys[value['kid']] = JsonWebKey.fromJson(value);
      }
    } catch (_) {
      throw ArgumentError('Invalid cleanup public key ring');
    }
  }

  Future<VerifiedCleanupCommand> verify(String compact,
      {required String operationId,
      required String commandId,
      required int notAfter}) async {
    if (!validUuid(operationId) ||
        !validUuid(commandId) ||
        !safeInteger(notAfter, minimum: 1)) {
      throw const CleanupFailure('CLEANUP_RESPONSE_INVALID');
    }
    Map<String, dynamic> body;
    try {
      if (compact.length > 16384 ||
          !RegExp(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$')
              .hasMatch(compact)) {
        throw const FormatException();
      }
      final jws = JsonWebSignature.fromCompactSerialization(compact);
      final header = jws.unverifiedPayload.protectedHeader!.toJson();
      if (header['alg'] != 'ES256' ||
          header['typ'] != 'aimanager-cleanup-command+jws' ||
          header.keys
              .any((key) => !const {'alg', 'typ', 'kid'}.contains(key))) {
        throw const FormatException();
      }
      final key = _keys[header['kid']];
      if (key == null) throw const FormatException();
      final payload = await jws.getPayload(JsonWebKeyStore()..addKey(key),
          allowedAlgorithms: ['ES256']);
      final decoded = jsonDecode(payload.stringContent);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      body = decoded;
    } catch (_) {
      throw const CleanupFailure('CLEANUP_SIGNATURE_INVALID');
    }
    const names = {
      'schemaVersion',
      'purpose',
      'tenantId',
      'deviceId',
      'registrationId',
      'keyThumbprint',
      'operationId',
      'commandId',
      'issuedAt',
      'notAfter',
      'scope',
      'actions',
      'keyRemoval'
    };
    if (body.length != names.length ||
        body.keys.any((key) => !names.contains(key)) ||
        body['schemaVersion'] != 1 ||
        body['purpose'] != 'AGENT_CLEANUP' ||
        body['tenantId'] != scope.tenantId ||
        body['deviceId'] != scope.deviceId ||
        body['registrationId'] != scope.registrationId ||
        body['keyThumbprint'] != scope.keyThumbprint ||
        body['operationId'] != operationId ||
        body['commandId'] != commandId ||
        body['notAfter'] != notAfter ||
        body['scope'] != 'OWN_AGENT_DATA_ONLY' ||
        body['keyRemoval'] != 'AFTER_SERVER_ACK' ||
        body['actions'] is! List ||
        !_fixedActions(body['actions']) ||
        !safeInteger(body['issuedAt'], minimum: 1)) {
      throw const CleanupFailure('CLEANUP_COMMAND_MISMATCH');
    }
    final issued = body['issuedAt'] as int;
    final now = nowMillis();
    if (!safeInteger(now, minimum: 1)) {
      throw const CleanupFailure('CLOCK_UNTRUSTED');
    }
    if (notAfter <= issued ||
        notAfter - issued > 7 * 86400000 ||
        issued > now + 300000 ||
        notAfter <= now ||
        notAfter > maxSafeInteger) {
      throw const CleanupFailure('CLEANUP_COMMAND_EXPIRED');
    }
    final hash = sha256.convert(utf8.encode(compact)).toString();
    return VerifiedCleanupCommand._(
        scope, operationId, commandId, hash, issued, notAfter);
  }

  bool _fixedActions(dynamic value) =>
      value is List &&
      value.length == 3 &&
      value[0] == 'CLEAR_POLICY_CACHE' &&
      value[1] == 'CLEAR_USAGE_CACHE' &&
      value[2] == 'CLEAR_BUSINESS_CREDENTIALS';
}

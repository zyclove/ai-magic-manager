import 'package:device_identity/device_identity.dart';
import 'package:flutter/services.dart';

/// New Android registrations use a non-exportable AndroidKeyStore alias.
/// Existing encrypted software-JWK records remain readable for recovery and
/// cleanup; they are never silently replaced with another signing key.
class AndroidDeviceKeys
    implements
        DeviceEnrollmentKeys,
        DeviceCleanupKeys,
        DeviceManagedBindingKeys,
        DeviceCleanupKeyDeletion {
  static const _channel = MethodChannel('com.aimanager.child/device_keys');
  static final _alias = RegExp(
      r'^aimanager\.device\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  final JoseDeviceEnrollmentKeys _legacy = const JoseDeviceEnrollmentKeys();

  bool _software(String handle) => handle.startsWith('{');
  void _requireAlias(String handle) {
    if (!_alias.hasMatch(handle)) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }

  Future<Map<String, dynamic>> _invoke(
      String method, Map<String, Object?> arguments) async {
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>(method, arguments);
      if (result == null) throw const FormatException('Missing result');
      return result;
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }

  @override
  Future<String> generateHandle() async {
    try {
      final handle = await _channel.invokeMethod<String>('generate');
      if (handle == null) throw const FormatException('Missing alias');
      _requireAlias(handle);
      return handle;
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }

  @override
  Future<EnrollmentProof> proof(String handle, String enrollmentId,
      String token, String purpose, int nowMillis) async {
    if (_software(handle)) {
      return _legacy.proof(handle, enrollmentId, token, purpose, nowMillis);
    }
    _requireAlias(handle);
    final result = await _invoke('proof', {
      'handle': handle,
      'enrollmentId': enrollmentId,
      'token': token,
      'purpose': purpose,
      'nowMillis': nowMillis
    });
    if (result['publicKeyJwk'] is! String || result['compact'] is! String) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
    return EnrollmentProof(result['publicKeyJwk'], result['compact']);
  }

  @override
  Future<ManagedAgentBindingProof> managedBindingProof(
      String handle, ManagedAgentChallenge challenge, int nowMillis) async {
    challenge.requireCurrent(nowMillis);
    if (_software(handle)) {
      return _legacy.managedBindingProof(handle, challenge, nowMillis);
    }
    _requireAlias(handle);
    final result = await _invoke('managedBindingProof', {
      'handle': handle,
      'challengeId': challenge.id,
      'nonce': challenge.nonce,
      'audience': managedAgentAudience,
      'createdAt': challenge.createdAt,
      'expiresAt': challenge.expiresAt,
      'nowMillis': nowMillis,
    });
    if (result.length != 1 || result['compact'] is! String) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
    return ManagedAgentBindingProof(result['compact'], challenge, nowMillis);
  }

  @override
  Future<CleanupProof> cleanupProof(
      String handle,
      String tenantId,
      String deviceId,
      String registrationId,
      String action,
      String? operationId,
      int nowMillis) async {
    if (_software(handle)) {
      return _legacy.cleanupProof(handle, tenantId, deviceId, registrationId,
          action, operationId, nowMillis);
    }
    _requireAlias(handle);
    final result = await _invoke('cleanupProof', {
      'handle': handle,
      'tenantId': tenantId,
      'deviceId': deviceId,
      'registrationId': registrationId,
      'action': action,
      'operationId': operationId,
      'nowMillis': nowMillis
    });
    if (result['compact'] is! String || result['keyThumbprint'] is! String) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
    return CleanupProof(result['compact'], result['keyThumbprint']);
  }

  @override
  Future<void> deleteOriginalHandle(String handle) async {
    if (_software(handle)) return _legacy.deleteOriginalHandle(handle);
    _requireAlias(handle);
    try {
      if (await _channel.invokeMethod<bool>('delete', {'handle': handle}) !=
          true) {
        throw const FormatException('Key deletion not confirmed');
      }
    } catch (_) {
      throw const DeviceIdentityFailure('DEVICE_KEY_UNAVAILABLE');
    }
  }
}

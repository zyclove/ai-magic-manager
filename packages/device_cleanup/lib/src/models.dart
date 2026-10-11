import 'package:device_identity/device_identity.dart'
    show validUuid, validSecret;

/// Diagnostics never include command content, signatures or private keys.
class CleanupFailure implements Exception {
  final String code;
  final bool outcomeUnknown;
  const CleanupFailure(this.code, {this.outcomeUnknown = false});
  @override
  String toString() => 'CleanupFailure($code)';
}

/// The thumbprint must come from the original enrollment key, not from the
/// untrusted command or a newly generated key.
class CleanupScope {
  final String tenantId, deviceId, registrationId, keyThumbprint;
  CleanupScope(
      this.tenantId, this.deviceId, this.registrationId, this.keyThumbprint) {
    if (![tenantId, deviceId, registrationId].every(validUuid) ||
        !validSecret(keyThumbprint)) {
      throw ArgumentError('Invalid cleanup scope');
    }
  }
}

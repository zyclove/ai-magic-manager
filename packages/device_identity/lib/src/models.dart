/// Fixed diagnostics only; never copy server text or a secure-store SDK cause.
class DeviceIdentityFailure implements Exception {
  final String code;
  final int? status;
  final bool retryable, outcomeUnknown;
  const DeviceIdentityFailure(this.code,
      {this.status, this.retryable = false, this.outcomeUnknown = false});
  @override
  String toString() => 'DeviceIdentityFailure($code)';
}

/// Host must implement ONE atomic, durable encrypted application-private record.
/// No plaintext fallback, shared backup or generic preference store is allowed.
/// Multi-process access requires a native lock and the optional compare-and-set
/// capability below; a plain read/write adapter must have one owner.
abstract interface class DeviceSecretStore {
  Future<String?> read();
  Future<void> write(String record);
}

/// Optional atomic mutation shared with native/background identity owners.
/// Compare the exact encrypted record's plaintext serialization under the same
/// native lock used by every writer. Null expected means absent, and null value
/// deletes the record. True confirms the mutation and durability barrier; false
/// leaves the current record unchanged. Never retry a rejected mutation blindly.
abstract interface class DeviceSecretCompareAndSet {
  Future<bool> compareAndSet(
      {required String? expected, required String? value});
}

/// Optional destructive capability used only after an acknowledged cleanup.
/// Implementations must make repeated deletion safe and durably flush it.
abstract interface class DeviceSecretDeletion {
  Future<void> deleteIdentity();
}

enum IdentityPhase {
  claimUncertain,
  awaitingConfirmation,
  active,
  rotationRequested,
  rotationPending,
  activationUncertain,
  cleanupPending
}

class EnrollmentTicket {
  final String tenantId, enrollmentId, token;
  final int expiresAt;
  EnrollmentTicket(
      {required this.tenantId,
      required this.enrollmentId,
      required this.token,
      required this.expiresAt}) {
    if (!validUuid(tenantId) ||
        !validUuid(enrollmentId) ||
        !validSecret(token) ||
        !safeInteger(expiresAt, minimum: 1)) {
      throw ArgumentError('Invalid enrollment ticket');
    }
  }
  @override
  String toString() => 'EnrollmentTicket(redacted)';
}

/// Safe UI facts. No private key, enrollment secret, bearer or pairing code.
class DeviceIdentityView {
  final IdentityPhase phase;
  final String tenantId;
  final String? deviceId, registrationId;
  final int? credentialExpiresAt,
      confirmBefore,
      activateBefore,
      lastHeartbeatAt;
  final int heartbeatSequence;
  final bool heartbeatPending, cloudAuthenticationBlocked;
  const DeviceIdentityView(
      {required this.phase,
      required this.tenantId,
      this.deviceId,
      this.registrationId,
      this.credentialExpiresAt,
      this.confirmBefore,
      this.activateBefore,
      this.lastHeartbeatAt,
      required this.heartbeatSequence,
      required this.heartbeatPending,
      required this.cloudAuthenticationBlocked});
  bool get systemEnforced => false;
  @override
  String toString() => 'DeviceIdentityView(${phase.name})';
}

/// Private-host recovery binding for a cleanup already entered. No bearer or
/// private key is exposed. A journal must independently prove a persisted
/// cleared-receipt acknowledgement before this may authorize final deletion.
class CleanupPendingBinding {
  final String tenantId, deviceId, registrationId, keyThumbprint, commandHash;
  const CleanupPendingBinding(this.tenantId, this.deviceId, this.registrationId,
      this.keyThumbprint, this.commandHash);
  @override
  String toString() => 'CleanupPendingBinding(redacted)';
}

class HeartbeatAcknowledgement {
  final int sequence, receivedAt;
  final bool replayed;
  const HeartbeatAcknowledgement(this.sequence, this.receivedAt,
      {required this.replayed});
}

const maxSafeInteger = 9007199254740991;
bool safeInteger(dynamic value, {int minimum = 0}) =>
    value is int && value >= minimum && value <= maxSafeInteger;
bool validUuid(dynamic value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);
bool validSecret(dynamic value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value);
bool boundedText(dynamic value, int limit) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.length <= limit &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

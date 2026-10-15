import 'dart:async';
import 'managed_binding.dart';
import 'manager.dart';
import 'models.dart';

/// Local SDK acknowledgement only. There is deliberately no verified/enforced state.
enum ManagedFeedbackStage { idle, submitted, awaitingVerification, paused }

abstract interface class ManagedAgentFeedbackPort {
  Future<void> submit(ManagedAgentBindingProof proof);

  /// Invalidates pending callbacks; already delivered EMM data cannot be recalled.
  void pause();
  void close();
}

/// One foreground registration owner. No background loop, persisted proof or raw logging.
class ManagedAgentFeedbackSender {
  final DeviceIdentityManager identity;
  final ManagedAgentFeedbackPort feedback;
  final int Function() nowMillis;
  bool _busy = false, _closed = false, _submitted = false;
  int _generation = 0, _attempts = 0;
  int? _timeFloor, _nextAttempt;
  String? _challenge;
  ManagedAgentFeedbackSender(
      {required this.identity,
      required this.feedback,
      required this.nowMillis});

  int _now() {
    final now = nowMillis();
    if (!safeInteger(now, minimum: 1) ||
        (_timeFloor != null && now < _timeFloor!)) {
      throw const DeviceIdentityFailure('CLOCK_UNTRUSTED');
    }
    return _timeFloor = now;
  }

  Future<ManagedFeedbackStage> synchronize(
      {required bool Function() current}) async {
    if (_closed || !current()) return ManagedFeedbackStage.paused;
    if (_busy) throw const DeviceIdentityFailure('IDENTITY_BUSY');
    _busy = true;
    final generation = _generation;
    bool active() => !_closed && generation == _generation && current();
    try {
      _now();
      final proof = await identity.managedAgentBindingProof();
      if (!active()) return ManagedFeedbackStage.paused;
      if (proof == null) {
        _challenge = null;
        _attempts = 0;
        _submitted = false;
        _nextAttempt = null;
        return ManagedFeedbackStage.idle;
      }
      final now = _now();
      if (now >= proof.expiresAt) {
        throw const DeviceIdentityFailure('MANAGED_CHALLENGE_EXPIRED');
      }
      if (_challenge != proof.challengeId) {
        _challenge = proof.challengeId;
        _attempts = 0;
        _submitted = false;
        _nextAttempt = null;
      }
      if (_submitted) return ManagedFeedbackStage.awaitingVerification;
      if (_attempts >= 3) {
        throw const DeviceIdentityFailure('MANAGED_FEEDBACK_RETRY_EXHAUSTED');
      }
      if (_nextAttempt != null && now < _nextAttempt!) {
        throw const DeviceIdentityFailure('MANAGED_FEEDBACK_RETRY_LATER');
      }
      if (await identity.activeCredential() == null) {
        throw const DeviceIdentityFailure('DEVICE_CREDENTIAL_UNAVAILABLE');
      }
      if (!active()) return ManagedFeedbackStage.paused;
      if (_now() >= proof.expiresAt) {
        throw const DeviceIdentityFailure('MANAGED_CHALLENGE_EXPIRED');
      }
      _attempts++;
      _nextAttempt = now + 60000;
      try {
        await feedback.submit(proof).timeout(const Duration(seconds: 15));
      } catch (_) {
        if (!active()) return ManagedFeedbackStage.paused;
        throw const DeviceIdentityFailure('MANAGED_FEEDBACK_UNAVAILABLE');
      }
      if (!active()) return ManagedFeedbackStage.paused;
      if (_now() >= proof.expiresAt) {
        throw const DeviceIdentityFailure('MANAGED_CHALLENGE_EXPIRED');
      }
      _submitted = true;
      return ManagedFeedbackStage.submitted;
    } finally {
      _busy = false;
    }
  }

  void pause() {
    _generation++;
    try {
      feedback.pause();
    } catch (_) {/* No native cause enters diagnostics. */}
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _generation++;
    _challenge = null;
    _timeFloor = null;
    try {
      feedback.close();
    } catch (_) {/* Host disposal is idempotent. */}
  }
}

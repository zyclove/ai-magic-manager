import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:guardian/core/publication_journal.dart';

/// Test-only per-session adapter. All read/CAS/write work is synchronous before
/// returning each Future; production must use the real browser transaction.
class MemoryPublicationJournal implements PublicationJournal {
  final _records = <(PublicationOwner, String), PublicationPending>{};
  final _terminal = <String, PublicationTerminalMarker>{};

  @override
  Future<PublicationPending?> read(
          PublicationOwner owner, String policyId) async =>
      _records[(owner, policyId)];

  @override
  Future<PublicationReservation> reserve(PublicationIntent intent) async {
    final marker = _terminal[publicationRequestDigest(intent)];
    final key = (intent.owner, intent.policyId);
    final existing = _records[key];
    if (existing != null) {
      if (marker != null && existing.intent.idempotencyKey == intent.idempotencyKey) {
        throw const ApiFailure(409, 'INVALID_POLICY_PUBLICATION_RECORD');
      }
      return PublicationReservation(record: existing, maySubmit: false);
    }
    if (marker != null) {
      return PublicationReservation(record: PublicationPending(intent: intent,
          phase: marker.reason.phase, confirmedSuccess: marker.confirmedSuccess),
          maySubmit: false);
    }
    if (_records.keys.where((key) => key.$1 == intent.owner).length >=
        publicationMaximumPending) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CAPACITY');
    }
    final record = PublicationPending(intent: intent);
    record.encode();
    _records[key] = record;
    return PublicationReservation(record: record, maySubmit: true);
  }

  @override
  Future<PublicationReservation> claimRetry(PublicationPending expected) async {
    final marker = _terminal[publicationRequestDigest(expected.intent)];
    final key = (expected.intent.owner, expected.intent.policyId);
    final current = _records[key];
    if (marker != null) {
      if (current != null) {
        if (current.intent.idempotencyKey == expected.intent.idempotencyKey) {
          throw const ApiFailure(409, 'INVALID_POLICY_PUBLICATION_RECORD');
        }
        return PublicationReservation(record: current, maySubmit: false);
      }
      return PublicationReservation(record: PublicationPending(
          intent: expected.intent, phase: marker.reason.phase,
          attempt: expected.attempt, confirmedSuccess: marker.confirmedSuccess),
          maySubmit: false);
    }
    if (current == null) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    if (current != expected ||
        expected.phase != PublicationPhase.reauthenticationRequired) {
      return PublicationReservation(record: current, maySubmit: false);
    }
    if (expected.attempt >= publicationMaximumSafeInteger) {
      throw const ApiFailure(409, 'PUBLICATION_ATTEMPT_EXHAUSTED');
    }
    final next = PublicationPending(
        intent: expected.intent, attempt: expected.attempt + 1);
    _records[key] = next;
    return PublicationReservation(record: next, maySubmit: true);
  }

  @override
  Future<PublicationPending> markReauthenticationRequired(
      PublicationPending expected) async {
    final key = (expected.intent.owner, expected.intent.policyId);
    if (_records[key] != expected ||
        expected.phase != PublicationPhase.unknown) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    final next = PublicationPending(
        intent: expected.intent,
        phase: PublicationPhase.reauthenticationRequired,
        attempt: expected.attempt);
    _records[key] = next;
    return next;
  }

  @override
  Future<PublicationPending> markResultTerminalIfSame(
      PublicationPending expected, PublicationTerminalReason reason,
      {bool confirmedSuccess = false, bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    final key = (expected.intent.owner, expected.intent.policyId);
    var next = PublicationPending(
        intent: expected.intent,
        phase: reason.phase,
        attempt: expected.attempt,
        confirmedSuccess: confirmedSuccess || expected.confirmedSuccess);
    final digest = publicationRequestDigest(expected.intent);
    final marker = _terminal[digest];
    if (marker != null) {
      if (_records[key] != null) {
        throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
      }
      final mergedReason = marker.reason == PublicationTerminalReason.erased ||
          reason == PublicationTerminalReason.erased
          ? PublicationTerminalReason.erased : PublicationTerminalReason.expired;
      next = PublicationPending(intent: expected.intent, phase: mergedReason.phase,
          attempt: expected.attempt,
          confirmedSuccess: marker.confirmedSuccess || next.confirmedSuccess);
      if (marker.reason != mergedReason || marker.confirmedSuccess != next.confirmedSuccess) {
        final strengthened = PublicationTerminalMarker(ownerKey: marker.ownerKey,
            policyId: marker.policyId, requestDigest: marker.requestDigest,
            reason: mergedReason, acknowledgedAt: marker.acknowledgedAt,
            confirmedSuccess: next.confirmedSuccess);
        strengthened.encode();
        if (isCurrent?.call() == false) {
          throw const ApiFailure(409, 'WORKSPACE_CHANGED');
        }
        _terminal[digest] = strengthened;
      }
      return next;
    }
    if (_records[key] == next) return next;
    final current = _records[key];
    if (current != null && current.phase.terminal &&
        current.intent == expected.intent && current.attempt == expected.attempt) {
      next = PublicationPending(intent: expected.intent,
          phase: current.phase == PublicationPhase.resultErased ||
              reason == PublicationTerminalReason.erased
              ? PublicationPhase.resultErased : PublicationPhase.resultExpired,
          attempt: expected.attempt,
          confirmedSuccess: current.confirmedSuccess || next.confirmedSuccess);
      next.encode();
      if (isCurrent?.call() == false) {
        throw const ApiFailure(409, 'WORKSPACE_CHANGED');
      }
      _records[key] = next;
      return next;
    }
    if (_records[key] != expected || expected.phase.terminal) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    next.encode();
    if (isCurrent?.call() == false) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    _records[key] = next;
    return next;
  }

  @override
  Future<PublicationTerminalMarker> acknowledgeTerminalIfSame(
      PublicationPending expected,
      {required int acknowledgedAt, bool Function()? isCurrent}) async {
    if (isCurrent?.call() == false) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    if (!expected.phase.terminal) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    final key = (expected.intent.owner, expected.intent.policyId);
    final digest = publicationRequestDigest(expected.intent);
    final reason = expected.phase == PublicationPhase.resultExpired
        ? PublicationTerminalReason.expired : PublicationTerminalReason.erased;
    final existing = _terminal[digest];
    if (existing != null) {
      if (_records[key] != null || existing.reason != reason ||
          (expected.confirmedSuccess && !existing.confirmedSuccess)) {
        throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
      }
      return existing;
    }
    if (_records[key] != expected) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    final marker = PublicationTerminalMarker(
        ownerKey: expected.intent.owner.key, policyId: expected.intent.policyId,
        requestDigest: digest, reason: reason, acknowledgedAt: acknowledgedAt,
        confirmedSuccess: expected.confirmedSuccess);
    marker.encode();
    if (isCurrent?.call() == false) {
      throw const ApiFailure(409, 'WORKSPACE_CHANGED');
    }
    _terminal[digest] = marker;
    _records.remove(key);
    return marker;
  }

  @override
  Future<bool> removeIfSame(PublicationPending expected) async {
    final key = (expected.intent.owner, expected.intent.policyId);
    if (_records[key] != expected || expected.phase.terminal) return false;
    _records.remove(key);
    return true;
  }

  @override
  Future<bool> cancelNotSubmitted(PublicationPending expected) async {
    if (expected.phase != PublicationPhase.reauthenticationRequired) {
      return false;
    }
    return removeIfSame(expected);
  }
}

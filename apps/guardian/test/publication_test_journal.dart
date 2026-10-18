import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:guardian/core/publication_journal.dart';

/// Test-only per-session adapter. All read/CAS/write work is synchronous before
/// returning each Future; production must use the real browser transaction.
class MemoryPublicationJournal implements PublicationJournal {
  final _records = <(PublicationOwner, String), PublicationPending>{};

  @override
  Future<PublicationPending?> read(
          PublicationOwner owner, String policyId) async =>
      _records[(owner, policyId)];

  @override
  Future<PublicationReservation> reserve(PublicationIntent intent) async {
    final key = (intent.owner, intent.policyId);
    final existing = _records[key];
    if (existing != null) {
      return PublicationReservation(record: existing, maySubmit: false);
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
    final key = (expected.intent.owner, expected.intent.policyId);
    final current = _records[key];
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
  Future<bool> removeIfSame(PublicationPending expected) async {
    final key = (expected.intent.owner, expected.intent.policyId);
    if (_records[key] != expected) return false;
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

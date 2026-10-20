import 'policy_publication.dart';

/// Persistent per-owner/per-policy write-ahead slot. Restored UNKNOWN never
/// authorizes another POST. Implementations must make each mutation atomic.
abstract interface class PublicationJournal {
  Future<PublicationPending?> read(PublicationOwner owner, String policyId);

  /// First insertion persists UNKNOWN attempt1 before returning maySubmit=true.
  /// An occupied slot always returns its original record with maySubmit=false.
  Future<PublicationReservation> reserve(PublicationIntent intent);

  /// Exact REAUTH_REQUIRED CAS to UNKNOWN attempt+1. At most one caller wins.
  /// A stale/nonmatching record returns the current record with maySubmit=false.
  Future<PublicationReservation> claimRetry(PublicationPending expected);

  /// Only the controller's typed trusted response to this exact POST attempt may
  /// invoke this transition; query failures never supply evidence for it.
  /// A stale/non-UNKNOWN record throws PUBLICATION_PENDING_CHANGED.
  Future<PublicationPending> markReauthenticationRequired(
      PublicationPending expected);

  /// Trusted terminal evidence, fenced by the complete original record.
  Future<PublicationPending> markResultTerminalIfSame(
      PublicationPending expected, PublicationTerminalReason reason,
      {bool confirmedSuccess = false, bool Function()? isCurrent});

  /// Explicit local acknowledgement only. In one transaction, retain a minimal
  /// permanent fence and delete sensitive intent; verify both after commit.
  Future<PublicationTerminalMarker> acknowledgeTerminalIfSame(
      PublicationPending expected,
      {required int acknowledgedAt, bool Function()? isCurrent});

  /// Strict successful receipt cleanup. Compare the complete record and attempt;
  /// mismatch/absence returns false and never deletes a newer record.
  Future<bool> removeIfSame(PublicationPending expected);

  /// Explicit user cancellation of an exact REAUTH_REQUIRED record only.
  /// UNKNOWN is never cancelled or evicted just because its preview expired.
  Future<bool> cancelNotSubmitted(PublicationPending expected);
}

package com.aimanager.managedandroid.internal;

import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import java.time.Clock;
import java.util.Objects;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Joins a durable candidate resource to current policy preparation. No remote ownership claim,
 * state transition, write or assignment is performed. Future dispatch still needs independent
 * resource authority and the journal's final pre-write checkpoint.
 */
@Service
class ManagedExecutionPreparationService {
  private final ManagedPolicyExecutionJournal journal;
  private final ManagedPolicyPreparationService preparation;
  private final Clock clock;

  ManagedExecutionPreparationService(
      ManagedPolicyExecutionJournal journal,
      ManagedPolicyPreparationService preparation,
      Clock clock) {
    this.journal = journal;
    this.preparation = preparation;
    this.clock = clock;
  }

  PreparedExecution prepare(ManagedPolicyExecutionJournal.Claim claim) {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Execution preparation requires separate short transactions");
    var before = journal.writePreparationTarget(claim);
    var binding = before.binding();
    // Only persisted task authority selects these inputs, never caller-supplied publication IDs.
    var prepared =
        preparation.prepare(
            binding.tenantId(),
            binding.actorId(),
            before.publicationId(),
            binding.bindingId(),
            binding.bindingVersion());
    var current = journal.writePreparationTarget(claim);
    if (!before.equals(current)
        || prepared == null
        || !Objects.equals(current.publicationId(), prepared.publicationId())
        || !Objects.equals(current.binding(), prepared.binding())
        || prepared.desired() == null
        || !Objects.equals(current.publication(), prepared.desired().publication())
        || !Objects.equals(binding.deviceId(), prepared.desired().deviceId())
        || !Objects.equals(binding.registrationId(), prepared.desired().registrationId())
        || prepared.document() == null
        || !Objects.equals(current.claim().documentJson(), prepared.document().documentJson())
        || !Objects.equals(current.claim().documentSha256(), prepared.document().sha256())
        || !Objects.equals(
            current.claim().documentSha256(),
            SecretMaterial.hash(prepared.document().documentJson()))
        || prepared.profile() == null
        || prepared.profile().expiresAt() == null
        || prepared.controls() == null) throw rejected("EXECUTION_PREPARATION_CHANGED");
    long expiresAt;
    try {
      expiresAt =
          Math.min(
              Math.min(current.expiresAt(), current.claim().leaseUntil()),
              Math.min(
                  prepared.profile().expiresAt().toEpochMilli(), prepared.controls().expiresAt()));
    } catch (ArithmeticException invalid) {
      throw rejected("EXECUTION_PREPARATION_CHANGED");
    }
    if (clock.millis() >= expiresAt) throw rejected("EXECUTION_PREPARATION_EXPIRED");
    return new PreparedExecution(current, prepared, expiresAt);
  }

  private static DomainException rejected(String reason) {
    return new DomainException(HttpStatus.CONFLICT, reason);
  }

  /** Internal observation only. Consumers must revalidate it before any later external action. */
  record PreparedExecution(
      ManagedPolicyExecutionJournal.WritePreparationTarget target,
      ManagedPolicyPreparationService.Prepared preparation,
      long expiresAt) {
    @Override
    public String toString() {
      return "PreparedManagedExecution[REDACTED]";
    }
  }
}

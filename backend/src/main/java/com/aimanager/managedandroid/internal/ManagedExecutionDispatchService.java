package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedAndroidGateway.CompletePolicyState;
import com.aimanager.managedandroid.ManagedAndroidGateway.PolicyReceipt;
import com.aimanager.managedandroid.internal.ManagedExecutionResourceAuthorityService.VerifiedExecution;
import java.time.Clock;
import java.util.Objects;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Executes one leased write action, never retries it. The journal commits uncertainty before
 * provider I/O. A confirmed assignment still awaits independent device compliance evidence. No
 * scheduler or HTTP entry enables this service until publication admission is connected.
 */
@Service
class ManagedExecutionDispatchService {
  private static final Logger LOG = LoggerFactory.getLogger(ManagedExecutionDispatchService.class);
  private final ManagedPolicyExecutionJournal journal;
  private final ManagedExecutionResourceAuthorityService authority;
  private final ManagedAndroidGateway gateway;
  private final Clock clock;

  ManagedExecutionDispatchService(
      ManagedPolicyExecutionJournal journal,
      ManagedExecutionResourceAuthorityService authority,
      ManagedAndroidGateway gateway,
      Clock clock) {
    this.journal = journal;
    this.authority = authority;
    this.gateway = gateway;
    this.clock = clock;
  }

  boolean execute(ManagedPolicyExecutionJournal.Claim claim) {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Dispatch requires separate short transactions");
    if (claim == null
        || (claim.action() != ManagedPolicyExecutionJournal.Action.WRITE_POLICY
            && claim.action() != ManagedPolicyExecutionJournal.Action.ASSIGN_POLICY))
      throw new IllegalArgumentException("Dispatch requires a write or assignment claim");
    String stage = "prepare";
    try {
      var verified = authority.verify(claim);
      current(verified, claim, false);
      if (claim.action() == ManagedPolicyExecutionJournal.Action.ASSIGN_POLICY) {
        stage = "inspect-before-assignment";
        inspect(verified, claim, claim.policyVersion());
        current(verified, claim, false);
        // Inspection is network I/O: recheck application/device qualification afterward.
        var fresh = authority.verify(claim);
        current(verified, claim, false);
        current(fresh, claim, false);
        if (!verified.evidence().target().equals(fresh.evidence().target())) throw changed();
        verified =
            new VerifiedExecution(
                fresh.prepared(),
                fresh.evidence(),
                Math.min(verified.expiresAt(), fresh.expiresAt()));
      }
      stage = "checkpoint";
      if (!journal.beforeWrite(verified.prepared().target(), verified.expiresAt())) throw changed();
      current(verified, claim, true);
      if (claim.action() == ManagedPolicyExecutionJournal.Action.WRITE_POLICY) {
        stage = "write";
        var receipt =
            gateway.writePolicyCandidate(
                claim.enterpriseId(),
                claim.policyId(),
                verified.prepared().preparation().document());
        validReceipt(claim, receipt);
        current(verified, claim, true);
        stage = "inspect-written-policy";
        inspect(verified, claim, receipt.providerVersion());
        current(verified, claim, true);
        return journal.policyWritten(claim, receipt);
      }
      stage = "assign";
      var receipt = gateway.assignPolicy(claim.enterpriseId(), claim.deviceId(), claim.policyId());
      current(verified, claim, true);
      return journal.assignmentAccepted(claim, receipt);
    } catch (RuntimeException failure) {
      log(stage, claim, failure);
      try {
        // READY failures cancel; UNKNOWN failures stay unknown. A stale lease cannot change state.
        journal.failed(claim);
      } catch (RuntimeException checkpointFailure) {
        // Database failure leaves the committed lease/state for recovery, never another write.
        log("record-failure", claim, checkpointFailure);
      }
      return false;
    }
  }

  private void current(
      VerifiedExecution verified, ManagedPolicyExecutionJournal.Claim claim, boolean dispatched) {
    if (verified == null
        || verified.prepared() == null
        || verified.evidence() == null
        || verified.evidence().target() == null
        || !claim.equals(verified.prepared().target().claim())) throw changed();
    var actual =
        dispatched ? journal.dispatchedTarget(claim) : journal.writePreparationTarget(claim);
    var target = verified.evidence().target();
    if (!actual.equals(verified.prepared().target())
        || !gateway.available()
        || !gateway.supportsCompletePolicyDocuments()
        || !gateway.supportsPolicyResourceAuthority()
        || !Objects.equals(gateway.providerCode(), target.provider())
        || !Objects.equals(gateway.policyResourceAuthorityRevision(), target.adapterRevision())
        || Thread.currentThread().isInterrupted()
        || clock.millis() >= verified.expiresAt()) throw changed();
  }

  private void inspect(
      VerifiedExecution verified, ManagedPolicyExecutionJournal.Claim claim, Long version) {
    if (version == null || version < 1) throw changed();
    var observed =
        gateway.inspectCompletePolicy(
            claim.enterpriseId(),
            claim.policyId(),
            verified.prepared().preparation().document(),
            version);
    if (observed == null
        || observed.state() != CompletePolicyState.MATCHED
        || !policyName(claim).equals(observed.policyName())
        || !version.equals(observed.providerVersion())) throw changed();
  }

  private static void validReceipt(
      ManagedPolicyExecutionJournal.Claim claim, PolicyReceipt receipt) {
    if (receipt == null
        || !policyName(claim).equals(receipt.policyName())
        || receipt.providerVersion() == null
        || receipt.providerVersion() < 1) throw changed();
  }

  private static String policyName(ManagedPolicyExecutionJournal.Claim claim) {
    return "enterprises/" + claim.enterpriseId() + "/policies/" + claim.policyId();
  }

  private static IllegalStateException changed() {
    return new IllegalStateException("Managed dispatch prerequisites no longer match");
  }

  private static void log(
      String stage, ManagedPolicyExecutionJournal.Claim claim, RuntimeException failure) {
    LOG.warn(
        "Managed dispatch stopped: stage={}, task={}, type={}",
        stage,
        claim.taskId(),
        failure.getClass().getSimpleName());
  }
}

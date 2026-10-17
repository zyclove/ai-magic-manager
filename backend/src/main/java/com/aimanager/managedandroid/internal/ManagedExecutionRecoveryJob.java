package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Observes already dispatched device assignments. Never creates tasks, writes policies or assigns
 * devices. Disabled by default until a qualified connector and its bounded read transport are
 * ready.
 */
@Component
@ConditionalOnProperty(name = "manager.emm.execution.device-recovery.enabled", havingValue = "true")
class ManagedExecutionRecoveryJob {
  private static final Logger LOG = LoggerFactory.getLogger(ManagedExecutionRecoveryJob.class);
  private final ManagedPolicyExecutionJournal journal;
  private final ManagedAndroidGateway gateway;
  private final int batch;

  ManagedExecutionRecoveryJob(
      ManagedPolicyExecutionJournal journal,
      ManagedAndroidGateway gateway,
      @Value("${manager.emm.execution.device-recovery.batch-size:5}") int batch,
      @Value("${manager.emm.execution.device-recovery.interval-seconds:30}") long intervalSeconds) {
    if (batch < 1 || batch > 25 || intervalSeconds < 5 || intervalSeconds > 3600)
      throw new IllegalArgumentException("Invalid device execution recovery configuration");
    this.journal = journal;
    this.gateway = gateway;
    this.batch = batch;
  }

  @Scheduled(
      fixedDelayString = "${manager.emm.execution.device-recovery.interval-seconds:30}",
      initialDelayString = "${manager.emm.execution.device-recovery.interval-seconds:30}",
      timeUnit = TimeUnit.SECONDS)
  void recover() {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Device recovery must run outside a transaction");
    for (int index = 0; index < batch && !Thread.currentThread().isInterrupted(); index++) {
      ManagedPolicyExecutionJournal.Claim claim;
      try {
        if (!gateway.available()) return;
        // Claim just before use, so slow reads do not consume a queued batch's leases.
        var claims = journal.claimDeviceObservations(gateway.providerCode(), 1);
        // An empty result can mean the journal just retired an expired head task. Continue the
        // bounded round so that a valid task behind it need not wait another scheduler interval.
        if (claims.isEmpty()) continue;
        claim = claims.get(0);
      } catch (RuntimeException failure) {
        logFailure("claim", null, failure);
        return;
      }
      try {
        if (Thread.currentThread().isInterrupted()) return;
        if (!journal.deviceObservationCurrent(claim)) continue;
        if (claim.policyVersion() == null || claim.policyVersion() < 1)
          throw new IllegalStateException("Device observation requires a confirmed policy version");
        var observed =
            gateway.readDeviceState(
                claim.enterpriseId(), claim.deviceId(), claim.policyId(), claim.policyVersion());
        // A stale lease or a concurrent cancellation returns false; no compensating write follows.
        journal.deviceObserved(claim, observed);
      } catch (RuntimeException failure) {
        logFailure("observe", claim.taskId(), failure);
        try {
          journal.failed(claim);
        } catch (RuntimeException checkpointFailure) {
          // An unavailable database leaves the durable lease to expire; continue other tasks.
          logFailure("defer", claim.taskId(), checkpointFailure);
        }
      }
    }
  }

  private static void logFailure(String stage, String taskId, RuntimeException failure) {
    // External error messages, resource names and claim documents must never enter logs.
    LOG.warn(
        "Managed device observation failed: stage={}, task={}, type={}",
        stage,
        taskId,
        failure.getClass().getSimpleName());
  }
}

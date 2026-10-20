package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import java.time.Clock;
import java.time.Duration;
import java.util.Objects;
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
  private final ManagedProviderCalls calls;
  private final Clock clock;
  private final long commitReserveMillis;

  ManagedExecutionRecoveryJob(
      ManagedPolicyExecutionJournal journal,
      ManagedAndroidGateway gateway,
      @Value("${manager.emm.execution.device-recovery.batch-size:5}") int batch,
      @Value("${manager.emm.execution.device-recovery.interval-seconds:30}") long intervalSeconds,
      ManagedProviderCalls calls,
      Clock clock,
      @Value("${manager.emm.execution.device-recovery.commit-reserve-millis:10000}")
          long commitReserveMillis) {
    if (batch < 1
        || batch > 25
        || intervalSeconds < 5
        || intervalSeconds > 3600
        || commitReserveMillis < 1
        || commitReserveMillis > 10000)
      throw new IllegalArgumentException("Invalid device execution recovery configuration");
    this.journal = journal;
    this.gateway = gateway;
    this.batch = batch;
    this.calls = Objects.requireNonNull(calls);
    this.clock = Objects.requireNonNull(clock);
    this.commitReserveMillis = commitReserveMillis;
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
      String provider;
      try {
        if (!gateway.available()) return;
        // Claim just before use, so slow reads do not consume a queued batch's leases.
        provider = gateway.providerCode();
        var claims = journal.claimDeviceObservations(provider, 1);
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
        // Queueing, local preflight and provider I/O all consume this one lease-bounded budget.
        long remaining =
            Math.subtractExact(
                Math.subtractExact(claim.leaseUntil(), clock.millis()), commitReserveMillis);
        var budget = calls.budget(Duration.ofMillis(remaining));
        if (!journal.deviceObservationCurrent(claim)) continue;
        calls.check(budget);
        if (claim.policyVersion() == null || claim.policyVersion() < 1)
          throw new IllegalStateException("Device observation requires a confirmed policy version");
        var observed =
            calls.call(
                budget,
                () -> {
                  // A read may have waited behind other provider calls. Revalidate after that wait,
                  // outside the remote I/O transaction, so cancellation cannot leak a later read.
                  if (!journal.deviceObservationCurrent(claim))
                    throw new IllegalStateException("Device observation is no longer current");
                  requireProvider(provider);
                  calls.check(budget);
                  return gateway.readDeviceState(
                      claim.enterpriseId(),
                      claim.deviceId(),
                      claim.policyId(),
                      claim.policyVersion());
                });
        requireProvider(provider);
        calls.check(budget);
        // A stale lease or a concurrent cancellation returns false; no compensating write follows.
        // The durable receipt uses the reserved local time and still checks exact device evidence.
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

  private void requireProvider(String provider) {
    if (!gateway.available() || !Objects.equals(provider, gateway.providerCode()))
      throw new IllegalStateException("Device observation provider is unavailable");
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

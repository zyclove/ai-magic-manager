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
 * Durable write consumption. Claims one action immediately before dispatch and leaves uncertain
 * writes for explicit review. Disabled until complete connector and activation readiness is proven.
 */
@Component
@ConditionalOnProperty(name = "manager.emm.execution.dispatch.enabled", havingValue = "true")
class ManagedExecutionDispatchJob {
  private static final Logger LOG = LoggerFactory.getLogger(ManagedExecutionDispatchJob.class);
  private final ManagedPolicyExecutionJournal journal;
  private final ManagedExecutionDispatchService dispatch;
  private final ManagedAndroidGateway gateway;
  private final int batch;

  ManagedExecutionDispatchJob(
      ManagedPolicyExecutionJournal journal,
      ManagedExecutionDispatchService dispatch,
      ManagedAndroidGateway gateway,
      @Value("${manager.emm.execution.dispatch.batch-size:5}") int batch,
      @Value("${manager.emm.execution.dispatch.interval-seconds:30}") long intervalSeconds) {
    if (batch < 1 || batch > 25 || intervalSeconds < 5 || intervalSeconds > 3600)
      throw new IllegalArgumentException("Invalid execution dispatch scheduling configuration");
    this.journal = journal;
    this.dispatch = dispatch;
    this.gateway = gateway;
    this.batch = batch;
  }

  @Scheduled(
      fixedDelayString = "${manager.emm.execution.dispatch.interval-seconds:30}",
      initialDelayString = "${manager.emm.execution.dispatch.interval-seconds:30}",
      timeUnit = TimeUnit.SECONDS)
  void dispatch() {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Execution dispatch consumer requires separate transactions");
    if (Thread.currentThread().isInterrupted()) return;
    try {
      // Local retirement must still work during provider outages, without leaking authority facts.
      journal.settleUnrunnableTasks(batch);
    } catch (RuntimeException failure) {
      log("settle", failure);
      return;
    }
    for (int index = 0; index < batch && !Thread.currentThread().isInterrupted(); index++) {
      try {
        if (!gateway.available()
            || !gateway.supportsExecutionProfiles()
            || !gateway.supportsCompletePolicyDocuments()
            || !gateway.supportsPolicyResourceAuthority()) return;
        var claims = journal.claimWriteActions(gateway.providerCode(), 1);
        // A racing expiry may have retired the head row. Continue only within this bounded round.
        if (claims.isEmpty()) continue;
        if (Thread.currentThread().isInterrupted()) return;
        if (!dispatch.execute(claims.get(0))) return;
      } catch (RuntimeException failure) {
        // No immediate retry after a storage/provider error. The durable state owns recovery.
        log("dispatch", failure);
        return;
      }
    }
  }

  private static void log(String stage, RuntimeException failure) {
    LOG.warn(
        "Managed execution consumer stopped: stage={}, type={}",
        stage,
        failure.getClass().getSimpleName());
  }
}

package com.aimanager.managedandroid.internal;

import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.dao.DataAccessException;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Bounded recovery of durable preparation requests. Selects references, then lets the same worker
 * claim each just before use. Both flags remain false by default; transport readiness is separate.
 */
@Component
@ConditionalOnProperty(
    prefix = "manager.emm.execution.preparation",
    name = {"enabled", "recovery.enabled"},
    havingValue = "true")
class ManagedPreparationRecoveryJob {
  private static final Logger LOG = LoggerFactory.getLogger(ManagedPreparationRecoveryJob.class);
  private final ManagedPreparationRequestJournal requests;
  private final ManagedPreparationWorker worker;
  private final int batch;

  ManagedPreparationRecoveryJob(
      ManagedPreparationRequestJournal requests,
      ManagedPreparationWorker worker,
      @Value("${manager.emm.execution.preparation.recovery.batch-size:5}") int batch,
      @Value("${manager.emm.execution.preparation.recovery.interval-seconds:30}")
          long intervalSeconds) {
    if (batch < 1 || batch > 25 || intervalSeconds < 5 || intervalSeconds > 3600)
      throw new IllegalArgumentException("Invalid preparation recovery configuration");
    this.requests = requests;
    this.worker = worker;
    this.batch = batch;
  }

  @Scheduled(
      fixedDelayString = "${manager.emm.execution.preparation.recovery.interval-seconds:30}",
      initialDelayString = "${manager.emm.execution.preparation.recovery.interval-seconds:30}",
      timeUnit = TimeUnit.SECONDS)
  void recover() {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Preparation recovery requires separate transactions");
    if (Thread.currentThread().isInterrupted()) return;
    java.util.List<ManagedPreparationRequestJournal.Reference> selected;
    try {
      selected = requests.dueRequests(batch);
    } catch (RuntimeException failure) {
      log("select", failure);
      return;
    }
    for (int index = 0;
        index < Math.min(batch, selected.size()) && !Thread.currentThread().isInterrupted();
        index++) {
      var reference = selected.get(index);
      try {
        worker.process(reference.tenantId(), reference.requestId());
      } catch (ManagedPreparationWorker.StorageUnavailable | DataAccessException failure) {
        log("storage", failure);
        return;
      } catch (RuntimeException failure) {
        log("request", failure);
      }
    }
  }

  private static void log(String stage, RuntimeException failure) {
    LOG.warn(
        "Managed preparation recovery failed: stage={}, type={}",
        stage,
        failure.getClass().getSimpleName());
  }
}

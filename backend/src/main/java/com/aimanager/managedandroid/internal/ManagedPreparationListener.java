package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedPreparationRequested;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;
import org.springframework.transaction.event.TransactionalEventListener;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Durable post-commit wake-up. Request rows, rather than listener completion, determine work state.
 * Default closed: the preparation worker must be implemented and validated before activation.
 */
@Component
@ConditionalOnProperty(name = "manager.emm.execution.preparation.enabled", havingValue = "true")
class ManagedPreparationListener {
  private static final Logger LOG = LoggerFactory.getLogger(ManagedPreparationListener.class);
  private final ManagedPreparationWorker worker;

  ManagedPreparationListener(ManagedPreparationWorker worker) {
    this.worker = worker;
  }

  @Async("managedPreparationExecutor")
  @TransactionalEventListener
  public void on(ManagedPreparationRequested request) {
    // Do not use a listener annotation that wraps provider preparation in a new transaction.
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Preparation wake-up must run outside a transaction");
    try {
      worker.process(request.tenantId(), request.requestId());
    } catch (RuntimeException failure) {
      // The async exception handler also logs thrown exceptions; never attach an unsafe cause.
      LOG.warn("Managed preparation wake-up failed: type={}", failure.getClass().getSimpleName());
      throw new IllegalStateException("Managed preparation wake-up failed");
    }
  }
}

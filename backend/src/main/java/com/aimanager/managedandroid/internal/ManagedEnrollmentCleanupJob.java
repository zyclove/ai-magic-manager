package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** Bounded, leased cleanup of cancelled provider tokens across backend replicas. */
@Component
@ConditionalOnProperty(name = "manager.emm.enrollment-cleanup.enabled", havingValue = "true",
    matchIfMissing = true)
class ManagedEnrollmentCleanupJob {
  private static final Logger LOG = LoggerFactory.getLogger(ManagedEnrollmentCleanupJob.class);
  private final ManagedEnrollmentStore store;
  private final ManagedAndroidGateway gateway;
  private final int batch;

  ManagedEnrollmentCleanupJob(
      ManagedEnrollmentStore store,
      ManagedAndroidGateway gateway,
      @Value("${manager.emm.enrollment-cleanup.batch-size:25}") int batch,
      @Value("${manager.emm.enrollment-cleanup.interval-seconds:30}") long intervalSeconds) {
    if (batch < 1 || batch > 100 || intervalSeconds < 5 || intervalSeconds > 3600)
      throw new IllegalArgumentException("Invalid EMM enrollment cleanup configuration");
    this.store = store;
    this.gateway = gateway;
    this.batch = batch;
  }

  @Scheduled(fixedDelayString = "${manager.emm.enrollment-cleanup.interval-seconds:30}",
      initialDelayString = "${manager.emm.enrollment-cleanup.interval-seconds:30}",
      timeUnit = TimeUnit.SECONDS)
  void clean() {
    if (!gateway.available()) return;
    for (var lease : store.claimCleanup(batch)) {
      try {
        if (lease.tokenName() != null)
          gateway.deleteEnrollmentToken(lease.enterpriseId(), lease.tokenName());
        store.completeCleanup(lease);
      } catch (RuntimeException failure) {
        LOG.warn("Managed enrollment cleanup retry scheduled: intent={}, type={}",
            lease.id(), failure.getClass().getSimpleName());
        store.deferCleanup(lease);
      }
    }
  }
}

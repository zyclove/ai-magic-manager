package com.aimanager.quota.internal;

import com.aimanager.quota.QuotaPlanMaintenance;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
    name = "manager.quota.materialization-job.enabled",
    havingValue = "true",
    matchIfMissing = true)
class QuotaPlanJob {
  private final QuotaPlanMaintenance maintenance;
  private final int batch;

  QuotaPlanJob(
      QuotaPlanMaintenance maintenance,
      @Value("${manager.quota.materialization-job.batch-size:100}") int batch,
      @Value("${manager.quota.materialization-job.interval-seconds:30}") long interval) {
    if (batch < 1 || batch > 1000 || interval < 5 || interval > 3600)
      throw new IllegalArgumentException("Invalid quota materialization configuration");
    this.maintenance = maintenance;
    this.batch = batch;
  }

  @Scheduled(
      fixedDelayString = "${manager.quota.materialization-job.interval-seconds:30}",
      timeUnit = java.util.concurrent.TimeUnit.SECONDS)
  public void tick() {
    maintenance.materializeDue(batch);
  }
}

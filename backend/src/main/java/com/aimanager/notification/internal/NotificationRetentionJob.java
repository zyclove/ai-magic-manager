package com.aimanager.notification.internal;

import com.aimanager.notification.NotificationMaintenance;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
    prefix = "manager.notifications.retention-job",
    name = "enabled",
    havingValue = "true",
    matchIfMissing = true)
class NotificationRetentionJob {
  private static final Logger LOG = LoggerFactory.getLogger(NotificationRetentionJob.class);
  private final NotificationMaintenance maintenance;
  private final int batchSize;

  NotificationRetentionJob(
      NotificationMaintenance maintenance,
      @Value("${manager.notifications.retention-job.batch-size:100}") int batchSize) {
    if (batchSize < 1 || batchSize > 500)
      throw new IllegalArgumentException("Invalid notification purge batch");
    this.maintenance = maintenance;
    this.batchSize = batchSize;
  }

  @Scheduled(
      fixedDelayString = "${manager.notifications.retention-job.interval-seconds:300}",
      initialDelayString = "${manager.notifications.retention-job.interval-seconds:300}",
      timeUnit = TimeUnit.SECONDS)
  public void purge() {
    int count = maintenance.purgeExpired(batchSize);
    if (count > 0) LOG.info("notification retention removedCount={}", count);
  }
}

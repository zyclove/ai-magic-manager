package com.aimanager.reporting.internal;

import com.aimanager.reporting.ExportMaintenance;
import java.util.concurrent.TimeUnit;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
    prefix = "manager.exports.worker",
    name = "enabled",
    havingValue = "true",
    matchIfMissing = true)
class ExportSchedule {
  private final ExportMaintenance maintenance;

  ExportSchedule(ExportMaintenance maintenance) {
    this.maintenance = maintenance;
  }

  @Scheduled(
      fixedDelayString = "${manager.exports.worker.interval-seconds:5}",
      initialDelayString = "${manager.exports.worker.interval-seconds:5}",
      timeUnit = TimeUnit.SECONDS)
  public void run() {
    maintenance.purge(25);
    maintenance.runBatch(2);
  }
}

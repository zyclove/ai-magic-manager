package com.aimanager.reporting.internal;

import com.aimanager.reporting.ReportJobMaintenance;
import java.util.concurrent.TimeUnit;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
    prefix = "manager.report-jobs.worker",
    name = "enabled",
    havingValue = "true",
    matchIfMissing = true)
class ReportJobSchedule {
  private final ReportJobMaintenance worker;

  ReportJobSchedule(ReportJobMaintenance worker) {
    this.worker = worker;
  }

  @Scheduled(
      fixedDelayString = "${manager.report-jobs.worker.interval-seconds:5}",
      initialDelayString = "${manager.report-jobs.worker.interval-seconds:5}",
      timeUnit = TimeUnit.SECONDS)
  public void run() {
    worker.purge(25);
    worker.runBatch(2);
  }
}

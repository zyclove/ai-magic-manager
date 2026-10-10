package com.aimanager.support.internal;

import com.aimanager.support.DiagnosticPackageMaintenance;
import java.util.concurrent.TimeUnit;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
    prefix = "manager.diagnostic-packages.worker",
    name = "enabled",
    havingValue = "true",
    matchIfMissing = true)
class DiagnosticPackageSchedule {
  private final DiagnosticPackageMaintenance worker;

  DiagnosticPackageSchedule(DiagnosticPackageMaintenance worker) {
    this.worker = worker;
  }

  @Scheduled(
      fixedDelayString = "${manager.diagnostic-packages.worker.interval-seconds:5}",
      initialDelayString = "${manager.diagnostic-packages.worker.interval-seconds:5}",
      timeUnit = TimeUnit.SECONDS)
  public void run() {
    worker.purge(25);
    worker.runBatch(2);
  }
}

package com.aimanager.retention.internal;

import java.util.concurrent.TimeUnit;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(
    prefix = "manager.erasure-previews.cleanup",
    name = "enabled",
    havingValue = "true",
    matchIfMissing = true)
class ErasurePreviewCleanup {
  private final ErasurePreviewService service;

  ErasurePreviewCleanup(ErasurePreviewService service) {
    this.service = service;
  }

  @Scheduled(
      fixedDelayString = "${manager.erasure-previews.cleanup.interval-seconds:60}",
      initialDelayString = "${manager.erasure-previews.cleanup.interval-seconds:60}",
      timeUnit = TimeUnit.SECONDS)
  public void run() {
    service.purge(50);
  }
}

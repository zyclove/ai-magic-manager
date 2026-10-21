package com.aimanager.notification.internal;

import java.util.concurrent.TimeUnit;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(prefix="manager.family.reminders.worker",name="enabled",havingValue="true")
class FamilyReminderWorker {
  private final FamilyReminderService service;
  private final int batch;
  FamilyReminderWorker(FamilyReminderService service,@Value("${manager.family.reminders.worker.batch-size:50}")int batch) {
    if(batch<1 || batch>100)throw new IllegalArgumentException("Invalid family reminder batch");
    this.service=service;this.batch=batch;
  }
  @Scheduled(fixedDelayString="${manager.family.reminders.worker.interval-seconds:60}",initialDelayString="${manager.family.reminders.worker.interval-seconds:60}",timeUnit=TimeUnit.SECONDS)
  public void scan(){service.scan(batch);}
}

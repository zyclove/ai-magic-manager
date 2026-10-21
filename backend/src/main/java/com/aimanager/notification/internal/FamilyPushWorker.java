package com.aimanager.notification.internal;

import java.util.concurrent.TimeUnit;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@ConditionalOnProperty(prefix="manager.family.push.worker",name="enabled",havingValue="true")
class FamilyPushWorker {
  private final FamilyPushDispatcher dispatcher;
  FamilyPushWorker(FamilyPushDispatcher dispatcher) { this.dispatcher=dispatcher; }
  @Scheduled(fixedDelayString="${manager.family.push.worker.interval-seconds:10}",
      initialDelayString="${manager.family.push.worker.interval-seconds:10}",timeUnit=TimeUnit.SECONDS)
  public void dispatch() { dispatcher.dispatch(50); }
}

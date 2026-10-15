package com.aimanager.managedandroid.internal;

import java.util.concurrent.TimeUnit;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/** 到期清理不依赖提供方在线；停止服务期间仍由请求时间检查拒绝过期挑战。 */
@Component
class ManagedAgentBindingExpiryJob {
  private final ManagedAgentBindingStore store;
  private final int batch;

  ManagedAgentBindingExpiryJob(
      ManagedAgentBindingStore store,
      @Value("${manager.emm.agent-binding.expiry-batch-size:100}") int batch,
      @Value("${manager.emm.agent-binding.expiry-interval-seconds:30}") long interval) {
    if (batch < 1 || batch > 1000 || interval < 5 || interval > 3600)
      throw new IllegalArgumentException("Invalid managed binding expiry configuration");
    this.store = store;
    this.batch = batch;
  }

  @Scheduled(
      fixedDelayString = "${manager.emm.agent-binding.expiry-interval-seconds:30}",
      initialDelayString = "${manager.emm.agent-binding.expiry-interval-seconds:30}",
      timeUnit = TimeUnit.SECONDS)
  void expire() {
    store.expireBatch(batch);
  }
}

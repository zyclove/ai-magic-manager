package com.aimanager.managedandroid.internal;

import java.util.concurrent.ThreadPoolExecutor;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.concurrent.ThreadPoolTaskExecutor;

/** Isolates preparation wake-ups from notifications and from the provider-call executor. */
@Configuration(proxyBeanMethods = false)
@ConditionalOnProperty(name = "manager.emm.execution.preparation.enabled", havingValue = "true")
class ManagedPreparationExecutorConfiguration {
  @Bean(name = "managedPreparationExecutor", defaultCandidate = false)
  ThreadPoolTaskExecutor managedPreparationExecutor(
      @Value("${manager.emm.execution.preparation.executor.workers:2}") int workers,
      @Value("${manager.emm.execution.preparation.executor.queue-capacity:64}") int queue) {
    if (workers < 1 || workers > 16 || queue < 1 || queue > 1024)
      throw new IllegalArgumentException("Invalid preparation event executor capacity");
    var executor =
        new ThreadPoolTaskExecutor() {
          @Override
          protected void initiateEarlyShutdown() {
            // The default early hook drains accepted tasks before destruction. These wake-ups
            // are durable, so cancel queued work immediately instead of starting it during close.
            // A running worker still owns its lease; interruption never certifies remote exit.
            shutdown();
          }
        };
    executor.setCorePoolSize(workers);
    executor.setMaxPoolSize(workers);
    executor.setQueueCapacity(queue);
    executor.setThreadNamePrefix("managed-preparation-");
    executor.setRejectedExecutionHandler(new ThreadPoolExecutor.AbortPolicy());
    executor.setStrictEarlyShutdown(true);
    executor.setAcceptTasksAfterContextClose(false);
    executor.setWaitForTasksToCompleteOnShutdown(false);
    executor.setAwaitTerminationMillis(1000);
    // Spring initializes, monitors and destroys this bean. Never use CallerRuns: callers can
    // still be completing a publication transaction when a post-commit wake-up is rejected.
    return executor;
  }
}

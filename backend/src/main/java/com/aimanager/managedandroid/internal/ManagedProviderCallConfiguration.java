package com.aimanager.managedandroid.internal;

import java.time.Duration;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** Shared lifecycle and bounded settings; creating this pool does not activate a connector. */
@Configuration(proxyBeanMethods = false)
class ManagedProviderCallConfiguration {
  @Bean(destroyMethod = "close")
  ManagedProviderCalls managedProviderCalls(
      @Value("${manager.emm.provider-calls.workers:4}") int workers,
      @Value("${manager.emm.provider-calls.budget-millis:20000}") long budgetMillis) {
    return new ManagedProviderCalls(workers, Duration.ofMillis(budgetMillis), System::nanoTime);
  }
}

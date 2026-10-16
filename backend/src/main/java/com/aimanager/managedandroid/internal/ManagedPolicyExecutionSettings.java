package com.aimanager.managedandroid.internal;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Bounded local scheduling configuration; does not activate a provider or execution capability. */
@Component
final class ManagedPolicyExecutionSettings {
  private final long leaseMillis;
  private final int maximumAttempts;
  private final long retryMillis;

  ManagedPolicyExecutionSettings(
      @Value("${manager.emm.execution.lease-seconds:30}") int leaseSeconds,
      @Value("${manager.emm.execution.maximum-attempts:24}") int attempts,
      @Value("${manager.emm.execution.retry-seconds:10}") int retrySeconds) {
    if (leaseSeconds < 5
        || leaseSeconds > 120
        || attempts < 2
        || attempts > 24
        || retrySeconds < 1
        || retrySeconds > 60)
      throw new IllegalArgumentException("Invalid managed execution scheduling configuration");
    this.leaseMillis = leaseSeconds * 1000L;
    this.maximumAttempts = attempts;
    this.retryMillis = retrySeconds * 1000L;
  }

  long leaseMillis() {
    return leaseMillis;
  }

  int maximumAttempts() {
    return maximumAttempts;
  }

  long retryMillis() {
    return retryMillis;
  }
}

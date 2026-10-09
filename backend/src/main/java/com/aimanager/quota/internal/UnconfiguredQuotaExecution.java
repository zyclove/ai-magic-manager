package com.aimanager.quota.internal;

import com.aimanager.fleet.Device;
import com.aimanager.quota.QuotaExecutionSupport;
import com.aimanager.shared.DomainException;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/**
 * No shipped device adapter currently proves monotonic metering, crash recovery and bounded stop
 * latency.
 */
@Component
class UnconfiguredQuotaExecution implements QuotaExecutionSupport {
  @Override
  public void requireVerified(Device device, String applicationId) {
    throw new DomainException(HttpStatus.CONFLICT, "QUOTA_EXECUTION_UNVERIFIED");
  }
}

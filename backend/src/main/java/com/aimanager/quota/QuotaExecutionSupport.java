package com.aimanager.quota;

import com.aimanager.fleet.Device;

/** Trusted adapter gate: self-reported capability flags must never enable hard quota grants. */
public interface QuotaExecutionSupport {
  void requireVerified(Device device, String applicationId);
}

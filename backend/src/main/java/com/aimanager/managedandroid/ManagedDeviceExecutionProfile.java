package com.aimanager.managedandroid;

/**
 * Provider-read facts for execution preparation, not an authorization or an applied-policy receipt.
 * Never accept this record from a child/client request as trusted device evidence.
 */
public record ManagedDeviceExecutionProfile(
    String deviceName,
    String managementMode,
    int apiLevel,
    String state,
    String appliedState,
    String lastStatusReportTime) {
  @Override
  public String toString() {
    return "ManagedDeviceExecutionProfile[REDACTED]";
  }
}

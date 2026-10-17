package com.aimanager.managedandroid;

/**
 * Coherent provider-side observation of one application's identity, user space and device facts.
 * Only a trusted server connector may construct this input; it is never accepted as a client DTO.
 * Hardware fields must originate from the provider report, not from a catalog qualification.
 */
public record ManagedApplicationControlReport(
    ManagedApplicationReport identity,
    ManagedDeviceExecutionProfile device,
    String profileScope,
    String manufacturer,
    String model,
    String osBuild) {
  @Override
  public String toString() {
    return "ManagedApplicationControlReport[REDACTED]";
  }
}

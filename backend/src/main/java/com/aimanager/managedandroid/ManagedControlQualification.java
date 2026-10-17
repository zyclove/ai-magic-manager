package com.aimanager.managedandroid;

import java.time.Instant;
import java.util.List;

/**
 * Deployment-reviewed device/adapter compatibility entry, supplied as a trusted Spring bean. An
 * empty catalog approves no device. This entry is not tenant authorization or resource ownership.
 * Versions and acceptance references must change when the tested behavior or trust basis changes.
 */
public record ManagedControlQualification(
    String id,
    String revision,
    String provider,
    String reportAdapterRevision,
    String compilerRevision,
    String manufacturer,
    String model,
    String osBuild,
    int apiLevel,
    String managementMode,
    Instant validFrom,
    Instant validUntil,
    String acceptanceReference,
    List<ManagedControlOperation> operations) {
  public ManagedControlQualification {
    operations = operations == null ? List.of() : List.copyOf(operations);
  }

  @Override
  public String toString() {
    return "ManagedControlQualification[REDACTED]";
  }
}

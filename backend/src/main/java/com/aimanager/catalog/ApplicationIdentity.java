package com.aimanager.catalog;

import com.aimanager.fleet.Device;
import java.time.Instant;
import java.util.List;

/**
 * Server-owned immutable declaration metadata for evidence matching. This is not an installation,
 * device-profile or execution claim. Consumers must separately authorize the current target.
 */
public record ApplicationIdentity(
    String applicationId,
    Device.Platform platform,
    String packageName,
    ApplicationDefinition.Profile profile,
    List<String> signingDigests,
    String revision,
    Instant establishedAt) {
  public ApplicationIdentity {
    signingDigests = List.copyOf(signingDigests);
  }

  @Override
  public String toString() {
    return "ApplicationIdentity[REDACTED]";
  }
}

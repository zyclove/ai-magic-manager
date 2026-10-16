package com.aimanager.managedandroid;

import com.aimanager.fleet.FleetPolicyAccess;
import java.util.List;
import java.util.Set;

/**
 * Current, local-only preview inputs. Call inside a READ_COMMITTED transaction before device locks.
 */
public interface ManagedPolicyEvidenceAccess {
  List<Target> snapshot(
      String tenantId, String actorId, List<String> deviceIds, Set<String> applicationIds);

  record Target(FleetPolicyAccess.Target fleet, List<ApplicationEvidence> applications) {
    public Target {
      applications = List.copyOf(applications);
    }
  }

  /** No provider resource, credential, signing certificate or execution authority is exposed. */
  record ApplicationEvidence(
      String deviceId,
      String registrationId,
      String applicationId,
      String bindingId,
      long bindingVersion,
      String definitionRevision,
      long evidenceVersion,
      String state,
      String reasonCode,
      String profileScope,
      boolean systemControlAvailable,
      Long reportedAt,
      Long retrievedAt,
      Long expiresAt) {
    @Override
    public String toString() {
      return "ManagedPolicyApplicationEvidence[REDACTED]";
    }
  }
}

package com.aimanager.managedandroid;

/**
 * Inverted domain boundary: policy owns publication data; a reference is not execution authority.
 */
public interface ManagedExecutionPublicationAccess {
  /** Whole frozen target set for atomic admission; no current-device discovery or provider I/O. */
  Targets requireTargets(String tenant, String actor, String publication);

  record Target(String deviceId, String registrationId) {}

  record Targets(Publication publication, java.util.List<Target> targets) {
    public Targets {
      targets = java.util.List.copyOf(targets);
    }
  }

  /**
   * Requires an actual transaction, current adult authority, ENFORCE, and an exact frozen target.
   */
  Publication requireTarget(
      String tenant, String actor, String publication, String device, String registration);

  /** Resolve all frozen source rules without granting execution authority. */
  ManagedDesiredPolicy requireDesiredTarget(
      String tenant, String actor, String publication, String device, String registration);

  record Publication(String versionId, String previewHash, long createdAt) {}
}

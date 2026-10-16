package com.aimanager.managedandroid;

/**
 * Inverted domain boundary: policy owns publication data; a reference is not execution authority.
 */
public interface ManagedExecutionPublicationAccess {
  /**
   * Requires an actual transaction, current adult authority, ENFORCE, and an exact frozen target.
   */
  Publication requireTarget(
      String tenant, String actor, String publication, String device, String registration);

  record Publication(String versionId, String previewHash, long createdAt) {}
}

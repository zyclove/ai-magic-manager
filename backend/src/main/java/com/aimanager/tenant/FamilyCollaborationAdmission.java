package com.aimanager.tenant;

/** Commercial admission for adding a guardian; existing relationships and recovery stay usable. */
public interface FamilyCollaborationAdmission {
  void requireNewGuardian(String tenantId);
}

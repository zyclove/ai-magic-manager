package com.aimanager.subject;

/**
 * Subject lifecycle facts for trusted domain services. These methods are not public HTTP endpoints.
 */
public interface SubjectAccess {
  Subject lockActiveForScope(String tenantId, String actorId, String subjectId);

  boolean active(String tenantId, String subjectId);

  /**
   * Trusted services have already authorized the exact device/subject scope. Locks lifecycle and
   * returns active status.
   */
  boolean lockForDevice(String tenantId, String subjectId);
}

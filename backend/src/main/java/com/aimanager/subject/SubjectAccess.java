package com.aimanager.subject;

/** Subject lifecycle facts for trusted domain services. These methods are not public HTTP endpoints. */
public interface SubjectAccess {
    Subject lockActiveForScope(String tenantId, String actorId, String subjectId);
    boolean active(String tenantId, String subjectId);
}

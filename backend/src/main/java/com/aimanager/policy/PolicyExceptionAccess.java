package com.aimanager.policy;

import java.util.List;

/** Narrow child-safe baseline, never a tenant-wide draft/snapshot. Caller must hold a write transaction. */
public interface PolicyExceptionAccess {
    Baseline accessWindow(String tenantId, String actorId, String deviceId, String policyId,
                          String baseVersionId, String applicationId, List<String> ruleIds);
    record Baseline(String subjectId, String deviceId, String registrationId, String policyId, String versionId,
                    long sequence, String applicationId, List<String> ruleIds) {}
}

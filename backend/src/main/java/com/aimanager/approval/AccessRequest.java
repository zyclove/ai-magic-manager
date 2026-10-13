package com.aimanager.approval;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;

/** Adult decision, bounded authority and actual execution are independent. Epoch fields are UTC milliseconds. */
public record AccessRequest(String id, String subjectId, String deviceId, String registrationId, String policyId,
                            String baseVersionId, String applicationId, List<String> ruleIds,
                            long requestedWindowSeconds, String reason, State state, long requestExpiresAt,
                            Long grantedWindowSeconds, Long issuedAt, Long absoluteNotAfter, String reasonCode,
                            String executionState, long version, long createdAt,
                            @JsonInclude(JsonInclude.Include.NON_NULL) String subjectName,
                            @JsonInclude(JsonInclude.Include.NON_NULL) String deviceName,
                            @JsonInclude(JsonInclude.Include.NON_NULL) String applicationName,
                            @JsonInclude(JsonInclude.Include.NON_NULL) String applicationPackageName) {
    public enum State { PENDING, APPROVED_PENDING_DELIVERY, DENIED, CANCELLED, EXPIRED, REVOKED, INVALIDATED }
    /** Presentation facts are attached only after tenant and subject scope have been checked. */
    public AccessRequest withDisplayContext(String subject, String device, String application, String packageName) {
        return new AccessRequest(id, subjectId, deviceId, registrationId, policyId, baseVersionId,
            applicationId, ruleIds, requestedWindowSeconds, reason, state, requestExpiresAt,
            grantedWindowSeconds, issuedAt, absoluteNotAfter, reasonCode, executionState, version, createdAt,
            subject, device, application, packageName);
    }
    @Override public String toString() { return "AccessRequest[id=" + id + ", state=" + state + ", version=" + version + "]"; }
}

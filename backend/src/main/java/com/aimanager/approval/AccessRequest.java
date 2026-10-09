package com.aimanager.approval;

import java.util.List;

/** Adult decision, bounded authority and actual execution are independent. Epoch fields are UTC milliseconds. */
public record AccessRequest(String id, String subjectId, String deviceId, String registrationId, String policyId,
                            String baseVersionId, String applicationId, List<String> ruleIds,
                            long requestedWindowSeconds, String reason, State state, long requestExpiresAt,
                            Long grantedWindowSeconds, Long issuedAt, Long absoluteNotAfter, String reasonCode,
                            String executionState, long version, long createdAt) {
    public enum State { PENDING, APPROVED_PENDING_DELIVERY, DENIED, CANCELLED, EXPIRED, REVOKED, INVALIDATED }
    @Override public String toString() { return "AccessRequest[id=" + id + ", state=" + state + ", version=" + version + "]"; }
}

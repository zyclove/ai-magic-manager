package com.aimanager.approval;

/**
 * Minimal in-transaction fact. Never contains the child's reason, a token, or an actor identifier.
 */
public record AccessRequestChanged(
    String tenantId,
    String requestId,
    String subjectId,
    String deviceId,
    String requesterKey,
    long requestVersion,
    AccessRequest.State state,
    long occurredAt) {}

package com.aimanager.delivery;

/** A hint to pull authoritative configuration. Duplicate, delayed and out-of-order hints are harmless. */
public record ConfigurationChangedNotice(String eventId, String tenantId, String deviceId, String registrationId,
                                         String policyId, long cursor, long createdAt, String correlationId) {}

package com.aimanager.delivery;

/** First-delivery expiry and persistent configuration lifetime are deliberately different fields. */
public record ConfigurationEnvelope(int schemaVersion, String issuer, String purpose, String mode, String action,
                                    String tenantId, String deviceId, String registrationId, String policyId,
                                    String versionId, long sourceSequence, long cursor, String deliveryId,
                                    long issuedAt, long deliveryExpiresAt, Long effectiveUntil, ConfigurationDocument document) {}

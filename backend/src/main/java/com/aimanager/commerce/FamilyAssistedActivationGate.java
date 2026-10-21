package com.aimanager.commerce;

/**
 * Server-owned acceptance boundary for actual assisted activation. Enrollment, configuration
 * delivery and a client boolean are insufficient. An implementation must validate signed runtime
 * observation and the configured tested model acceptance policy before returning evidence.
 */
public interface FamilyAssistedActivationGate {
  VerifiedActivation verify(String tenantId, String deviceId);

  record VerifiedActivation(String tenantId, String deviceId, String registrationId,
      long activatedAt, String evidenceHash) {}
}

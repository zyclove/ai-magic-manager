package com.aimanager.managedandroid;

import java.time.Instant;

/**
 * Provider-authenticated observation of an independently audited exclusive policy namespace. Only a
 * trusted server adapter constructs this report after verifying provider-side authority. Echoing
 * the request, reading an absent policy or matching its content is not such verification. This is
 * not a client DTO, atomic resource reservation, or permission to dispatch a write.
 */
public record ManagedPolicyResourceEvidence(
    Target target,
    Mechanism mechanism,
    String evidenceReference,
    String namespaceReference,
    Instant observedAt,
    Instant expiresAt) {

  /**
   * Atomic reservation requires a separate durable workflow and is deliberately not represented.
   */
  public enum Mechanism {
    AUDITED_EXCLUSIVE_NAMESPACE
  }

  public enum Purpose {
    WRITE_POLICY,
    ASSIGN_POLICY
  }

  /**
   * Immutable server-selected task scope. The binding digest covers the complete verified binding,
   * including registration key, enrollment, agent trust and authority versions. No lease secret or
   * policy plaintext crosses this boundary. The provider must verify scope, not merely echo it.
   */
  public record Target(
      String tenantId,
      String taskId,
      String publicationId,
      String policyVersionId,
      String deviceId,
      String registrationId,
      String bindingId,
      long bindingVersion,
      String bindingContextSha256,
      String provider,
      String adapterRevision,
      String enterpriseId,
      long enterpriseBindingVersion,
      String providerDeviceId,
      String policyId,
      Long policyVersion,
      String documentSha256,
      long generation,
      Purpose purpose) {
    @Override
    public String toString() {
      return "ManagedPolicyResourceTarget[REDACTED]";
    }
  }

  @Override
  public String toString() {
    return "ManagedPolicyResourceEvidence[REDACTED]";
  }
}

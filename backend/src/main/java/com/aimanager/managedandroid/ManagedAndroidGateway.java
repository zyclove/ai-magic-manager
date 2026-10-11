package com.aimanager.managedandroid;

import java.time.Duration;
import java.util.List;

/**
 * Server-side boundary for a qualified Android Enterprise provider. Never expose it to a device
 * client.
 */
public interface ManagedAndroidGateway {
  boolean available();

  /**
   * Replaces the complete applications field of an exclusively owned policy. The Google adapter
   * requires that policy to exist with an explicit BLACKLIST Play Store mode; callers must not use
   * this operation to implement an app allowlist or to modify a policy shared with another EMM.
   */
  PolicyReceipt putApplicationPolicy(
      String enterpriseId, String policyId, List<AppRestriction> rules);

  /** Confirms that this provider can read the exact enterprise resource. Not customer ownership. */
  EnterpriseIdentity readEnterprise(String enterpriseId);

  /** Returns secret provisioning material to a trusted, short-lived delivery flow only. */
  default EnrollmentMaterial createEnrollmentToken(
      String enterpriseId, String policyId, Duration lifetime) {
    return createEnrollmentToken(enterpriseId, policyId, lifetime, null);
  }

  /** Additional data is an opaque enrollment nonce, never a child or tenant identifier. */
  EnrollmentMaterial createEnrollmentToken(
      String enterpriseId, String policyId, Duration lifetime, String additionalData);

  /** Reads provider identity evidence before a local device can be bound to it. */
  ManagedEnrollmentIdentity readEnrollmentIdentity(String enterpriseId, String deviceId);

  /** Requests assignment; it does not prove the device has applied the policy. */
  AssignmentReceipt assignPolicy(String enterpriseId, String deviceId, String policyId);

  /** Reads independent device-side application and compliance evidence from the provider. */
  ManagedDeviceState readDeviceState(
      String enterpriseId, String deviceId, String expectedPolicyId, long expectedVersion);

  enum AppControl {
    ALLOW,
    BLOCK_LAUNCH,
    BLOCK_INSTALL
  }

  record AppRestriction(String packageName, AppControl control) {}

  record PolicyReceipt(String policyName, Long providerVersion) {}

  record EnterpriseIdentity(String enterpriseName, String displayName) {}

  /** Values are secrets; do not log, persist in plaintext, or include in exception messages. */
  record EnrollmentMaterial(String tokenName, String value, String qrCode, String expiresAt) {
    @Override
    public String toString() {
      return "EnrollmentMaterial[REDACTED]";
    }
  }

  record AssignmentReceipt(String deviceName, String requestedPolicyName) {}

  /** The token data is a secret correlation nonce. Do not log or return it to a tenant client. */
  record ManagedEnrollmentIdentity(
      String deviceName,
      String managementMode,
      String enrollmentTime,
      String enrollmentTokenName,
      String enrollmentTokenData) {
    @Override
    public String toString() {
      return "ManagedEnrollmentIdentity[REDACTED]";
    }
  }

  enum ApplyState {
    PENDING,
    APPLIED,
    NON_COMPLIANT
  }

  record ManagedDeviceState(
      String deviceName,
      String managementMode,
      String requestedPolicyName,
      String appliedPolicyName,
      Long appliedPolicyVersion,
      ApplyState state,
      List<String> nonComplianceReasons,
      String lastPolicySyncTime) {}
}

package com.aimanager.managedandroid;

import java.time.Duration;
import java.util.List;

/**
 * Server-side boundary for a qualified Android Enterprise provider. Never expose it to a device
 * client.
 */
public interface ManagedAndroidGateway {
  boolean available();

  /** Replaces only the applications field of a policy owned by this integration. */
  PolicyReceipt putApplicationPolicy(
      String enterpriseId, String policyId, List<AppRestriction> rules);

  /** Returns secret provisioning material to a trusted, short-lived delivery flow only. */
  EnrollmentMaterial createEnrollmentToken(String enterpriseId, String policyId, Duration lifetime);

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

  /** Values are secrets; do not log, persist in plaintext, or include in exception messages. */
  record EnrollmentMaterial(String tokenName, String value, String qrCode, String expiresAt) {
    @Override
    public String toString() {
      return "EnrollmentMaterial[REDACTED]";
    }
  }

  record AssignmentReceipt(String deviceName, String requestedPolicyName) {}

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

package com.aimanager.managedandroid;

import java.time.Duration;
import java.util.List;
import java.util.Optional;

/**
 * Server-side boundary for a qualified Android Enterprise provider. Never expose it to a device
 * client.
 */
public interface ManagedAndroidGateway {
  /** Stable provider identity persisted with every enterprise binding and enrollment intent. */
  String providerCode();

  boolean available();

  /** 合作方需显式声明可读取受信应用证据；可连接不等于已支持绑定核验。 */
  default boolean supportsAgentBindingEvidence() { return false; }

  /**
   * Replaces the complete applications field of an exclusively owned policy. The Google adapter
   * requires that policy to exist with an explicit BLACKLIST Play Store mode; callers must not use
   * this operation to implement an app allowlist or to modify a policy shared with another EMM.
   */
  PolicyReceipt putApplicationPolicy(
      String enterpriseId, String policyId, List<AppRestriction> rules);

  /**
   * Replaces one existing app's runtime permission decisions without changing its installation
   * or other application policy fields. This is a provider request, not an applied-device receipt.
   * Auto-grant is deliberately excluded until device-mode-specific validation is available.
   */
  default PolicyReceipt putRuntimePermissionDecisions(
      String enterpriseId, String policyId, String packageName,
      List<RuntimePermissionDecision> decisions) {
    throw new ManagedAndroidUnavailableException();
  }

  /** Confirms that this provider can read the exact enterprise resource. Not customer ownership. */
  EnterpriseIdentity readEnterprise(String enterpriseId);

  /** Requires an exclusively provisioned, minimal policy before issuing an enrollment token. */
  PolicyReceipt requireSafeEnrollmentPolicy(String enterpriseId, String policyId);

  /** Returns secret provisioning material to a trusted, short-lived delivery flow only. */
  default EnrollmentMaterial createEnrollmentToken(
      String enterpriseId, String policyId, Duration lifetime) {
    return createEnrollmentToken(enterpriseId, policyId, lifetime, null);
  }

  /** Additional data is an opaque enrollment nonce, never a child or tenant identifier. */
  EnrollmentMaterial createEnrollmentToken(
      String enterpriseId, String policyId, Duration lifetime, String additionalData);

  /** Invalidates unused provisioning material by its exact resource name. Safe to repeat. */
  void deleteEnrollmentToken(String enterpriseId, String tokenName);

  /** Reads provider identity evidence before a local device can be bound to it. */
  ManagedEnrollmentIdentity readEnrollmentIdentity(String enterpriseId, String deviceId);

  /**
   * 从提供方读取指定应用的短期绑定证明。空值表示报告尚未包含该反馈，不能视为绑定成功。
   * 未实现此能力的合作提供方保持关闭；调用方必须独立验证当前注册、企业权属与证明。
   */
  default Optional<ManagedAgentEvidence> readAgentEvidence(
      String enterpriseId, String deviceId, String packageName) {
    throw new ManagedAndroidUnavailableException();
  }

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

  enum PermissionDecision { DENY, PROMPT }

  record RuntimePermissionDecision(String permission, PermissionDecision decision) {}

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

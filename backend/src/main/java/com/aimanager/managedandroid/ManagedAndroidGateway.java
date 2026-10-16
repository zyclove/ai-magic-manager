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

  /** Provider profile reading only; does not certify a model/OS compatibility matrix. */
  default boolean supportsExecutionProfiles() {
    return false;
  }

  /** Empty only for a provider-confirmed missing device. Other failures must remain failures. */
  default Optional<ManagedDeviceExecutionProfile> readExecutionProfile(
      String enterpriseId, String deviceId) {
    throw new ManagedAndroidUnavailableException();
  }

  /** A transport contract only; does not certify authority or enable execution scheduling. */
  default boolean supportsCompletePolicyDocuments() {
    return false;
  }

  /**
   * Write a complete document to a separately reserved random candidate resource. The provider API
   * may be an upsert; a preliminary 404 is not atomic create-only or exclusive ownership. Callers
   * must persist uncertainty BEFORE dispatch and must not blindly retry this method.
   */
  default PolicyReceipt writePolicyCandidate(
      String enterpriseId, String policyId, PolicyDocument document) {
    throw new ManagedAndroidUnavailableException();
  }

  /**
   * Pure observation, never creates, repairs, or assigns a remote policy. A content match proves
   * neither exclusive ownership nor attribution to this execution. Recovery decisions require
   * separate authorization and ownership checks; the current journal retains NEEDS_REVIEW.
   */
  default CompletePolicyInspection inspectCompletePolicy(
      String enterpriseId, String policyId, PolicyDocument expected, Long expectedVersion) {
    throw new ManagedAndroidUnavailableException();
  }

  /** Values must originate from server compilation and independently verified current context. */
  record PolicyDocument(
      String documentJson,
      String sha256,
      String agentPackage,
      int apiLevel,
      String managementMode) {
    @Override
    public String toString() {
      return "ManagedPolicyDocument[REDACTED]";
    }
  }

  enum CompletePolicyState {
    MATCHED,
    CONTENT_MISMATCH,
    VERSION_MISMATCH,
    NOT_FOUND
  }

  record CompletePolicyInspection(
      String policyName, Long providerVersion, CompletePolicyState state) {
    @Override
    public String toString() {
      return "CompletePolicyInspection[REDACTED]";
    }
  }

  /** 合作方需显式声明可读取受信应用证据；可连接不等于已支持绑定核验。 */
  default boolean supportsAgentBindingEvidence() {
    return false;
  }

  /** 是否具备目标应用事实读取接口；不表示报告已存在、身份已核验或设备可执行策略。 */
  default boolean supportsApplicationReports() {
    return false;
  }

  /**
   * Code/configuration revision of the application-report adapter, not the provider name. Partners
   * must change it whenever report interpretation or provider trust configuration changes. Absence
   * keeps persistent application evidence disabled. Never derives from a client request.
   */
  default String applicationReportRevision() {
    return null;
  }

  /**
   * 读取指定设备和应用的原始报告。空值仅表示报告缺失，不能解释为未安装。 不要求普通目标应用实现平台绑定反馈协议；报告仍需与当前租户、注册、绑定关联。
   * 默认实现保持不支持，合作方必须显式实现并声明读取能力。
   */
  default Optional<ManagedApplicationReport> readApplicationReport(
      String enterpriseId, String deviceId, String packageName) {
    throw new ManagedAndroidUnavailableException();
  }

  /**
   * Replaces the complete applications field of an exclusively owned policy. The Google adapter
   * requires that policy to exist with an explicit BLACKLIST Play Store mode; callers must not use
   * this operation to implement an app allowlist or to modify a policy shared with another EMM.
   */
  PolicyReceipt putApplicationPolicy(
      String enterpriseId, String policyId, List<AppRestriction> rules);

  /**
   * Read-only reconciliation of the complete applications-field control projection. A match is an
   * observation, not proof of write attribution, exclusive resource ownership or device
   * application. A known expected version must match exactly; null requests content-only
   * comparison.
   */
  default ApplicationPolicyInspection inspectApplicationPolicy(
      String enterpriseId, String policyId, List<AppRestriction> expected, Long expectedVersion) {
    throw new ManagedAndroidUnavailableException();
  }

  enum ApplicationPolicyState {
    MATCHED,
    CONTENT_MISMATCH,
    VERSION_MISMATCH,
    NOT_FOUND
  }

  record ApplicationPolicyInspection(
      String policyName, Long providerVersion, ApplicationPolicyState state) {
    @Override
    public String toString() {
      return "ApplicationPolicyInspection[REDACTED]";
    }
  }

  /**
   * Replaces one existing app's runtime permission decisions without changing its installation or
   * other application policy fields. This is a provider request, not an applied-device receipt.
   * Auto-grant is deliberately excluded until device-mode-specific validation is available. A
   * successful receipt must confirm the exact target app and complete requested decision set in the
   * provider's returned policy. Missing or contradictory fields are an uncertain write outcome;
   * reconcile the original policy before any subsequent write.
   */
  default PolicyReceipt putRuntimePermissionDecisions(
      String enterpriseId,
      String policyId,
      String packageName,
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

  /** 从提供方读取指定应用的短期绑定证明。空值表示报告尚未包含该反馈，不能视为绑定成功。 未实现此能力的合作提供方保持关闭；调用方必须独立验证当前注册、企业权属与证明。 */
  default Optional<ManagedAgentEvidence> readAgentEvidence(
      String enterpriseId, String deviceId, String packageName) {
    throw new ManagedAndroidUnavailableException();
  }

  /**
   * Requests assignment and verifies the returned device and requested policy identities. An absent
   * or mismatched response is an uncertain write outcome, not an applied-device receipt; callers
   * must reconcile the original target before considering another write.
   */
  AssignmentReceipt assignPolicy(String enterpriseId, String deviceId, String policyId);

  /**
   * Reads independent device-side application and compliance evidence from the provider. APPLIED
   * requires the exact expected policy resource/version and affirmative, consistent compliance
   * evidence. A newer mutable policy does not prove that the requested version applied.
   */
  ManagedDeviceState readDeviceState(
      String enterpriseId, String deviceId, String expectedPolicyId, long expectedVersion);

  enum AppControl {
    ALLOW,
    BLOCK_LAUNCH,
    BLOCK_INSTALL
  }

  record AppRestriction(String packageName, AppControl control) {}

  enum PermissionDecision {
    DENY,
    PROMPT
  }

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

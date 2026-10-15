package com.aimanager.managedandroid;

import java.util.List;

/** 由服务端合规提供方读取的应用反馈；不得接受设备客户端直接提交此对象作为提供方证据。 证书摘要统一为小写 SHA-256 十六进制。反馈仍需验签、授权及原子消费后才能建立绑定。 */
public record ManagedAgentEvidence(
    String deviceName,
    String managementMode,
    String packageName,
    String applicationState,
    List<String> signingCertificateSha256,
    String feedbackKey,
    String severity,
    String proof,
    String feedbackUpdatedAt,
    String deviceReportedAt) {
  public static final String FEEDBACK_KEY = "ai_manager.binding.v1";

  public ManagedAgentEvidence {
    signingCertificateSha256 =
        signingCertificateSha256 == null ? List.of() : List.copyOf(signingCertificateSha256);
  }

  @Override
  public String toString() {
    return "ManagedAgentEvidence[REDACTED]";
  }
}

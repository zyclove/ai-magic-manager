package com.aimanager.managedandroid;

import java.util.List;

/** Frozen desired inputs, not current capability evidence or permission to contact a provider. */
public record ManagedDesiredPolicy(
    ManagedExecutionPublicationAccess.Publication publication,
    String deviceId,
    String registrationId,
    List<ApplicationIntent> applications,
    List<RuleReadiness> rules,
    List<String> protectedPackages) {
  public ManagedDesiredPolicy {
    applications = List.copyOf(applications);
    rules = List.copyOf(rules);
    protectedPackages = List.copyOf(protectedPackages);
  }

  @Override
  public String toString() {
    return "ManagedDesiredPolicy[REDACTED]";
  }

  /** Catalog identity declarations must be compared with current provider evidence before use. */
  public record ApplicationIntent(
      String applicationId,
      String packageName,
      String profile,
      List<String> signingDigests,
      ManagedAndroidGateway.AppControl control,
      List<ManagedAndroidGateway.RuntimePermissionDecision> permissions,
      List<String> sourceRuleIds,
      List<ManagedControlOperation> requiredOperations) {
    public ApplicationIntent {
      signingDigests = List.copyOf(signingDigests);
      permissions = List.copyOf(permissions);
      sourceRuleIds = List.copyOf(sourceRuleIds);
      requiredOperations = List.copyOf(requiredOperations);
    }

    @Override
    public String toString() {
      return "ManagedApplicationIntent[REDACTED]";
    }
  }

  /** Frozen preview information; SUPPORTED_PENDING is never an execution receipt. */
  public record RuleReadiness(String sourceRuleId, String status, String reasonCode) {}
}

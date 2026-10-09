package com.aimanager.policy;

import java.util.List;

/**
 * Narrow request baseline, never a tenant-wide draft/snapshot. Caller must hold a write
 * transaction.
 */
public interface PolicyExceptionAccess {
  Baseline accessWindow(
      String tenantId,
      String actorId,
      String deviceId,
      String policyId,
      String baseVersionId,
      String applicationId,
      List<String> ruleIds);

  com.aimanager.shared.ItemPage<WindowOptions> requestOptions(
      String tenantId, String actorId, String deviceId, int limit, String cursor);

  record WindowOptions(
      String id,
      String name,
      String baseVersionId,
      List<RuleOption> commonRules,
      List<ApplicationOption> applications) {}

  record ApplicationOption(String id, String displayName, List<RuleOption> rules) {}

  record RuleOption(String id, PolicyRule.Kind kind) {}

  record Baseline(
      String subjectId,
      String deviceId,
      String registrationId,
      String policyId,
      String versionId,
      long sequence,
      String applicationId,
      List<String> ruleIds) {}
}

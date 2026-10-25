package com.aimanager.policy;

import java.util.List;

/** Read-only intent explanation for one exact domain, never an execution result. */
public record PolicyDomainEvaluation(
    String policyId,
    long draftRevision,
    String canonicalDomain,
    List<String> matchingRuleIds,
    PredictedEffect predictedEffect,
    PolicyRule.Effect effectiveEffect,
    MatchMode matchMode,
    ExecutionStatus executionStatus) {
  public PolicyDomainEvaluation {
    matchingRuleIds = List.copyOf(matchingRuleIds);
  }

  public enum PredictedEffect { ALLOW, DENY, NO_MATCH }
  public enum MatchMode { EXACT_DOMAIN }
  public enum ExecutionStatus { NOT_EVALUATED }
}

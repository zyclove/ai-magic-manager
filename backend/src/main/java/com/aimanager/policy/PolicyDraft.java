package com.aimanager.policy;

import java.util.List;

public record PolicyDraft(String id, String name, Kind kind, long revision, List<PolicyRule> rules, String sourceVersionId) {
    public enum Kind { POLICY, TEMPLATE }
}

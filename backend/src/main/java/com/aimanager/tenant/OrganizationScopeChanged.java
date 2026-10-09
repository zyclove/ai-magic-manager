package com.aimanager.tenant;

import java.util.List;

/** Removed roster scope must be reconciled before the organization transaction commits. */
public record OrganizationScopeChanged(
    String tenantId, List<String> actorKeys, List<String> subjectIds, long occurredAt) {
  public OrganizationScopeChanged {
    actorKeys = List.copyOf(actorKeys);
    subjectIds = List.copyOf(subjectIds);
  }
}

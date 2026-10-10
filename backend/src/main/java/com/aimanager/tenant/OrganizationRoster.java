package com.aimanager.tenant;

import java.util.Set;

/** Current class membership for private reporting; does not extend teacher access. */
public interface OrganizationRoster {
  Snapshot lockForPrivateReport(String tenant, String actor, String classId, long expectedVersion);

  record Snapshot(String classId, long version, Set<String> subjectIds) {
    public Snapshot {
      subjectIds = Set.copyOf(subjectIds);
    }
  }
}

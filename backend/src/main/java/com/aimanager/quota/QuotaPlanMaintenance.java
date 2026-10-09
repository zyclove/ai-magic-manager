package com.aimanager.quota;

/**
 * Trusted scheduler boundary. A batch uses one short, independently committed transaction per plan.
 */
public interface QuotaPlanMaintenance {
  int materializeDue(int limit);
}

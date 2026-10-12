package com.aimanager.commerce;

/**
 * Current paid device capacity. Write callers must hold their own domain transaction; the locked
 * read serializes enrollment admission with contract changes across backend replicas.
 */
public interface CommercialCapacity {
  long currentForUpdate(String tenantId);
  long current(String tenantId);
}

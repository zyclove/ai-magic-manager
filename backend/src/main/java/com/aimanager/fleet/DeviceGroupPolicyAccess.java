package com.aimanager.fleet;

import java.util.Map;

/**
 * Policy-facing boundary for an explicit institution group selection. The returned registrations
 * are current facts for one transaction, not a dynamic policy target or execution receipt.
 */
public interface DeviceGroupPolicyAccess {
  Selection resolveCurrent(String tenantId, String actorId, String groupId, long version);

  record Selection(String groupId, long version, Map<String, String> registrations) {}
}

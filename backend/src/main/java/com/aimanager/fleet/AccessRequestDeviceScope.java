package com.aimanager.fleet;

/**
 * Read-only target facts for temporary access requests. This boundary never authorizes fleet,
 * inventory, enrollment, policy, or subject mutations. A caller must hold the membership lock.
 */
public interface AccessRequestDeviceScope {
  Device observeRequestTarget(String tenant, String actor, String device);

  /** Acquire only after the policy and subject lifecycle locks. */
  Device lockRequestTarget(String tenant, String actor, String device);
}

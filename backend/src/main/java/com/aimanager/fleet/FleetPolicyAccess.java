package com.aimanager.fleet;

import java.util.List;

/** Device evidence boundary; callers must not query or mutate fleet tables directly. */
public interface FleetPolicyAccess {
    Target snapshot(String tenantId, String actorId, String deviceId, boolean lock);
    record Target(Device device, List<CapabilityView> capabilities) {}
}

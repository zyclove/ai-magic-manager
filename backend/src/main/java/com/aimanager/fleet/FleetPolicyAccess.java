package com.aimanager.fleet;

import java.util.List;
import com.aimanager.shared.ItemPage;

/** Device evidence boundary; callers must not query or mutate fleet tables directly. */
public interface FleetPolicyAccess {
    Target snapshot(String tenantId, String actorId, String deviceId, boolean lock);
    /** 管理员工作流的有界候选清单；归属与注册仍需在写事务中重新核对。 */
    ItemPage<Device> activeForSubject(String tenantId, String actorId, String subjectId, int limit, String cursor);
    record Target(Device device, List<CapabilityView> capabilities) {}
}

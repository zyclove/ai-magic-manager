package com.aimanager.fleet;

import com.aimanager.deviceidentity.DeviceContext;

/** Fleet-owned scope and lifecycle checks shared with device-facing domain modules. */
public interface DeviceAccess {
    Device requireVisible(String tenantId, String actorId, String deviceId);
    /** Membership then lifecycle locks; use after a policy lock when the operation also references policy. */
    Device lockVisibleActive(String tenantId, String actorId, String deviceId);
    boolean registrationActive(String tenantId, String deviceId, String registrationId, String subjectId);
    /** Transaction required. Locks lifecycle before credential scope to serialize device reports with revocation. */
    Device lockActive(DeviceContext identity);
}

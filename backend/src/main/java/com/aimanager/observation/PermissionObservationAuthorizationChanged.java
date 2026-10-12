package com.aimanager.observation;

/** An authorization epoch changed; downstream snapshots from the old epoch must be erased. */
public record PermissionObservationAuthorizationChanged(String tenantId, String deviceId,
    String registrationId) {}

package com.aimanager.observation;

import com.aimanager.deviceidentity.DeviceContext;

/** Caller must hold the device/credential lifecycle locks in its write transaction. */
public interface PermissionObservationAuthorization {
  void requirePermissionObservation(DeviceContext identity, long authorizationVersion);
  boolean permissionObservationEnabled(String tenantId, String deviceId, String registrationId);
}

package com.aimanager.fleet;

/** Revocation of remote authority; never claims the device has erased local data. */
public record DeviceRegistrationRevoked(String tenantId, String deviceId, String registrationId) {}

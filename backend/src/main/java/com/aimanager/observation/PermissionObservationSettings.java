package com.aimanager.observation;

/** Separate consent for reading an app's requested and observed permission state. */
public record PermissionObservationSettings(String deviceId, String registrationId,
    long version, boolean enabled, Long updatedAt) {}

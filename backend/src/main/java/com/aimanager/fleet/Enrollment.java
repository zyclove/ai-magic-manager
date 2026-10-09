package com.aimanager.fleet;

/** Safe management view: intentionally excludes token and pairing code. */
public record Enrollment(String id, String subjectId, Device.Platform platform, Device.Mode requestedMode,
                         String state, long expiresAt, String deviceId, int pairingFailures) {}

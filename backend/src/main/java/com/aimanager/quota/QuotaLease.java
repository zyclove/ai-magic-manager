package com.aimanager.quota;

public record QuotaLease(
    String id,
    String deviceId,
    String registrationId,
    String applicationId,
    String bootId,
    String sessionId,
    long reservedSeconds,
    long usedSeconds,
    long lastSequence,
    long issuedAt,
    long notAfter,
    String state,
    String signedLease) {}

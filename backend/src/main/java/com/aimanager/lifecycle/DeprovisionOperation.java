package com.aimanager.lifecycle;

/** Device reports remain explicitly unverified; remote access has already been revoked in the creation transaction. */
public record DeprovisionOperation(String id, String deviceId, String registrationId, String commandId, String action,
                                    String state, String remoteAccess, String localEvidence, String reasonCode,
                                    long issuedAt, long notAfter, long version) {}

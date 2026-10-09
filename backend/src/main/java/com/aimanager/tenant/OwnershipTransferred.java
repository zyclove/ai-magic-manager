package com.aimanager.tenant;

/** Synchronous transaction event: former owner remains a member, but old sensitive intent ends. */
public record OwnershipTransferred(
    String tenantId,
    String formerOwnerActorId,
    String formerOwnerActorKey,
    String newOwnerActorId,
    long occurredAt) {}

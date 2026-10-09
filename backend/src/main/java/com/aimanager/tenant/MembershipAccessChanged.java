package com.aimanager.tenant;

/** Previous sensitive intent cannot survive a membership authority epoch change. */
public record MembershipAccessChanged(
    String tenantId, String actorId, String actorKey, boolean revoked, long occurredAt) {}

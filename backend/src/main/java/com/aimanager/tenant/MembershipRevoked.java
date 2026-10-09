package com.aimanager.tenant;

/** Exact actor namespace, not default database text collation. Synchronous in the membership transaction. */
public record MembershipRevoked(String tenantId, String actorKey) {}

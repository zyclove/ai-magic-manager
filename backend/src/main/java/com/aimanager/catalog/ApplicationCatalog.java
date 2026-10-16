package com.aimanager.catalog;

/** Tenant-authorized read boundary used by policy compilation. Identities are immutable after creation. */
public interface ApplicationCatalog {
    ApplicationDefinition requireDeclared(String tenantId, String actorId, String applicationId);
    /** Internal services must authorize their device/tenant context before this identity lookup. */
    ApplicationDefinition requireKnownIdentity(String tenantId, String applicationId);
    /**
     * Requires an existing short transaction and current directory management authority.
     * Locks the actor's membership and returns checked server metadata; does not authorize a device.
     * Missing historical timestamps must be reconfirmed, never silently backfilled by this read.
     */
    ApplicationIdentity requireEvidenceIdentity(String tenantId, String actorId, String applicationId);
}

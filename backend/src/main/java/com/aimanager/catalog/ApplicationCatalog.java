package com.aimanager.catalog;

/** Tenant-authorized read boundary used by policy compilation. Identities are immutable after creation. */
public interface ApplicationCatalog {
    ApplicationDefinition requireDeclared(String tenantId, String actorId, String applicationId);
}

package com.aimanager.policy;

/** Public tenant-authorized operation boundary for delivery diagnostics. */
public interface PolicyReadAccess {
    PolicyPublication publication(String tenantId, String actorId, String publicationId);
}

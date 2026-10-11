package com.aimanager.managedandroid;

/**
 * Resolves a reviewed organization enterprise for server-side operations. This is a live
 * authorization check, not evidence that any device is enrolled or applying a policy.
 */
public interface ManagedEnterpriseAuthority {
  EnterpriseAccess requireActive(String tenantId);

  record EnterpriseAccess(String provider, String enterpriseId, long bindingVersion) {}
}

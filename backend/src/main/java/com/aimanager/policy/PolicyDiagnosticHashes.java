package com.aimanager.policy;

import java.util.Map;

/**
 * Immutable policy fingerprints only, with tenant and policy binding; never returns policy text.
 */
public interface PolicyDiagnosticHashes {
  /**
   * Caller retains authorized lifecycle locks and uses READ_COMMITTED for current committed
   * versions.
   */
  Map<String, String> forAuthorizedDiagnostic(String tenantId, Map<String, String> versionPolicies);
}

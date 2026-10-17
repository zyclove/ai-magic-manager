package com.aimanager.managedandroid;

import java.util.Set;

/**
 * Pure provider-specific translation of a complete desired policy. Implementations are trusted
 * server plugins registered as Spring beans, never client-supplied scripts. No network, credentials
 * or mutable shared state may be used: compilation runs inside a short context-check transaction.
 * Application safety and provider semantics require provider-specific conformance validation.
 */
public interface ManagedPolicyDocumentCompiler {
  /** Stable identifier shared with the configured gateway and reviewed enterprise binding. */
  String providerCode();

  /** Stable format revision written into every complete document; never silently reinterpret it. */
  String adapterRevision();

  /**
   * Return immutable canonical JSON and its digest for this exact agent/device context. The input
   * contains all resolved rules; protected packages must remain usable. A compiled document is not
   * execution authorization, resource ownership evidence or a device receipt.
   */
  ManagedAndroidGateway.PolicyDocument compile(
      ManagedDesiredPolicy desired,
      String agentPackage,
      ManagedDeviceExecutionVerifier.Verified profile,
      Set<String> protectedPackages);
}

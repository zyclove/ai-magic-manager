package com.aimanager.identityproviders.internal;

import java.util.List;

/** Public release responses contain decisions and references, never runtime proofs or paths. */
final class ProviderReleaseContracts {
  private ProviderReleaseContracts() {}
  record ReleaseInput(String id,String kind,String versionId,String preparationId,Long expectedRuntimeRevision,String providerJarSha256,String parentApkSha256) {}
  record CheckInput(String id) {}
  record CancellationInput(String id,Long expectedRuntimeRevision) {}
  record ReleaseTargetView(String versionId,String preparationId,String providerJarSha256,String parentApkSha256,long confirmedAt) {}
  record ReleaseOperationView(String id,String kind,String versionId,String preparationId,String providerJarSha256,String parentApkSha256,long baseRuntimeRevision,
      String state,String reasonCode,long createdAt,Long confirmedAt,boolean canCheckRuntime,boolean canCancel,String runtimeStatus,boolean salesAllowed) {}
  record ReleaseStatusView(String environmentId,long runtimeRevision,boolean observationReady,boolean executorReady,ReleaseOperationView activeOperation,
      ReleaseOperationView confirmedOperation,List<ReleaseTargetView> rollbackTargets,String runtimeStatus,boolean salesAllowed) {}
  record RuntimeInstanceView(String instanceId,String state,String reasonCode,Long observedAt) {}
  record RuntimeCheckView(String id,String operationId,String versionId,String state,String reasonCode,long createdAt,Long completedAt,
      List<RuntimeInstanceView> instances,String runtimeStatus,boolean salesAllowed) {}
  record ExecutorInput(String environmentId,String operationId,String claimId,String nonce,Long issuedAt,String proof,String outcome) {}
  @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.ALWAYS)
  record ExecutorView(String operationId,String claimId,String state,boolean executionAllowed,boolean canFinalizeHostPointer,String currentConfirmedOperationId,boolean canClearPendingHostPointer,String environmentId,String versionId,String preparationId,
      String providerJarSha256,String parentApkSha256,String kind) {}
}

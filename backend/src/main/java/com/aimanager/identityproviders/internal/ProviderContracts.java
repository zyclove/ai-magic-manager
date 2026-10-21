package com.aimanager.identityproviders.internal;

import java.util.List;
import java.util.Map;

/** Explicit response types keep encrypted material and supplier inputs out of public views. */
final class ProviderContracts {
  private ProviderContracts() {}
  record Settings(String smsSignName,String smsTemplateCode,String wechatAppId,String parentPackageName,String parentCertificateSha256) {}
  record SaveVersion(String id,Long baseVersion,Settings settings,Map<String,String> replacements,boolean clearSmsSecurityToken) {}
  record PreparationInput(String id) {}
  record AcceptanceInput(String id,String versionId,String environmentId,String providerJarSha256,String parentApkSha256,String releaseOperationId,Long expectedRuntimeRevision) {}
  record Capabilities(boolean canRead,boolean canManage,boolean canTest,boolean secretStorageReady,boolean releasePreparationReady) {}
  record VersionView(String id,long version,long baseVersion,long createdAt,Settings settings,Map<String,Boolean> credentials,String readinessStatus) {}
  record Check(String id,String label,String stage,String status,String reasonCode,String action) {}
  record StatusView(String environmentId,Capabilities capabilities,long latestVersion,VersionView version,List<Check> readinessChecks,String runtimeStatus,boolean salesAllowed) {}
  record ValidationView(String versionId,String readinessStatus,List<Check> checks,String runtimeStatus,boolean salesAllowed) {}
  record PreparationView(String id,String versionId,String status,String reasonCode,String runtimeStatus,boolean salesAllowed) {}
  record PreparationListView(List<PreparationView> items) {}
  @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.ALWAYS)
  record AcceptanceView(String id,String versionId,String environmentId,String providerJarSha256,String parentApkSha256,long createdAt,String status,List<Check> checks,String runtimeStatus,boolean salesAllowed,boolean providerRequestsPerformed,
      String releaseOperationId,Long runtimeRevision,Long expiresAt) {}
  record AcceptanceListView(List<AcceptanceView> items) {}
  record SalesGateView(boolean allowed,String status,List<Check> checks) {}
  @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.ALWAYS)
  record AcceptanceStatusView(String environmentId,String versionId,String confirmedOperationId,long runtimeRevision,String status,String nextAction,
      int passedCount,int requiredCount,AcceptanceView latestRun,List<Check> readinessChecks,List<Check> checks,SalesGateView salesGate) {}
  record ReleasePayload(int schemaVersion,String versionId,Settings settings,Map<String,String> credentials) {}
  record ReleaseBundle(int schemaVersion,String environmentId,String versionId,String protectedPayload) {}
}

package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedAndroidUnavailableException;
import java.time.Duration;
import java.util.List;

/** Explicit safe default; an unavailable provider never simulates managed enforcement. */
public final class UnavailableManagedAndroidGateway implements ManagedAndroidGateway {
  @Override
  public String providerCode() {
    return "GOOGLE_AMAPI";
  }

  @Override
  public boolean available() {
    return false;
  }

  @Override
  public PolicyReceipt putApplicationPolicy(
      String enterpriseId, String policyId, List<AppRestriction> rules) {
    throw new ManagedAndroidUnavailableException();
  }

  @Override
  public PolicyReceipt putRuntimePermissionDecisions(
      String enterpriseId, String policyId, String packageName,
      List<RuntimePermissionDecision> decisions) {
    throw new ManagedAndroidUnavailableException();
  }

  @Override
  public EnterpriseIdentity readEnterprise(String enterpriseId) {
    throw new ManagedAndroidUnavailableException();
  }

  @Override
  public PolicyReceipt requireSafeEnrollmentPolicy(String enterpriseId, String policyId) {
    throw new ManagedAndroidUnavailableException();
  }

  @Override
  public EnrollmentMaterial createEnrollmentToken(
      String enterpriseId, String policyId, Duration lifetime, String additionalData) {
    throw new ManagedAndroidUnavailableException();
  }

  @Override
  public void deleteEnrollmentToken(String enterpriseId, String tokenName) {
    throw new ManagedAndroidUnavailableException();
  }

  @Override
  public ManagedEnrollmentIdentity readEnrollmentIdentity(String enterpriseId, String deviceId) {
    throw new ManagedAndroidUnavailableException();
  }

  @Override
  public AssignmentReceipt assignPolicy(String enterpriseId, String deviceId, String policyId) {
    throw new ManagedAndroidUnavailableException();
  }

  @Override
  public ManagedDeviceState readDeviceState(
      String enterpriseId, String deviceId, String expectedPolicyId, long expectedVersion) {
    throw new ManagedAndroidUnavailableException();
  }
}

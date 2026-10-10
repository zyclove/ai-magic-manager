package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedAndroidUnavailableException;
import java.time.Duration;
import java.util.List;

/** Explicit safe default; an unavailable provider never simulates managed enforcement. */
public final class UnavailableManagedAndroidGateway implements ManagedAndroidGateway {
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
  public EnrollmentMaterial createEnrollmentToken(
      String enterpriseId, String policyId, Duration lifetime) {
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

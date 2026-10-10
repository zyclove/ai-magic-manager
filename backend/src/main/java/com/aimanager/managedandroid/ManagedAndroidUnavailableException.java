package com.aimanager.managedandroid;

/** Fail-closed result while commercial eligibility or credentials are unavailable. */
public final class ManagedAndroidUnavailableException extends IllegalStateException {
  public ManagedAndroidUnavailableException() {
    super("Android Enterprise connector is disabled or not qualified");
  }
}

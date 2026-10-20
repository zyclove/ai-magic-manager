package com.aimanager.managedandroid;

/** Atomic preparation intake within the publishing transaction; no provider write or assignment. */
public interface ManagedExecutionAdmission {
  /**
   * Reads the full frozen selection from server publication data, never a caller's target subset.
   */
  void accept(String tenant, String actor, String publication);
}

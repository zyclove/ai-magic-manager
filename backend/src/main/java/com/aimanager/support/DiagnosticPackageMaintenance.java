package com.aimanager.support;

/** Bounded persistent work and artifact cleanup; does not grant callers diagnostic access. */
public interface DiagnosticPackageMaintenance {
  int runBatch(int limit);

  int purge(int limit);
}

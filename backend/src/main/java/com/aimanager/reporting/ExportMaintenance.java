package com.aimanager.reporting;

/** Bounded durable work. No public HTTP endpoint can invoke this maintenance interface. */
public interface ExportMaintenance {
  int runBatch(int limit);

  int purge(int limit);
}

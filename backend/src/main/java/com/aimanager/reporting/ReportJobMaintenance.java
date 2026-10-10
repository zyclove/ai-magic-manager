package com.aimanager.reporting;

/** Bounded durable report work. Each claim produces at most one device result. */
public interface ReportJobMaintenance {
  int runBatch(int limit);

  int purge(int limit);
}

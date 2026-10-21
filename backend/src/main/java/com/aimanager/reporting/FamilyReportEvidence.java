package com.aimanager.reporting;
import java.util.Map;
/** Authorized anonymous aggregates for the adult family assistant. */
public interface FamilyReportEvidence {
  Map<String,Object> read(String tenant,String actor,String subject,String device);
}

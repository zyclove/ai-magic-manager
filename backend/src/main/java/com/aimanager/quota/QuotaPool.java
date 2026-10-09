package com.aimanager.quota;

/** Ledger facts, not a claim that a device stopped an application. Seconds are integer units. */
public record QuotaPool(
    String id,
    String subjectId,
    String name,
    Scope scope,
    String applicationId,
    String periodId,
    String timeZone,
    long periodStart,
    long periodEnd,
    long limitSeconds,
    long usedSeconds,
    long reservedSeconds,
    long availableSeconds,
    String status,
    String evidenceStatus,
    long version,
    String planId,
    Long planVersion) {
  public enum Scope {
    TOTAL,
    APPLICATION
  }
}

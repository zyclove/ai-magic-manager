package com.aimanager.quota;

import java.time.DayOfWeek;
import java.util.Map;

/**
 * Latest confirmed configuration. effectiveFrom is explicit; jobs never change its strong version.
 */
public record QuotaPlan(
    String id,
    String subjectId,
    QuotaPool.Scope scope,
    String applicationId,
    String timeZone,
    String name,
    State state,
    String effectiveFrom,
    Map<DayOfWeek, Long> weeklyLimits,
    Map<String, Long> dateOverrides,
    long version,
    long createdAt) {
  public enum State {
    ACTIVE,
    PAUSED
  }

  public record Configuration(
      String name,
      State state,
      Map<DayOfWeek, Long> weeklyLimits,
      Map<String, Long> dateOverrides) {}

  public record Revision(
      long version, String effectiveFrom, Configuration configuration, long createdAt) {}
}

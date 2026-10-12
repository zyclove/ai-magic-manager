package com.aimanager.reporting.internal;

import static com.aimanager.tenant.TenantAccess.Role.GUARDIAN;
import static com.aimanager.tenant.TenantAccess.Role.ORG_ADMIN;
import static com.aimanager.tenant.TenantAccess.Role.OWNER;

import com.aimanager.shared.SafetyCriticalPackages;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Set;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** On-demand, explainable wellbeing suggestions. No model, profiling label, or policy write. */
@Service
class WellbeingInsightService {
  private static final long DAILY_MINIMUM_MILLIS = 2L * 60 * 60 * 1000;
  private final UsageReportService reports;
  private final TenantAccess access;
  private final JdbcTemplate jdbc;
  private final Clock clock;
  private final Set<String> protectedPackages;

  WellbeingInsightService(
      UsageReportService reports, TenantAccess access, JdbcTemplate jdbc, Clock clock,
      @Value("${manager.policies.additional-protected-packages:}") String additionalProtectedPackages) {
    this.reports = reports;
    this.access = access;
    this.jdbc = jdbc;
    this.clock = clock;
    this.protectedPackages = SafetyCriticalPackages.withAdditional(additionalProtectedPackages);
  }

  @Transactional(timeout = 10)
  Insight read(String tenant, String actor, String deviceId) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    String zoneName = jdbc.queryForObject(
        "SELECT time_zone FROM tenants WHERE id=?", String.class, tenant);
    ZoneId zone = ZoneId.of(zoneName);
    var today = Instant.ofEpochMilli(clock.millis()).atZone(zone).toLocalDate();
    long from = today.minusDays(7).atStartOfDay(zone).toInstant().toEpochMilli();
    long to = today.atStartOfDay(zone).toInstant().toEpochMilli();
    var report = reports.query(tenant, actor, List.of(deviceId), from, to, zoneName, "DAY",
        new UsageReportScope.Selection("DEVICES", null, null));
    if (report.devices().size() != 1 || !deviceId.equals(report.devices().get(0).deviceId()))
      throw new IllegalStateException("Usage insight report scope changed");
    var device = report.devices().get(0);
    String status;
    List<Suggestion> suggestions = List.of();
    long window = report.to() - report.from();
    if ("NOT_AUTHORIZED".equals(device.status())) status = "NOT_AUTHORIZED";
    else if (!"OBSERVED".equals(device.status())) status = "NO_DATA";
    else if (window <= 0 || device.queryCoverageMillis() * 100 < window * 80)
      status = "INSUFFICIENT_COVERAGE";
    else {
      var candidates = new ArrayList<Suggestion>();
      for (var app : device.applications()) {
        if (!"PRIMARY".equals(app.profile())
            || protectedPackages.contains(app.packageName().toLowerCase(java.util.Locale.ROOT)))
          continue;
        int days = 0;
        for (var bucket : app.buckets())
          if (bucket.lowerMillis() != null
              && bucket.lowerMillis() >= DAILY_MINIMUM_MILLIS) days++;
        if (days >= 3) candidates.add(new Suggestion(
            "REVIEW_APP_TIME", app.packageName(), app.displayName(), days,
            DAILY_MINIMUM_MILLIS));
      }
      candidates.sort(Comparator.comparingInt(Suggestion::days).reversed()
          .thenComparing(Suggestion::packageName));
      suggestions = List.copyOf(candidates.subList(0, Math.min(3, candidates.size())));
      status = suggestions.isEmpty() ? "NO_PATTERN" : "SUGGESTIONS";
    }
    return new Insight(1, tenant, deviceId, device.registrationId(), report.generatedAt(),
        report.from(), report.to(), zoneName, report.evidenceStatus(), status,
        device.queryCoverageMillis(), List.copyOf(suggestions));
  }

  record Suggestion(
      String kind, String packageName, String displayName, int days,
      long minimumDailyMillis) {}

  record Insight(
      int schemaVersion, String tenantId, String deviceId, String registrationId,
      long generatedAt, long from, long to, String timeZone, String evidenceStatus,
      String status, long queryCoverageMillis, List<Suggestion> suggestions) {}
}

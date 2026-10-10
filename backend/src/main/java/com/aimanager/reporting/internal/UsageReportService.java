package com.aimanager.reporting.internal;

import com.aimanager.catalog.ApplicationCategories;
import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.delivery.ReportConfigurationSource;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.observation.UsageReportSource;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class UsageReportService {
  private final UsageReportSource source;
  private final ObjectMapper json;
  private final Clock clock;
  private final UsageReportScope scopes;
  private final ApplicationCategories categories;
  private final ReportConfigurationSource configurations;

  UsageReportService(
      UsageReportSource source,
      ObjectMapper json,
      Clock clock,
      UsageReportScope scopes,
      ApplicationCategories categories,
      ReportConfigurationSource configurations) {
    this.source = source;
    this.json = json;
    this.clock = clock;
    this.scopes = scopes;
    this.categories = categories;
    this.configurations = configurations;
  }

  @Transactional(timeout = 10)
  public Report query(
      String tenant,
      String actor,
      List<String> ids,
      long from,
      long requestedTo,
      String zone,
      String period,
      UsageReportScope.Selection scope) {
    if (ids == null
        || ids.isEmpty()
        || ids.size() > 20
        || new HashSet<>(ids).size() != ids.size()
        || ids.stream()
            .anyMatch(
                id ->
                    id == null
                        || !id.matches(
                            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")))
      throw DomainException.invalid("INVALID_REPORT_SELECTION");
    validateQuery(from, requestedTo, zone, period);
    var bindings = scopes.prepare(tenant, actor, ids, scope);
    var snapshot = source.read(tenant, actor, ids, from);
    scopes.verify(bindings, snapshot);
    return aggregate(tenant, snapshot, from, requestedTo, zone, period, scope);
  }

  @Transactional(timeout = 10)
  public Report queryDevice(
      DeviceContext identity, long from, long requestedTo, String zone, String period) {
    validateQuery(from, requestedTo, zone, period);
    var snapshot = source.readDevice(identity, from);
    return aggregate(
        identity.tenantId(),
        snapshot,
        from,
        requestedTo,
        zone,
        period,
        new UsageReportScope.Selection("DEVICES", null, null));
  }

  void validateQuery(long from, long requestedTo, String zone, String period) {
    try {
      UsageAggregation.validateWindow(from, requestedTo);
      if (zone == null
          || period == null
          || !ZoneId.getAvailableZoneIds().contains(zone)
          || !Set.of("DAY", "WEEK").contains(period)) throw new IllegalArgumentException();
      UsageAggregation.validateWindow(from, Math.min(requestedTo, clock.millis()));
    } catch (IllegalArgumentException invalid) {
      throw DomainException.invalid("INVALID_USAGE_REPORT_QUERY");
    }
  }

  private Report aggregate(
      String tenant,
      UsageReportSource.Snapshot snapshot,
      long from,
      long requestedTo,
      String zone,
      String period,
      UsageReportScope.Selection scope) {
    var configurationStates =
        configurations.forAuthorizedReport(
            tenant, snapshot.devices().stream().map(UsageReportSource.DeviceData::device).toList());
    long to = Math.min(requestedTo, snapshot.generatedAt());
    var devices = new ArrayList<DeviceReport>();
    int appCount = 0;
    for (var data : snapshot.devices()) {
      var samples = new ArrayList<UsageAggregation.Sample>();
      var windows = new ArrayList<UsageAggregation.Window>();
      var zones = new TreeSet<String>();
      Long observed = null, received = null;
      int count = 0;
      for (var batch : data.batches()) {
        boolean queryIntersects = batch.queryStart() < to && batch.queryEnd() > from;
        boolean appIntersects =
            batch.applications().stream().anyMatch(a -> a.start() < to && a.end() > from);
        if (!queryIntersects && !appIntersects) continue;
        count++;
        zones.add(batch.timeZone());
        observed = observed == null ? batch.observedAt() : Math.max(observed, batch.observedAt());
        received = received == null ? batch.receivedAt() : Math.max(received, batch.receivedAt());
        if (queryIntersects)
          windows.add(
              new UsageAggregation.Window(
                  Math.max(from, batch.queryStart()), Math.min(to, batch.queryEnd())));
        for (var app : batch.applications())
          if (app.start() < to && app.end() > from)
            samples.add(
                new UsageAggregation.Sample(
                    batch.sequence(),
                    batch.profile(),
                    app.packageName(),
                    app.displayName(),
                    app.start(),
                    app.end(),
                    app.foregroundMillis()));
      }
      if (samples.size() > 100000) throw tooLarge();
      if (samples.stream()
              .map(s -> s.profile() + "|" + s.packageName())
              .distinct()
              .limit(2001)
              .count()
          > 2000) throw tooLarge();
      final List<UsageAggregation.Application> apps;
      try {
        apps = UsageAggregation.aggregate(samples, from, to, zone, period);
      } catch (IllegalArgumentException invalid) {
        throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "USAGE_REPORT_DATA_UNAVAILABLE");
      }
      appCount += apps.size();
      if (appCount > 2000) throw tooLarge();
      var identities = new HashSet<ApplicationCategories.Identity>();
      for (var app : apps)
        identities.add(
            new ApplicationCategories.Identity(
                data.device().platform(),
                ApplicationDefinition.Profile.valueOf(app.profile()),
                app.packageName()));
      var classifications = categories.forAuthorizedUsageReport(tenant, identities);
      var labeledApps =
          apps.stream()
              .map(
                  app ->
                      new ApplicationReport(
                          app.profile(),
                          app.packageName(),
                          app.displayName(),
                          app.selectedIntervals(),
                          app.discardedOverlaps(),
                          app.buckets(),
                          classifications.get(
                              new ApplicationCategories.Identity(
                                  data.device().platform(),
                                  ApplicationDefinition.Profile.valueOf(app.profile()),
                                  app.packageName()))))
              .toList();
      long coverage = coverage(windows);
      String state =
          !data.settings().usageEnabled() ? "NOT_AUTHORIZED" : count == 0 ? "NO_DATA" : "OBSERVED";
      devices.add(
          new DeviceReport(
              data.device().id(),
              data.device().registrationId(),
              data.device().subjectId(),
              data.device().displayName(),
              state,
              data.settings().version(),
              data.retentionFrom(),
              count,
              List.copyOf(zones),
              observed,
              received,
              coverage,
              to - from - coverage,
              labeledApps,
              configurationStates.get(data.device().id())));
    }
    var report =
        new Report(
            1,
            snapshot.generatedAt(),
            from,
            to,
            requestedTo,
            zone,
            period,
            "OS_AGGREGATE",
            "AGENT_REPORTED_UNVERIFIED",
            List.copyOf(devices),
            scope);
    try {
      if (json.writeValueAsBytes(report).length > 8 * 1024 * 1024) throw tooLarge();
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Usage report serialization failed");
    }
    return report;
  }

  private long coverage(List<UsageAggregation.Window> windows) {
    windows.sort(Comparator.comparingLong(UsageAggregation.Window::start));
    long covered = 0, end = Long.MIN_VALUE;
    for (var window : windows) {
      long start = Math.max(end, window.start());
      if (window.end() > start) covered += window.end() - start;
      end = Math.max(end, window.end());
    }
    return covered;
  }

  private DomainException tooLarge() {
    return new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "USAGE_REPORT_TOO_LARGE");
  }

  record DeviceReport(
      String deviceId,
      String registrationId,
      String subjectId,
      String displayName,
      String status,
      long authorizationVersion,
      long retentionFrom,
      int sourceBatchCount,
      List<String> sourceTimeZones,
      Long latestObservedAt,
      Long latestReceivedAt,
      long queryCoverageMillis,
      long uncoveredQueryMillis,
      List<ApplicationReport> applications,
      ReportConfigurationSource.State configurationState) {}

  record ApplicationReport(
      String profile,
      String packageName,
      String displayName,
      int selectedIntervals,
      int discardedOverlaps,
      List<UsageAggregation.Bucket> buckets,
      ApplicationCategories.Classification classification) {}

  record Report(
      int schemaVersion,
      long generatedAt,
      long from,
      long to,
      long requestedTo,
      String timeZone,
      String period,
      String precision,
      String evidenceStatus,
      List<DeviceReport> devices,
      UsageReportScope.Selection scope) {}
}

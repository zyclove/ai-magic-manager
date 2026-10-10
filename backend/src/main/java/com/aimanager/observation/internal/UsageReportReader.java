package com.aimanager.observation.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.*;
import com.aimanager.observation.*;
import com.aimanager.shared.DomainException;
import com.aimanager.subject.SubjectAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.validation.Validator;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class UsageReportReader implements UsageReportSource {
  private final DeviceAccess devices;
  private final DeviceCredentials credentials;
  private final SubjectAccess subjects;
  private final ObservationSettingsService settings;
  private final JdbcTemplate db;
  private final ObjectMapper json;
  private final Validator validator;
  private final Clock clock;
  private final long retentionMillis;
  private final long maxBytes;

  UsageReportReader(
      DeviceAccess devices,
      DeviceCredentials credentials,
      SubjectAccess subjects,
      ObservationSettingsService settings,
      JdbcTemplate db,
      ObjectMapper json,
      Validator validator,
      Clock clock,
      @Value("${manager.observations.retention-days:30}") long days,
      @Value("${manager.reports.max-source-bytes:33554432}") long maxBytes) {
    if (days < 1 || days > 90) throw new IllegalArgumentException("Invalid observation retention");
    if (maxBytes < 1024 || maxBytes > 32L * 1024 * 1024)
      throw new IllegalArgumentException("Invalid report source bound");
    this.devices = devices;
    this.credentials = credentials;
    this.subjects = subjects;
    this.settings = settings;
    this.db = db;
    this.json = json;
    this.validator = validator;
    this.clock = clock;
    retentionMillis = days * 86400000;
    this.maxBytes = maxBytes;
  }

  @Override
  @Transactional(timeout = 10)
  public Snapshot read(String tenant, String actor, List<String> ids, long from) {
    if (ids == null || ids.isEmpty() || ids.size() > 20 || new HashSet<>(ids).size() != ids.size())
      throw DomainException.invalid("INVALID_REPORT_SELECTION");
    var locked = new ArrayList<Device>();
    // Lock all requested devices in a stable order before reading consent or payloads.
    // DeviceAccess locks current membership first and enforces the child's own subject.
    for (String id : ids.stream().sorted().toList())
      locked.add(devices.lockVisibleActive(tenant, actor, id));
    return readLocked(tenant, locked, from);
  }

  @Override
  @Transactional(timeout = 10)
  public Snapshot authorize(String tenant, String actor, List<String> ids) {
    if (ids == null || ids.isEmpty() || ids.size() > 200 || new HashSet<>(ids).size() != ids.size())
      throw DomainException.invalid("INVALID_REPORT_SELECTION");
    var bindings = new TreeMap<String, String>();
    for (var id : ids) bindings.put(id, devices.requireVisible(tenant, actor, id).subjectId());
    for (var subject : new TreeSet<>(bindings.values()))
      subjects.lockActiveForScope(tenant, actor, subject);
    var locked = new ArrayList<Device>();
    for (var id : bindings.keySet()) {
      var device = devices.lockVisibleActive(tenant, actor, id);
      if (!device.subjectId().equals(bindings.get(id)))
        throw new DomainException(HttpStatus.CONFLICT, "REPORT_SCOPE_CHANGED");
      locked.add(device);
    }
    long generated = clock.millis();
    var result = new ArrayList<DeviceData>();
    for (var device : locked)
      result.add(
          new DeviceData(
              device,
              settings.current(tenant, device.id(), device.registrationId(), true),
              generated - retentionMillis,
              List.of()));
    return new Snapshot(generated, result);
  }

  @Override
  @Transactional(timeout = 10)
  public Snapshot readDevice(DeviceContext identity, long from) {
    // Same subject -> device -> credential order as other device-facing read models.
    var observed = devices.observeActive(identity);
    boolean active = subjects.lockForDevice(identity.tenantId(), observed.subjectId());
    var current = devices.lockActive(identity);
    if (!current.subjectId().equals(observed.subjectId()))
      throw new DomainException(HttpStatus.CONFLICT, "REPORT_SCOPE_CHANGED");
    credentials.requireActive(identity);
    if (!active) throw DomainException.denied();
    return readLocked(identity.tenantId(), List.of(current), from);
  }

  private Snapshot readLocked(String tenant, List<Device> locked, long from) {
    long generated = clock.millis(), retentionFrom = generated - retentionMillis;
    var result = new ArrayList<DeviceData>();
    long totalBytes = 0;
    for (var device : locked) {
      var consent = settings.current(tenant, device.id(), device.registrationId(), true);
      if (!consent.usageEnabled()) {
        result.add(new DeviceData(device, consent, retentionFrom, List.of()));
        continue;
      }
      // Accepted observations may be 5 minutes ahead, and application boundaries a
      // further 5 minutes ahead. Earlier received rows cannot overlap this window.
      long cutoff = Math.max(retentionFrom, from - 600000);
      String predicate = "tenant_id=? AND device_id=? AND registration_id=? AND received_at>=?";
      Object[] args = {tenant, device.id(), device.registrationId(), cutoff};
      long bytes =
          db.queryForObject(
              "SELECT COALESCE(SUM(OCTET_LENGTH(payload_json)),0) FROM usage_observation_batches"
                  + " WHERE "
                  + predicate,
              Long.class,
              args);
      totalBytes += bytes;
      if (totalBytes > maxBytes)
        throw new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "USAGE_REPORT_TOO_LARGE");
      var batches =
          db.query(
              "SELECT payload_json,received_at,sequence_number,report_id,authorization_version FROM"
                  + " usage_observation_batches WHERE "
                  + predicate
                  + " ORDER BY sequence_number DESC LIMIT 1025",
              (r, n) ->
                  parse(
                      r.getString(1),
                      r.getLong(2),
                      r.getLong(3),
                      r.getString(4),
                      r.getLong(5),
                      consent.version()),
              args);
      if (batches.size() > 1024)
        throw new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "USAGE_REPORT_TOO_LARGE");
      result.add(new DeviceData(device, consent, retentionFrom, batches));
    }
    return new Snapshot(generated, result);
  }

  private Batch parse(
      String payload,
      long received,
      long sequence,
      String reportId,
      long authorizationVersion,
      long currentVersion) {
    try {
      var report = json.readValue(payload, UsageObservationController.Report.class);
      if (report == null
          || !validator.validate(report).isEmpty()
          || report.queryStart() >= report.queryEnd()
          || report.queryEnd() > report.observedAt()
          || report.sequence() != sequence
          || !reportId.equals(report.reportId())
          || report.authorizationVersion() != authorizationVersion
          || authorizationVersion > currentVersion) throw unavailable();
      var apps = new ArrayList<Application>();
      for (var app : report.applications()) {
        if (app.firstTimeStamp() > app.lastTimeStamp()
            || app.foregroundMillis() > app.lastTimeStamp() - app.firstTimeStamp())
          throw unavailable();
        apps.add(
            new Application(
                app.packageName(),
                app.displayName(),
                app.firstTimeStamp(),
                app.lastTimeStamp(),
                app.foregroundMillis()));
      }
      return new Batch(
          report.sequence(),
          report.profile(),
          report.queryStart(),
          report.queryEnd(),
          report.observedAt(),
          report.timeZone(),
          received,
          apps);
    } catch (JsonProcessingException invalid) {
      throw unavailable();
    }
  }

  private DomainException unavailable() {
    return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "USAGE_REPORT_DATA_UNAVAILABLE");
  }
}

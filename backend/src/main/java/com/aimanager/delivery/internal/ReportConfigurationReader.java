package com.aimanager.delivery.internal;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.delivery.ConfigurationDocument;
import com.aimanager.delivery.ReportConfigurationSource;
import com.aimanager.fleet.Device;
import com.aimanager.schedule.ScheduleEntry;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
class ReportConfigurationReader implements ReportConfigurationSource {
  private final JdbcTemplate jdbc;
  private final ObjectMapper json;
  private final Clock clock;

  ReportConfigurationReader(JdbcTemplate jdbc, ObjectMapper json, Clock clock) {
    this.jdbc = jdbc;
    this.json = json;
    this.clock = clock;
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public Map<String, State> forAuthorizedReport(String tenant, List<Device> devices) {
    if (devices == null || devices.size() > 20 || devices.stream().anyMatch(Objects::isNull))
      throw DomainException.invalid("INVALID_REPORT_SELECTION");
    var sorted = new TreeMap<String, Device>();
    var deviceIds = new HashSet<String>();
    for (var device : devices) {
      if (device.registrationId() == null
          || device.id() == null
          || device.state() != Device.State.ACTIVE
          || !deviceIds.add(device.id())
          || sorted.put(device.registrationId(), device) != null)
        throw DomainException.invalid("INVALID_REPORT_SELECTION");
    }
    // Match delivery's registration order. No head is created by this read-only source.
    var heads = new HashSet<String>();
    for (var device : sorted.values()) {
      var existing =
          jdbc.queryForList(
              "SELECT device_id FROM configuration_device_heads WHERE tenant_id=? AND"
                  + " registration_id=? FOR UPDATE",
              String.class,
              tenant,
              device.registrationId());
      if (!existing.isEmpty()) {
        if (existing.size() != 1 || !device.id().equals(existing.get(0))) throw unavailable();
        heads.add(device.registrationId());
      }
    }
    long bytes = 0;
    var selected = new LinkedHashMap<Device, List<Metadata>>();
    for (var device : sorted.values()) {
      if (!heads.contains(device.registrationId())) {
        selected.put(device, List.of());
        continue;
      }
      // A locking current read prevents an earlier REPEATABLE READ snapshot from estimating
      // an old smaller payload and then reading a newer larger document.
      var rows =
          jdbc.query(
              "SELECT d.id,d.device_id,d.registration_id,COALESCE(OCTET_LENGTH(d.document_json),0)"
                  + " AS source_bytes FROM configuration_streams s JOIN configuration_deliveries d"
                  + " ON d.tenant_id=s.tenant_id AND d.id=s.delivery_id WHERE s.tenant_id=? AND"
                  + " s.registration_id=? ORDER BY s.policy_id LIMIT 101 FOR UPDATE",
              (row, index) ->
                  new Metadata(
                      row.getString(1), row.getString(2), row.getString(3), row.getLong(4)),
              tenant,
              device.registrationId());
      if (rows.size() > 100) throw tooLarge();
      for (var row : rows) {
        if (!device.id().equals(row.device())
            || !device.registrationId().equals(row.registration())) throw unavailable();
        bytes += row.bytes();
        if (bytes > 2 * 1024 * 1024) throw tooLarge();
      }
      selected.put(device, rows);
    }
    long checkedAt = clock.millis();
    int ruleCount = 0;
    var result = new HashMap<String, State>();
    for (var entry : selected.entrySet()) {
      var configurations = new ArrayList<Configuration>();
      for (var metadata : entry.getValue()) {
        var item =
            jdbc.queryForObject(
                "SELECT"
                    + " id,policy_id,version_id,source_sequence,action,state,issued_at,delivery_expires_at,first_served_at,received_reported_at,stored_reported_at,rejection_code,document_json"
                    + " FROM configuration_deliveries WHERE tenant_id=? AND id=? FOR UPDATE",
                (row, index) -> configuration(row, checkedAt),
                tenant,
                metadata.id());
        if (item == null) throw unavailable();
        ruleCount += item.rules().size();
        if (ruleCount > 2000) throw tooLarge();
        configurations.add(item);
      }
      result.put(
          entry.getKey().id(), new State(checkedAt, "DELIVERY_ONLY_NOT_EXECUTION", configurations));
    }
    return Map.copyOf(result);
  }

  private Configuration configuration(ResultSet row, long now) throws SQLException {
    String action = row.getString("action"),
        state = row.getString("state"),
        source = row.getString("document_json");
    if (!Set.of(
            "PENDING_SIGNATURE",
            "READY",
            "SERVED",
            "DEVICE_REPORTED_RECEIVED",
            "DEVICE_REPORTED_STORED",
            "DEVICE_REPORTED_REJECTED")
        .contains(state)) throw unavailable();
    long expires = row.getLong("delivery_expires_at");
    Long stored = number(row, "stored_reported_at");
    if (expires <= now && stored == null && !"DEVICE_REPORTED_REJECTED".equals(state))
      state = "EXPIRED_AWAITING_PULL";
    String name = null;
    var rules = new ArrayList<Rule>();
    if ("UPSERT_CONFIGURATION".equals(action)) {
      if (source == null) throw unavailable();
      final ConfigurationDocument document;
      try {
        document = json.readValue(source, ConfigurationDocument.class);
      } catch (JsonProcessingException failure) {
        throw unavailable();
      }
      if (document == null
          || !text(document.name(), 100)
          || document.rules() == null
          || document.applications() == null
          || document.schedules() == null) throw unavailable();
      if (document.rules().size() > 100
          || document.applications().size() > 100
          || document.schedules().size() > 100) throw tooLarge();
      name = document.name();
      var applications = new HashMap<String, ApplicationDefinition>();
      for (var app : document.applications()) {
        if (app == null
            || app.id() == null
            || !text(app.displayName(), 100)
            || app.platform() == null
            || app.profile() == null
            || !text(app.packageName(), 255)
            || applications.put(app.id(), app) != null) throw unavailable();
      }
      var schedules = new HashMap<String, ScheduleEntry>();
      for (var schedule : document.schedules()) {
        if (schedule == null
            || schedule.id() == null
            || !text(schedule.name(), 100)
            || schedules.put(schedule.id(), schedule) != null) throw unavailable();
      }
      for (var rule : document.rules()) {
        if (rule == null
            || rule.kind() == null
            || rule.predictedEffect() == null
            || !text(rule.status(), 50)
            || !text(rule.reasonCode(), 100)
            || rule.effectiveEffect() != null) throw unavailable();
        var app = applications.get(rule.applicationId());
        var schedule = schedules.get(rule.scheduleId());
        if ((rule.applicationId() != null && app == null)
            || (rule.scheduleId() != null && schedule == null)) throw unavailable();
        rules.add(
            new Rule(
                rule.kind().name(),
                rule.predictedEffect().name(),
                rule.status(),
                rule.reasonCode(),
                app == null ? null : app.displayName(),
                app == null ? null : app.platform().name(),
                app == null ? null : app.profile().name(),
                app == null ? null : app.packageName(),
                schedule == null ? null : schedule.name(),
                rule.permission(),
                rule.domain(),
                rule.seconds(),
                rule.required()));
      }
    } else if (!"REMOVE_CONFIGURATION".equals(action) || source != null) throw unavailable();
    return new Configuration(
        row.getString("id"),
        row.getString("policy_id"),
        row.getString("version_id"),
        row.getLong("source_sequence"),
        action,
        state,
        row.getLong("issued_at"),
        expires,
        number(row, "first_served_at"),
        number(row, "received_reported_at"),
        stored,
        row.getString("rejection_code"),
        name,
        rules);
  }

  private boolean text(String value, int max) {
    return value != null && !value.isBlank() && value.length() <= max;
  }

  private Long number(ResultSet row, String field) throws SQLException {
    var value = (Number) row.getObject(field);
    return value == null ? null : value.longValue();
  }

  private DomainException tooLarge() {
    return new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "USAGE_REPORT_TOO_LARGE");
  }

  private DomainException unavailable() {
    return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "USAGE_REPORT_DATA_UNAVAILABLE");
  }

  private record Metadata(String id, String device, String registration, long bytes) {}
}

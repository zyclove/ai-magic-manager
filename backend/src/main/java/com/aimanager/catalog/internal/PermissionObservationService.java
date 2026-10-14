package com.aimanager.catalog.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.observation.ObservationAuthorization;
import com.aimanager.observation.ObservationAuthorizationChanged;
import com.aimanager.observation.PermissionObservationAuthorization;
import com.aimanager.observation.PermissionObservationAuthorizationChanged;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import org.springframework.context.event.EventListener;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** One-app-at-a-time, consented facts from a visible Android package. No enforcement claim. */
@Service
class PermissionObservationService {
  private static final long MAX_AGE_MILLIS = 15 * 60_000L;
  private static final long RETENTION_MILLIS = 24 * 60 * 60_000L;
  private final JdbcTemplate jdbc;
  private final DeviceAccess devices;
  private final DeviceCredentials credentials;
  private final TenantAccess access;
  private final PermissionObservationAuthorization permissionAuthorization;
  private final ObservationAuthorization inventoryAuthorization;
  private final InventoryService inventories;
  private final ObjectMapper mapper;
  private final Clock clock;
  private final AuditService audit;

  PermissionObservationService(JdbcTemplate jdbc, DeviceAccess devices,
      DeviceCredentials credentials, TenantAccess access,
      PermissionObservationAuthorization permissionAuthorization,
      ObservationAuthorization inventoryAuthorization, InventoryService inventories,
      ObjectMapper mapper, Clock clock, AuditService audit) {
    this.jdbc = jdbc;
    this.devices = devices;
    this.credentials = credentials;
    this.access = access;
    this.permissionAuthorization = permissionAuthorization;
    this.inventoryAuthorization = inventoryAuthorization;
    this.inventories = inventories;
    this.mapper = mapper;
    this.clock = clock;
    this.audit = audit;
  }

  @Transactional(timeout = 10)
  Accepted report(DeviceContext identity, PermissionObservationController.Report input) {
    devices.lockActive(identity);
    credentials.requireActive(identity);
    permissionAuthorization.requirePermissionObservation(identity, input.authorizationVersion());
    long now = clock.millis();
    try { UUID.fromString(input.reportId()); }
    catch (IllegalArgumentException invalid) { throw DomainException.invalid("INVALID_PERMISSION_REPORT_ID"); }
    var names = new HashSet<String>();
    var ordered = new ArrayList<PermissionObservationController.PermissionFact>();
    for (var fact : input.permissions()) {
      if (!names.add(fact.permissionName()))
        throw DomainException.invalid("DUPLICATE_OBSERVED_PERMISSION");
      if (fact.classification() != PermissionObservationController.Classification.DANGEROUS
          && fact.observedGrant() != PermissionObservationController.ObservedGrant.UNKNOWN)
        throw DomainException.invalid("PERMISSION_GRANT_CLASSIFICATION_INVALID");
      ordered.add(fact);
    }
    ordered.sort(Comparator.comparing(PermissionObservationController.PermissionFact::permissionName));
    if (input.signingDigests().stream().distinct().count() != input.signingDigests().size())
      throw DomainException.invalid("DUPLICATE_SIGNING_DIGEST");
    var normalized = new PermissionObservationController.Report(input.reportId(), input.sequence(),
        input.authorizationVersion(), input.packageName(), input.profile(),
        input.signingDigests().stream().sorted().toList(), input.versionCode(),
        input.observedAt(), input.source(), List.copyOf(ordered));
    String encoded = json(normalized);
    if (encoded.getBytes(StandardCharsets.UTF_8).length > 32 * 1024)
      throw DomainException.invalid("PERMISSION_OBSERVATION_TOO_LARGE");
    String hash = SecretMaterial.hash(encoded);
    var previous = jdbc.query(
        "SELECT sequence_number,report_id,request_hash,received_at FROM"
            + " device_permission_observation_snapshots WHERE tenant_id=? AND device_id=?"
            + " AND registration_id=? FOR UPDATE",
        (r, i) -> new Head(r.getLong(1), r.getString(2), r.getString(3), r.getLong(4)),
        identity.tenantId(), identity.deviceId(), identity.registrationId());
    if (!previous.isEmpty()) {
      Head prior = previous.get(0);
      if (input.sequence() == prior.sequence()) {
        if (!hash.equals(prior.hash()))
          throw new DomainException(HttpStatus.CONFLICT, "PERMISSION_OBSERVATION_SEQUENCE_CONFLICT");
        return new Accepted(identity.registrationId(), prior.sequence(), prior.receivedAt());
      }
      if (input.sequence() < prior.sequence() || input.reportId().equals(prior.reportId()))
        throw new DomainException(HttpStatus.CONFLICT, "PERMISSION_OBSERVATION_STALE_SEQUENCE");
    }
    // Replay of an already accepted body must survive expiry of its inventory evidence.
    var visible = inventories.requireCurrentVisible(identity, input.packageName(), input.profile());
    if (visible.versionCode().longValue() != input.versionCode()
        || !visible.signingDigests().equals(input.signingDigests().stream().sorted().toList()))
      throw new DomainException(HttpStatus.CONFLICT, "PERMISSION_APPLICATION_IDENTITY_CHANGED");
    if (input.observedAt() > now + 300_000 || input.observedAt() < now - MAX_AGE_MILLIS)
      throw DomainException.invalid("PERMISSION_OBSERVATION_TIME_INVALID");
    reserveRate(identity, now);
    if (previous.isEmpty()) {
      jdbc.update("INSERT INTO device_permission_observation_snapshots(tenant_id,device_id,"
          + "registration_id,sequence_number,report_id,request_hash,authorization_version,"
          + "package_name,profile,snapshot_json,received_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
          identity.tenantId(), identity.deviceId(), identity.registrationId(), input.sequence(),
          input.reportId(), hash, input.authorizationVersion(), input.packageName(),
          input.profile().name(), encoded, now);
    } else {
      jdbc.update("UPDATE device_permission_observation_snapshots SET sequence_number=?,"
          + "report_id=?,request_hash=?,authorization_version=?,package_name=?,profile=?,"
          + "snapshot_json=?,received_at=? WHERE tenant_id=? AND device_id=? AND registration_id=?",
          input.sequence(), input.reportId(), hash, input.authorizationVersion(),
          input.packageName(), input.profile().name(), encoded, now,
          identity.tenantId(), identity.deviceId(), identity.registrationId());
    }
    audit.record(identity.tenantId(), "device:" + identity.registrationId(),
        "PERMISSION_OBSERVATION_REPORTED", identity.deviceId());
    return new Accepted(identity.registrationId(), input.sequence(), now);
  }

  /** Rate limit new reports; idempotent replay is handled before this counter. */
  private void reserveRate(DeviceContext identity, long now) {
    var rows = jdbc.query("SELECT window_started_at,report_count FROM"
            + " device_permission_observation_rate WHERE tenant_id=? AND device_id=?"
            + " AND registration_id=? FOR UPDATE",
        (r, i) -> new Rate(r.getLong(1), r.getInt(2)),
        identity.tenantId(), identity.deviceId(), identity.registrationId());
    if (rows.isEmpty()) {
      jdbc.update("INSERT INTO device_permission_observation_rate(tenant_id,device_id,"
          + "registration_id,window_started_at,report_count) VALUES(?,?,?,?,1)",
          identity.tenantId(), identity.deviceId(), identity.registrationId(), now);
    } else if (now - rows.get(0).startedAt() >= MAX_AGE_MILLIS) {
      jdbc.update("UPDATE device_permission_observation_rate SET window_started_at=?,"
          + "report_count=1 WHERE tenant_id=? AND device_id=? AND registration_id=?",
          now, identity.tenantId(), identity.deviceId(), identity.registrationId());
    } else {
      if (rows.get(0).count() >= 20)
        throw new DomainException(HttpStatus.TOO_MANY_REQUESTS,
            "PERMISSION_OBSERVATION_RATE_LIMITED");
      jdbc.update("UPDATE device_permission_observation_rate SET report_count=report_count+1"
          + " WHERE tenant_id=? AND device_id=? AND registration_id=?",
          identity.tenantId(), identity.deviceId(), identity.registrationId());
    }
  }

  View read(String tenant, String actor, String deviceId, String packageName) {
    access.requireRole(tenant, actor, TenantAccess.Role.OWNER,
        TenantAccess.Role.GUARDIAN, TenantAccess.Role.ORG_ADMIN);
    if (packageName == null || !packageName.matches(
        "[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+") || packageName.length() > 255)
      throw DomainException.invalid("INVALID_PACKAGE_NAME");
    Device device = devices.requireVisible(tenant, actor, deviceId);
    if (!permissionAuthorization.permissionObservationEnabled(tenant, deviceId,
            device.registrationId())
        || !inventoryAuthorization.inventoryEnabled(tenant, deviceId, device.registrationId()))
      return empty(deviceId, device.registrationId(), packageName, "NOT_AUTHORIZED");
    var rows = jdbc.query("SELECT snapshot_json,received_at FROM"
            + " device_permission_observation_snapshots WHERE tenant_id=? AND device_id=?"
            + " AND registration_id=? AND package_name=?",
        (r, i) -> new Snapshot(parse(r.getString(1)), r.getLong(2)),
        tenant, deviceId, device.registrationId(), packageName);
    if (rows.isEmpty()) return empty(deviceId, device.registrationId(), packageName, "UNKNOWN");
    Snapshot snapshot = rows.get(0);
    long age = clock.millis() - snapshot.receivedAt();
    if (age >= RETENTION_MILLIS)
      return empty(deviceId, device.registrationId(), packageName, "UNKNOWN");
    // A later inventory can describe an updated/reinstalled application. Never
    // attribute an old permission snapshot to that different observed identity.
    var inventory = inventories.read(tenant, actor, deviceId);
    var application = inventory.applications().stream()
        .filter(app -> app.packageName().equals(packageName)
            && app.profile() == snapshot.report().profile()).findFirst();
    if (application.isEmpty()
        || !application.get().versionCode().equals(snapshot.report().versionCode())
        || !new HashSet<>(application.get().signingDigests())
            .equals(new HashSet<>(snapshot.report().signingDigests()))) {
      return empty(deviceId, device.registrationId(), packageName, "UNKNOWN");
    }
    return new View(deviceId, device.registrationId(), packageName,
        snapshot.report().profile(), snapshot.report().versionCode(),
        snapshot.report().observedAt(), snapshot.receivedAt(),
        age < 0 || age > MAX_AGE_MILLIS || !"RECENT".equals(inventory.observationStatus())
            ? "STALE" : "RECENT", "AGENT_REPORTED_UNVERIFIED",
        snapshot.report().permissions());
  }

  private static View empty(String device, String registration, String packageName, String status) {
    return new View(device, registration, packageName, null, null, null, null,
        status, "AGENT_REPORTED_UNVERIFIED", List.of());
  }

  @EventListener
  @Transactional(propagation = Propagation.MANDATORY)
  public void permissionChanged(PermissionObservationAuthorizationChanged event) {
    clear(event.tenantId(), event.deviceId(), event.registrationId());
  }

  @EventListener
  @Transactional(propagation = Propagation.MANDATORY)
  public void inventoryChanged(ObservationAuthorizationChanged event) {
    clear(event.tenantId(), event.deviceId(), event.registrationId());
  }

  private void clear(String tenant, String device, String registration) {
    jdbc.update("DELETE FROM device_permission_observation_snapshots WHERE tenant_id=?"
        + " AND device_id=? AND registration_id=?", tenant, device, registration);
    jdbc.update("DELETE FROM device_permission_observation_rate WHERE tenant_id=?"
        + " AND device_id=? AND registration_id=?", tenant, device, registration);
  }

  /** Bounded per-replica cleanup; the received_at condition protects a newly replaced snapshot. */
  @Scheduled(fixedDelayString = "${manager.observation.permission-retention-seconds:30}",
      initialDelayString = "${manager.observation.permission-retention-seconds:30}",
      timeUnit = TimeUnit.SECONDS)
  @Transactional(timeout = 10)
  void purgeExpired() {
    long cutoff = clock.millis() - RETENTION_MILLIS;
    var keys = jdbc.query("SELECT tenant_id,device_id,received_at FROM"
            + " device_permission_observation_snapshots WHERE received_at<?"
            + " ORDER BY received_at LIMIT 1000",
        (r, i) -> new Expired(r.getString(1), r.getString(2), r.getLong(3)), cutoff);
    for (var key : keys)
      jdbc.update("DELETE FROM device_permission_observation_snapshots WHERE tenant_id=?"
          + " AND device_id=? AND received_at=?", key.tenantId(), key.deviceId(), key.receivedAt());
    var rateKeys = jdbc.query("SELECT tenant_id,device_id,window_started_at FROM"
            + " device_permission_observation_rate WHERE window_started_at<?"
            + " ORDER BY window_started_at LIMIT 1000",
        (r, i) -> new Expired(r.getString(1), r.getString(2), r.getLong(3)), cutoff);
    for (var key : rateKeys)
      jdbc.update("DELETE FROM device_permission_observation_rate WHERE tenant_id=?"
          + " AND device_id=? AND window_started_at=?",
          key.tenantId(), key.deviceId(), key.receivedAt());
  }

  private String json(Object value) {
    try { return mapper.writeValueAsString(value); }
    catch (JsonProcessingException failure) {
      throw new IllegalStateException("Permission observation serialization failed", failure);
    }
  }

  private PermissionObservationController.Report parse(String encoded) {
    try { return mapper.readValue(encoded, PermissionObservationController.Report.class); }
    catch (JsonProcessingException failure) {
      throw new IllegalStateException("Permission observation snapshot unreadable", failure);
    }
  }

  record Accepted(String registrationId, long sequence, long receivedAt) {}
  record View(String deviceId, String registrationId, String packageName,
      ApplicationDefinition.Profile profile, Long versionCode, Long observedAt,
      Long receivedAt, String observationStatus, String evidenceStatus,
      List<PermissionObservationController.PermissionFact> permissions) {}
  private record Head(long sequence, String reportId, String hash, long receivedAt) {}
  private record Rate(long startedAt, int count) {}
  private record Snapshot(PermissionObservationController.Report report, long receivedAt) {}
  private record Expired(String tenantId, String deviceId, long receivedAt) {}
}

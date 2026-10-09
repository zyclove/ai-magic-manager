package com.aimanager.fleet.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.fleet.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.tenant.TenantAccess;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

@Service
class FleetReads
    implements FleetPolicyAccess, DeviceAccess, RegistrationKeys, AccessRequestDeviceScope {
  private static final Set<String> MANAGED =
      Set.of(
          "managed.app_policy",
          "app.install_policy",
          "app.launch_block",
          "permission.runtime",
          "device.lock_task",
          "usage.shared_quota_enforced");
  private static final Set<String> OBSERVABLE = Set.of("usage.report", "network.domain_filter");
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final Clock clock;
  private final long observationAgeMillis;
  private final long capabilityAgeMillis;

  FleetReads(
      JdbcTemplate jdbc,
      TenantAccess access,
      Clock clock,
      @Value("${manager.devices.observation-max-age-seconds:180}") long observationAge,
      @Value("${manager.devices.capability-max-age-seconds:900}") long capabilityAge) {
    if (observationAge < 30
        || observationAge > 86400
        || capabilityAge < 30
        || capabilityAge > 86400) throw new IllegalArgumentException("Invalid evidence lifetime");
    this.jdbc = jdbc;
    this.access = access;
    this.clock = clock;
    this.observationAgeMillis = observationAge * 1000;
    this.capabilityAgeMillis = capabilityAge * 1000;
  }

  Enrollment enrollment(String tenant, String actor, String id) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    var rows =
        jdbc.query(
            "SELECT * FROM device_enrollments WHERE tenant_id=? AND id=?",
            (row, index) ->
                new Enrollment(
                    row.getString("id"),
                    row.getString("subject_id"),
                    Device.Platform.valueOf(row.getString("platform")),
                    Device.Mode.valueOf(row.getString("requested_mode")),
                    derivedState(row.getString("state"), row.getLong("expires_at")),
                    row.getLong("expires_at"),
                    row.getString("device_id"),
                    row.getInt("pairing_failures")),
            tenant,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private String derivedState(String state, long expires) {
    return ("PENDING_CLAIM".equals(state) || "AWAITING_CONFIRMATION".equals(state))
            && expires <= clock.millis()
        ? "EXPIRED"
        : state;
  }

  ItemPage<Device> devices(String tenant, String actor, int limit, String cursor) {
    var grant = access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, TEACHER, CHILD);
    ItemPage.validate(limit, cursor);
    var filter = access.subjectFilter(tenant, actor, grant, "subject_id");
    String sql =
        "SELECT * FROM devices WHERE tenant_id=? AND id>? AND "
            + filter.sql()
            + " ORDER BY id LIMIT ?";
    var parameters = new ArrayList<Object>(List.of(tenant, cursor == null ? "" : cursor));
    parameters.addAll(filter.args());
    parameters.add(limit + 1);
    var rows = jdbc.query(sql, (row, index) -> map(row), parameters.toArray());
    return ItemPage.from(rows, limit, Device::id);
  }

  Device device(String tenant, String actor, String id) {
    var grant = access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, TEACHER, CHILD);
    var result = rawDevice(tenant, id);
    access.requireSubjectRead(tenant, actor, grant, result.subjectId());
    return result;
  }

  Device rawDevice(String tenant, String id) {
    return rawDevice(tenant, id, false);
  }

  private Device rawDevice(String tenant, String id, boolean lock) {
    var rows =
        jdbc.query(
            "SELECT * FROM devices WHERE tenant_id=? AND id=?" + (lock ? " FOR UPDATE" : ""),
            (row, index) -> map(row),
            tenant,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private Device map(ResultSet row) throws SQLException {
    var heartbeat = (Number) row.getObject("last_heartbeat_at");
    Long observed = heartbeat == null ? null : heartbeat.longValue();
    var state = Device.State.valueOf(row.getString("state"));
    return new Device(
        row.getString("id"),
        row.getString("subject_id"),
        row.getString("registration_id"),
        row.getString("display_name"),
        Device.Platform.valueOf(row.getString("platform")),
        row.getString("os_version"),
        state,
        state == Device.State.AWAITING_CONFIRMATION ? "UNVERIFIED" : "BYOD",
        state == Device.State.ACTIVE ? "LIMITED" : "NONE",
        observed,
        state == Device.State.REVOKED
            ? "REVOKED"
            : observed == null
                ? "UNKNOWN"
                : clock.millis() - observed > observationAgeMillis ? "STALE" : "RECENT",
        row.getString("key_thumbprint"),
        row.getLong("version"));
  }

  Capabilities capabilities(String tenant, String actor, String deviceId) {
    var device = device(tenant, actor, deviceId);
    return new Capabilities(deriveCapabilities(tenant, device, false));
  }

  private List<CapabilityView> deriveCapabilities(String tenant, Device device, boolean lock) {
    String deviceId = device.id();
    var reported =
        jdbc.query(
            "SELECT * FROM device_capabilities WHERE tenant_id=? AND device_id=? ORDER BY"
                + " capability_key"
                + (lock ? " FOR UPDATE" : ""),
            (row, index) ->
                new Observation(
                    row.getString("capability_key"),
                    row.getBoolean("reported_supported"),
                    row.getString("grant_status"),
                    row.getLong("checked_at")),
            tenant,
            deviceId);
    var results = new TreeMap<String, CapabilityView>();
    for (String key : MANAGED)
      results.put(
          key,
          new CapabilityView(
              key,
              false,
              "NOT_REQUESTED",
              "REGISTRATION_MODE",
              null,
              "UNSUPPORTED",
              false,
              "MANAGED_REGISTRATION_REQUIRED"));
    for (var item : reported) {
      boolean old = clock.millis() - item.at() > capabilityAgeMillis;
      String status =
          device.state() != Device.State.ACTIVE
              ? "UNKNOWN"
              : MANAGED.contains(item.key())
                  ? "UNSUPPORTED"
                  : old ? "STALE" : OBSERVABLE.contains(item.key()) ? "UNVERIFIED" : "UNKNOWN";
      String reason =
          MANAGED.contains(item.key()) ? "MANAGED_REGISTRATION_REQUIRED" : "EVIDENCE_NOT_CERTIFIED";
      results.put(
          item.key(),
          new CapabilityView(
              item.key(),
              item.supported(),
              item.grant(),
              "AGENT_REPORT",
              item.at(),
              status,
              false,
              reason));
    }
    return List.copyOf(results.values());
  }

  record Capabilities(List<CapabilityView> items) {}

  private record Observation(String key, boolean supported, String grant, long at) {}

  @Override
  public FleetPolicyAccess.Target snapshot(
      String tenant, String actor, String deviceId, boolean lock) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    if (lock) {
      if (!org.springframework.transaction.support.TransactionSynchronizationManager
          .isActualTransactionActive())
        throw new IllegalStateException("Fleet snapshot lock needs transaction");
    }
    // Current locking reads avoid an older REPEATABLE READ snapshot after waiting for
    // heartbeat/revocation.
    var device = rawDevice(tenant, deviceId, lock);
    return new FleetPolicyAccess.Target(device, deriveCapabilities(tenant, device, lock));
  }

  /**
   * Internal consumers may expose inventory or initiate workflows; teacher status reads use
   * device() only.
   */
  @Override
  public Device requireVisible(String tenant, String actor, String deviceId) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, CHILD);
    return device(tenant, actor, deviceId);
  }

  @Override
  public RegistrationKeys.Key key(String tenant, String device, String registration) {
    var keys =
        jdbc.query(
            "SELECT public_key_jwk,key_thumbprint,state FROM devices WHERE tenant_id=? AND id=? AND"
                + " registration_id=?",
            (row, index) ->
                new RegistrationKeys.Key(
                    row.getString("public_key_jwk"),
                    row.getString("key_thumbprint"),
                    Device.State.valueOf(row.getString("state"))),
            tenant,
            device,
            registration);
    if (keys.isEmpty()) throw DomainException.denied();
    return keys.get(0);
  }

  @Override
  public Device lockVisibleActive(String tenant, String actor, String deviceId) {
    var grant = access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, CHILD);
    var device = rawDevice(tenant, deviceId, true);
    if (grant.role() == CHILD && !device.subjectId().equals(grant.subjectId()))
      throw DomainException.denied();
    if (device.state() != Device.State.ACTIVE)
      throw new com.aimanager.shared.DomainException(
          org.springframework.http.HttpStatus.CONFLICT, "DEVICE_NOT_ACTIVE");
    return device;
  }

  @Override
  public Device observeRequestTarget(String tenant, String actor, String deviceId) {
    return requestTarget(tenant, actor, deviceId, false);
  }

  @Override
  public Device lockRequestTarget(String tenant, String actor, String deviceId) {
    return requestTarget(tenant, actor, deviceId, true);
  }

  private Device requestTarget(String tenant, String actor, String deviceId, boolean lock) {
    // Deliberately separate from DeviceAccess: its existing management consumers retain their
    // roles.
    var grant = access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, CHILD, TEACHER);
    var device = rawDevice(tenant, deviceId, lock);
    access.requireSubjectRead(tenant, actor, grant, device.subjectId());
    if (device.state() != Device.State.ACTIVE)
      throw new DomainException(org.springframework.http.HttpStatus.CONFLICT, "DEVICE_NOT_ACTIVE");
    return device;
  }

  @Override
  public boolean registrationActive(
      String tenant, String device, String registration, String subject) {
    return Boolean.TRUE.equals(
        jdbc.queryForObject(
            "SELECT COUNT(*)>0 FROM devices WHERE tenant_id=? AND id=? AND registration_id=? AND"
                + " subject_id=? AND state='ACTIVE'",
            Boolean.class,
            tenant,
            device,
            registration,
            subject));
  }

  @Override
  public Device observeActive(com.aimanager.deviceidentity.DeviceContext identity) {
    var device = rawDevice(identity.tenantId(), identity.deviceId(), false);
    if (device.state() != Device.State.ACTIVE
        || !device.registrationId().equals(identity.registrationId()))
      throw DomainException.denied();
    return device;
  }

  @Override
  public Device lockActive(com.aimanager.deviceidentity.DeviceContext identity) {
    if (!org.springframework.transaction.support.TransactionSynchronizationManager
        .isActualTransactionActive())
      throw new IllegalStateException("Device lifecycle lock needs transaction");
    var device = rawDevice(identity.tenantId(), identity.deviceId(), true);
    if (device.state() != Device.State.ACTIVE
        || !device.registrationId().equals(identity.registrationId()))
      throw DomainException.denied();
    return device;
  }
}

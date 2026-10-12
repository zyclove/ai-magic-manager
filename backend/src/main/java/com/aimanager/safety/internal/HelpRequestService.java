package com.aimanager.safety.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Records a child's request for adult attention without claiming delivery or emergency response. */
@Service
class HelpRequestService {
  private final JdbcTemplate jdbc;
  private final DeviceAccess devices;
  private final SubjectAccess subjects;
  private final DeviceCredentials credentials;
  private final TenantAccess access;
  private final AuditService audit;
  private final Clock clock;

  HelpRequestService(
      JdbcTemplate jdbc,
      DeviceAccess devices,
      SubjectAccess subjects,
      DeviceCredentials credentials,
      TenantAccess access,
      AuditService audit,
      Clock clock) {
    this.jdbc = jdbc;
    this.devices = devices;
    this.subjects = subjects;
    this.credentials = credentials;
    this.access = access;
    this.audit = audit;
    this.clock = clock;
  }

  /** The client UUID is durably chosen before HTTP; retries return the original record. */
  @Transactional(timeout = 10)
  Created create(DeviceContext identity, UUID clientRequestId, Reason reason) {
    var device = activeDevice(identity);
    var existing = own(identity, clientRequestId.toString());
    if (existing != null) {
      if (!existing.subjectId().equals(device.subjectId()))
        throw new DomainException(HttpStatus.NOT_FOUND, "HELP_REQUEST_UNAVAILABLE");
      if (existing.reasonCode() != reason)
        throw new DomainException(HttpStatus.CONFLICT, "HELP_REQUEST_ID_REUSED");
      return new Created(existing, false);
    }
    long now = clock.millis();
    Long recent = jdbc.queryForObject(
        "SELECT COUNT(*) FROM child_help_requests WHERE tenant_id=? AND device_id=?"
            + " AND registration_id=? AND created_at>?",
        Long.class, identity.tenantId(), identity.deviceId(), identity.registrationId(),
        now - 60_000);
    if (recent != null && recent >= 10)
      throw new DomainException(HttpStatus.TOO_MANY_REQUESTS, "HELP_REQUEST_RATE_LIMITED");
    String id = UUID.randomUUID().toString();
    jdbc.update(
        "INSERT INTO child_help_requests(tenant_id,id,subject_id,device_id,registration_id,"
            + "client_request_id,reason_code,state,created_at,version)"
            + " VALUES(?,?,?,?,?, ?,?,'OPEN',?,0)",
        identity.tenantId(), id, device.subjectId(), identity.deviceId(),
        identity.registrationId(), clientRequestId.toString(), reason.name(), now);
    audit.record(identity.tenantId(), "device:" + identity.deviceId(), "CHILD_HELP_REQUESTED", id);
    return new Created(new HelpRequest(id, device.subjectId(), identity.deviceId(),
        clientRequestId.toString(), reason, State.OPEN, now, null, 0), true);
  }

  @Transactional(timeout = 10)
  HelpRequest deviceGet(DeviceContext identity, UUID clientRequestId) {
    var device = activeDevice(identity);
    var value = own(identity, clientRequestId.toString());
    if (value == null || !value.subjectId().equals(device.subjectId()))
      throw new DomainException(HttpStatus.NOT_FOUND, "HELP_REQUEST_UNAVAILABLE");
    return value;
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<HelpRequest> list(String tenant, String actor, int limit, String cursor, State state) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    ItemPage.validate(limit, cursor);
    Long beforeTime = null;
    if (cursor != null) {
      // The anchor remains valid if another adult acknowledges it between pages.
      var times = jdbc.query(
          "SELECT created_at FROM child_help_requests WHERE tenant_id=? AND id=?",
          (row, index) -> row.getLong(1), tenant, cursor);
      if (times.size() != 1) throw DomainException.invalid("INVALID_CURSOR");
      beforeTime = times.get(0);
    }
    var args = new ArrayList<Object>(List.of(tenant));
    String sql = "SELECT * FROM child_help_requests WHERE tenant_id=?";
    if (state != null) {
      sql += " AND state=?";
      args.add(state.name());
    }
    if (cursor != null) {
      sql += " AND (created_at<? OR (created_at=? AND id<?))";
      args.add(beforeTime);
      args.add(beforeTime);
      args.add(cursor);
    }
    sql += " ORDER BY created_at DESC,id DESC LIMIT ?";
    args.add(limit + 1);
    return ItemPage.from(jdbc.query(sql, (row, index) -> map(row), args.toArray()),
        limit, HelpRequest::id);
  }

  @Transactional(readOnly = true, timeout = 10)
  HelpRequest get(String tenant, String actor, UUID id) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    return required(tenant, id.toString(), false);
  }

  @Transactional(readOnly = true, timeout = 10)
  OpenCount openCount(String tenant, String actor) {
    access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    var ids = jdbc.query(
        "SELECT id FROM child_help_requests WHERE tenant_id=? AND state='OPEN'"
            + " ORDER BY created_at DESC,id DESC LIMIT 1001",
        (row, index) -> row.getString(1), tenant);
    return new OpenCount(Math.min(ids.size(), 1000), ids.size() > 1000);
  }

  @Transactional(timeout = 10)
  HelpRequest acknowledge(String tenant, String actor, UUID id, String etag) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    long expected = ResourceVersions.require(etag);
    var current = required(tenant, id.toString(), true);
    ResourceVersions.check(expected, current.version());
    if (current.state() == State.ACKNOWLEDGED) return current;
    long now = clock.millis();
    int changed = jdbc.update(
        "UPDATE child_help_requests SET state='ACKNOWLEDGED',acknowledged_at=?,version=version+1"
            + " WHERE tenant_id=? AND id=? AND version=?",
        now, tenant, id.toString(), expected);
    if (changed != 1)
      throw new DomainException(HttpStatus.CONFLICT, "HELP_REQUEST_VERSION_CHANGED");
    audit.record(tenant, actor, "CHILD_HELP_ACKNOWLEDGED", id.toString());
    return new HelpRequest(current.id(), current.subjectId(), current.deviceId(),
        current.clientRequestId(), current.reasonCode(), State.ACKNOWLEDGED,
        current.createdAt(), now, expected + 1);
  }

  private com.aimanager.fleet.Device activeDevice(DeviceContext identity) {
    var observed = devices.observeActive(identity);
    if (!subjects.lockForDevice(identity.tenantId(), observed.subjectId()))
      throw DomainException.denied();
    var locked = devices.lockActive(identity);
    if (!locked.subjectId().equals(observed.subjectId()))
      throw new DomainException(HttpStatus.CONFLICT, "HELP_DEVICE_CHANGED");
    credentials.requireActive(identity);
    return locked;
  }

  private HelpRequest own(DeviceContext identity, String clientRequestId) {
    var rows = jdbc.query(
        "SELECT * FROM child_help_requests WHERE tenant_id=? AND device_id=?"
            + " AND registration_id=? AND client_request_id=?",
        (row, index) -> map(row), identity.tenantId(), identity.deviceId(),
        identity.registrationId(), clientRequestId);
    return rows.isEmpty() ? null : rows.get(0);
  }

  private HelpRequest required(String tenant, String id, boolean lock) {
    var rows = jdbc.query(
        "SELECT * FROM child_help_requests WHERE tenant_id=? AND id=?"
            + (lock ? " FOR UPDATE" : ""),
        (row, index) -> map(row), tenant, id);
    if (rows.isEmpty()) throw new DomainException(HttpStatus.NOT_FOUND, "HELP_REQUEST_UNAVAILABLE");
    return rows.get(0);
  }

  private HelpRequest map(ResultSet row) throws SQLException {
    Number acknowledged = (Number) row.getObject("acknowledged_at");
    return new HelpRequest(row.getString("id"), row.getString("subject_id"),
        row.getString("device_id"), row.getString("client_request_id"),
        Reason.valueOf(row.getString("reason_code")), State.valueOf(row.getString("state")),
        row.getLong("created_at"), acknowledged == null ? null : acknowledged.longValue(),
        row.getLong("version"));
  }

  enum Reason { NEED_HELP, UNCOMFORTABLE_CONTENT, DEVICE_PROBLEM }
  enum State { OPEN, ACKNOWLEDGED }

  record HelpRequest(String id, String subjectId, String deviceId, String clientRequestId,
      Reason reasonCode, State state, long createdAt, Long acknowledgedAt, long version) {}
  record Created(HelpRequest request, boolean created) {}
  record OpenCount(int count, boolean capped) {}
}

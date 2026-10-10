package com.aimanager.retention.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Informational snapshot only: submission must perform fresh authorization and scope checks. */
@Service
class ErasurePreflightService {
  record Counts(
      long devices,
      long activeRegistrations,
      long activeCredentials,
      long linkedMembers,
      long pendingEnrollments,
      long devicesWithCleanupReport) {}

  record Preflight(
      int schemaVersion,
      String subjectId,
      long subjectVersion,
      boolean subjectArchived,
      long evaluatedAt,
      boolean executionAvailable,
      boolean readyToErase,
      Counts counts,
      SubjectDataCatalog.Coverage catalog,
      List<String> blockers,
      List<String> notices) {}

  private record SubjectState(long version, boolean archived) {}

  private final JdbcTemplate db;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final SubjectDataCatalog catalog;
  private final AuditService audit;
  private final Clock clock;

  ErasurePreflightService(
      JdbcTemplate db,
      TenantAccess access,
      RecentAuthentication recent,
      SubjectDataCatalog catalog,
      AuditService audit,
      Clock clock) {
    this.db = db;
    this.access = access;
    this.recent = recent;
    this.catalog = catalog;
    this.audit = audit;
    this.clock = clock;
  }

  @Transactional(timeout = 10)
  public Preflight inspect(String tenant, String subject, Jwt actor) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, ORG_ADMIN);
    recent.require(actor);
    var rows =
        db.query(
            "SELECT version,archived_at FROM subjects WHERE tenant_id=? AND id=? FOR UPDATE",
            (r, n) -> new SubjectState(r.getLong(1), r.getObject(2) != null),
            tenant,
            subject);
    if (rows.isEmpty()) throw DomainException.denied();
    var state = rows.get(0);
    var coverage = catalog.requireCurrentSchema();
    long now = clock.millis();
    long devices =
        count("SELECT COUNT(*) FROM devices WHERE tenant_id=? AND subject_id=?", tenant, subject);
    long active =
        count(
            "SELECT COUNT(*) FROM devices WHERE tenant_id=? AND subject_id=? AND state<>'REVOKED'",
            tenant,
            subject);
    long credentials =
        count(
            "SELECT COUNT(*) FROM device_credentials c JOIN devices d ON d.tenant_id=c.tenant_id"
                + " AND d.id=c.device_id AND d.registration_id=c.registration_id WHERE"
                + " d.tenant_id=? AND d.subject_id=? AND c.active=true AND c.revoked_at IS NULL AND"
                + " c.expires_at>?",
            tenant,
            subject,
            now);
    long members =
        count(
            "SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND subject_id=? AND revoked_at"
                + " IS NULL",
            tenant,
            subject);
    long enrollments =
        count(
            "SELECT COUNT(*) FROM device_enrollments WHERE tenant_id=? AND subject_id=? AND state"
                + " IN ('PENDING_CLAIM','AWAITING_CONFIRMATION') AND expires_at>?",
            tenant,
            subject,
            now);
    long reported =
        count(
            "SELECT COUNT(*) FROM devices d WHERE d.tenant_id=? AND d.subject_id=? AND EXISTS"
                + " (SELECT 1 FROM deprovision_heads h JOIN deprovision_operations o ON"
                + " o.tenant_id=h.tenant_id AND o.id=h.operation_id WHERE h.tenant_id=d.tenant_id"
                + " AND h.device_id=d.id AND h.registration_id=d.registration_id AND"
                + " o.device_id=h.device_id AND o.registration_id=h.registration_id AND"
                + " o.state='CLEANUP_REPORTED')",
            tenant,
            subject);
    var blockers = new ArrayList<String>();
    blockers.add("ERASURE_EXECUTION_UNAVAILABLE");
    if (active > 0) blockers.add("DEVICE_EXIT_REQUIRED");
    if (credentials > 0) blockers.add("ACTIVE_DEVICE_CREDENTIALS");
    if (enrollments > 0) blockers.add("PENDING_DEVICE_ENROLLMENTS");
    var notices = new ArrayList<String>();
    notices.add("PREFLIGHT_IS_NOT_ERASURE_AUTHORIZATION");
    notices.add("AUDIT_RETENTION_POLICY_REQUIRES_REVIEW");
    notices.add("DOWNLOADED_COPIES_CANNOT_BE_RECALLED");
    if (devices > 0) notices.add("DEVICE_CLEANUP_REPORTS_ARE_UNVERIFIED");
    if (members > 0) notices.add("LINKED_IDENTITY_REVOCATION_REQUIRED");
    audit.record(tenant, actor.getSubject(), "SUBJECT_ERASURE_PREFLIGHT_VIEWED", subject);
    return new Preflight(
        1,
        subject,
        state.version(),
        state.archived(),
        now,
        false,
        false,
        new Counts(devices, active, credentials, members, enrollments, reported),
        coverage,
        List.copyOf(blockers),
        List.copyOf(notices));
  }

  private long count(String sql, Object... args) {
    return db.queryForObject(sql, Long.class, args);
  }
}

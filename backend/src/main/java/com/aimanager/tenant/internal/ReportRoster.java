package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.shared.DomainException;
import com.aimanager.tenant.OrganizationRoster;
import com.aimanager.tenant.TenantAccess;
import java.util.HashSet;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
class ReportRoster implements OrganizationRoster {
  private final JdbcTemplate db;
  private final TenantAccess access;

  ReportRoster(JdbcTemplate db, TenantAccess access) {
    this.db = db;
    this.access = access;
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public Snapshot lockForPrivateReport(
      String tenant, String actor, String classId, long expectedVersion) {
    access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
    if (!"ORGANIZATION"
        .equals(db.queryForObject("SELECT kind FROM tenants WHERE id=?", String.class, tenant)))
      throw DomainException.invalid("ORGANIZATION_REQUIRED");
    var rows =
        db.query(
            "SELECT version,archived_at FROM organization_classes WHERE tenant_id=? AND id=? FOR"
                + " UPDATE",
            (r, n) -> new ClassState(r.getLong(1), r.getObject(2) != null),
            tenant,
            classId);
    if (rows.isEmpty()) throw DomainException.denied();
    if (rows.get(0).archived()) throw new DomainException(HttpStatus.CONFLICT, "CLASS_ARCHIVED");
    if (rows.get(0).version() != expectedVersion)
      throw new DomainException(HttpStatus.CONFLICT, "REPORT_SCOPE_CHANGED");
    // A locking read sees current rows under MySQL REPEATABLE READ, even when
    // the caller waited behind a roster change after establishing its snapshot.
    var ids =
        db.queryForList(
            "SELECT subject_id FROM organization_class_students WHERE tenant_id=? AND class_id=?"
                + " ORDER BY subject_id LIMIT 501 FOR UPDATE",
            String.class,
            tenant,
            classId);
    if (ids.size() > 500)
      throw new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "USAGE_REPORT_TOO_LARGE");
    return new Snapshot(classId, expectedVersion, new HashSet<>(ids));
  }

  private record ClassState(long version, boolean archived) {}
}

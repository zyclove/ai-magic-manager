package com.aimanager.tenant;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import java.util.List;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** The database is authoritative: a valid JWT does not keep a revoked tenant relationship alive. */
@Service
public class TenantAccess {
  private final JdbcTemplate jdbc;

  public TenantAccess(JdbcTemplate jdbc) {
    this.jdbc = jdbc;
  }

  public Grant requireRole(String tenantId, String actorId, Role... allowed) {
    return evaluate(tenantId, actorId, false, allowed);
  }

  /**
   * Call within the domain write transaction; membership revocation serializes with authorized
   * writes.
   */
  public Grant requireWriteRole(String tenantId, String actorId, Role... allowed) {
    if (!TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Write authorization needs transaction");
    return evaluate(tenantId, actorId, true, allowed);
  }

  /** Lock delegated and confirming actors before domain rows, in a stable order across replicas. */
  public void requireWriteRoles(String tenantId, Collection<String> actors, Role... allowed) {
    if (!TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Write authorization needs transaction");
    if (actors.isEmpty() || actors.size() > 16)
      throw new IllegalArgumentException("Invalid actor set");
    actors.stream()
        .distinct()
        .sorted(Comparator.comparing(ActorKeys::key))
        .forEach(actor -> evaluate(tenantId, actor, true, allowed));
  }

  private Grant evaluate(String tenantId, String actorId, boolean lock, Role[] allowed) {
    var grants =
        jdbc.query(
            "SELECT role,subject_id FROM tenant_members WHERE tenant_id=? AND actor_key=? AND"
                + " revoked_at IS NULL"
                + (lock ? " FOR UPDATE" : ""),
            (row, index) ->
                new Grant(Role.valueOf(row.getString("role")), row.getString("subject_id")),
            tenantId,
            ActorKeys.key(actorId));
    if (grants.isEmpty() || Arrays.stream(allowed).noneMatch(role -> role == grants.get(0).role()))
      throw DomainException.denied();
    return grants.get(0);
  }

  public enum Role {
    OWNER,
    GUARDIAN,
    ORG_ADMIN,
    TEACHER,
    CHILD,
    AUDITOR
  }

  /** Code-owned predicate for read-only subject and device listings. */
  public ScopeFilter subjectFilter(String tenant, String actor, Grant grant, String column) {
    if (!column.matches("[a-z_]+(?:\\.[a-z_]+)?"))
      throw new IllegalArgumentException("Invalid scope column");
    if (grant.role() == Role.CHILD) {
      return grant.subjectId() == null
          ? new ScopeFilter("1=0", List.of())
          : new ScopeFilter(column + "=?", List.of(grant.subjectId()));
    }
    if (grant.role() != Role.TEACHER) return new ScopeFilter("1=1", List.of());
    return new ScopeFilter(
        column
            + " IN (SELECT scope_s.id FROM subjects scope_s JOIN tenant_members scope_m ON"
            + " scope_m.tenant_id=scope_s.tenant_id WHERE scope_s.tenant_id=? AND"
            + " scope_s.archived_at IS NULL AND scope_m.actor_key=? AND scope_m.role='TEACHER' AND"
            + " scope_m.revoked_at IS NULL AND (scope_m.subject_id=scope_s.id OR EXISTS (SELECT 1"
            + " FROM organization_class_students scope_r JOIN organization_classes scope_c ON"
            + " scope_c.tenant_id=scope_r.tenant_id AND scope_c.id=scope_r.class_id JOIN"
            + " tenant_member_class_scopes scope_g ON scope_g.tenant_id=scope_r.tenant_id AND"
            + " scope_g.class_id=scope_r.class_id WHERE scope_r.tenant_id=scope_s.tenant_id AND"
            + " scope_r.subject_id=scope_s.id AND scope_c.archived_at IS NULL AND"
            + " scope_g.actor_key=scope_m.actor_key AND scope_g.member_version=scope_m.version)))",
        List.of(tenant, ActorKeys.key(actor)));
  }

  public boolean canReadSubject(String tenant, String actor, Grant grant, String subject) {
    if (grant.role() != Role.TEACHER && grant.role() != Role.CHILD) return true;
    var filter = subjectFilter(tenant, actor, grant, "checked_s.id");
    var args = new java.util.ArrayList<Object>(List.of(tenant, subject));
    args.addAll(filter.args());
    return Boolean.TRUE.equals(
        jdbc.queryForObject(
            "SELECT COUNT(*)>0 FROM subjects checked_s WHERE checked_s.tenant_id=? AND"
                + " checked_s.id=? AND "
                + filter.sql(),
            Boolean.class,
            args.toArray()));
  }

  public void requireSubjectRead(String tenant, String actor, Grant grant, String subject) {
    if (!canReadSubject(tenant, actor, grant, subject)) throw DomainException.denied();
  }

  public record ScopeFilter(String sql, List<Object> args) {
    public ScopeFilter {
      args = List.copyOf(args);
    }
  }

  public record Grant(Role role, String subjectId) {}
}

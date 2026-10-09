package com.aimanager.tenant;

import com.aimanager.shared.DomainException;
import com.aimanager.identity.ActorKeys;
import java.util.Arrays;
import java.util.Collection;
import java.util.Comparator;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** The database is authoritative: a valid JWT does not keep a revoked tenant relationship alive. */
@Service
public class TenantAccess {
    private final JdbcTemplate jdbc;
    public TenantAccess(JdbcTemplate jdbc) { this.jdbc = jdbc; }

    public Grant requireRole(String tenantId, String actorId, Role... allowed) {
        return evaluate(tenantId, actorId, false, allowed);
    }

    /** Call within the domain write transaction; membership revocation serializes with authorized writes. */
    public Grant requireWriteRole(String tenantId, String actorId, Role... allowed) {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) throw new IllegalStateException("Write authorization needs transaction");
        return evaluate(tenantId, actorId, true, allowed);
    }

    /** Lock delegated and confirming actors before domain rows, in a stable order across replicas. */
    public void requireWriteRoles(String tenantId, Collection<String> actors, Role... allowed) {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) throw new IllegalStateException("Write authorization needs transaction");
        if (actors.isEmpty() || actors.size() > 16) throw new IllegalArgumentException("Invalid actor set");
        actors.stream().distinct().sorted(Comparator.comparing(ActorKeys::key))
            .forEach(actor -> evaluate(tenantId, actor, true, allowed));
    }

    private Grant evaluate(String tenantId, String actorId, boolean lock, Role[] allowed) {
        var grants = jdbc.query("SELECT role,subject_id FROM tenant_members WHERE tenant_id=? AND actor_key=? AND revoked_at IS NULL"
                + (lock ? " FOR UPDATE" : ""),
            (row, index) -> new Grant(Role.valueOf(row.getString("role")), row.getString("subject_id")), tenantId, ActorKeys.key(actorId));
        if (grants.isEmpty() || Arrays.stream(allowed).noneMatch(role -> role == grants.get(0).role())) throw DomainException.denied();
        return grants.get(0);
    }

    public enum Role { OWNER, GUARDIAN, ORG_ADMIN, TEACHER, CHILD, AUDITOR }
    public record Grant(Role role, String subjectId) {}
}

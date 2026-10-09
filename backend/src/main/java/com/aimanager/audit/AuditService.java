package com.aimanager.audit;

import com.aimanager.shared.ItemPage;
import java.time.Clock;
import java.util.UUID;
import org.slf4j.MDC;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** Audit writes commit or roll back with the business operation, never as a best-effort side effect. */
@Service
public class AuditService {
    private final JdbcTemplate jdbc;
    private final Clock clock;
    public AuditService(JdbcTemplate jdbc, Clock clock) { this.jdbc = jdbc; this.clock = clock; }

    @Transactional(propagation = Propagation.MANDATORY)
    public void record(String tenantId, String actorId, String action, String resourceId) {
        String correlation = MDC.get("correlationId");
        jdbc.update("INSERT INTO audit_events(tenant_id,id,actor_id,action,resource_id,correlation_id,occurred_at) VALUES(?,?,?,?,?,?,?)",
            tenantId, UUID.randomUUID().toString(), actorId, action, resourceId,
            correlation == null ? UUID.randomUUID().toString() : correlation, clock.millis());
    }

    /** Caller must authorize tenant audit access before calling this bounded read. */
    public ItemPage<Event> list(String tenantId, int limit, String cursor) {
        ItemPage.validate(limit, cursor);
        var rows = jdbc.query("SELECT * FROM audit_events WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",
            (row, index) -> new Event(row.getString("id"), row.getString("actor_id"), row.getString("action"),
                row.getString("resource_id"), row.getString("correlation_id"), row.getLong("occurred_at")),
            tenantId, cursor == null ? "" : cursor, limit + 1);
        return ItemPage.from(rows, limit, Event::id);
    }

    public record Event(String id, String actorId, String action, String resourceId, String correlationId, long occurredAt) {}
}

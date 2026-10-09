package com.aimanager.audit;

import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import java.time.Clock;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.slf4j.MDC;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Audit writes commit or roll back with the business operation, never as a best-effort side effect.
 */
@Service
public class AuditService {
  private final JdbcTemplate jdbc;
  private final Clock clock;

  public AuditService(JdbcTemplate jdbc, Clock clock) {
    this.jdbc = jdbc;
    this.clock = clock;
  }

  @Transactional(propagation = Propagation.MANDATORY)
  public void record(String tenantId, String actorId, String action, String resourceId) {
    String correlation = MDC.get("correlationId");
    jdbc.update(
        "INSERT INTO"
            + " audit_events(tenant_id,id,actor_id,action,resource_id,correlation_id,occurred_at)"
            + " VALUES(?,?,?,?,?,?,?)",
        tenantId,
        UUID.randomUUID().toString(),
        actorId,
        action,
        resourceId,
        correlation == null ? UUID.randomUUID().toString() : correlation,
        clock.millis());
  }

  /** Caller must authorize tenant audit access before calling this bounded read. */
  public ItemPage<Event> list(String tenantId, int limit, String cursor) {
    ItemPage.validate(limit, cursor);
    var rows =
        jdbc.query(
            "SELECT * FROM audit_events WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",
            (row, index) ->
                new Event(
                    row.getString("id"),
                    row.getString("actor_id"),
                    row.getString("action"),
                    row.getString("resource_id"),
                    row.getString("correlation_id"),
                    row.getLong("occurred_at")),
            tenantId,
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(rows, limit, Event::id);
  }

  public record Event(
      String id,
      String actorId,
      String action,
      String resourceId,
      String correlationId,
      long occurredAt) {}

  /** Caller must authorize and keep the creator's membership locked through generation. */
  public List<Event> exportEvents(String tenant, AuditSelection selection, int maximum) {
    if (maximum < 1 || maximum > 10000)
      throw new IllegalArgumentException("Invalid export row bound");
    var predicate = selection.predicate(tenant);
    var parameters = new ArrayList<Object>(predicate.parameters());
    parameters.add(maximum + 1);
    var rows =
        jdbc.query(
            "SELECT * FROM audit_events WHERE "
                + predicate.sql()
                + " ORDER BY occurred_at DESC,id DESC LIMIT ?",
            (r, n) ->
                new Event(
                    r.getString("id"),
                    r.getString("actor_id"),
                    r.getString("action"),
                    r.getString("resource_id"),
                    r.getString("correlation_id"),
                    r.getLong("occurred_at")),
            parameters.toArray());
    if (rows.size() > maximum) throw DomainException.invalid("EXPORT_ROW_LIMIT_EXCEEDED");
    return List.copyOf(rows);
  }
}

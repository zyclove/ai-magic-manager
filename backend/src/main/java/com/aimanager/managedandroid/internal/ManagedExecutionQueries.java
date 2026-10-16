package com.aimanager.managedandroid.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.tenant.TenantAccess;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * Bounded administrative projections; credentials and complete provider documents stay in the
 * journal.
 */
@Service
class ManagedExecutionQueries {
  private static final long MAX_REVISION = 9007199254740990L;
  private static final String COLUMNS =
      "id,publication_id,device_id,registration_id,state,reason_code,revision,created_at,updated_at,cancel_requested";
  private final JdbcTemplate db;
  private final TenantAccess access;

  ManagedExecutionQueries(JdbcTemplate db, TenantAccess access) {
    this.db = db;
    this.access = access;
  }

  record Event(
      long revision,
      ManagedPolicyExecutionJournal.State state,
      ManagedPolicyExecutionJournal.Reason reason,
      long occurredAt) {}

  /**
   * The cursor is a tenant/filter-scoped anchor, never an authorization credential or SQL fragment.
   */
  ItemPage<ManagedPolicyExecutionJournal.View> list(
      String tenant,
      String actor,
      int limit,
      String cursor,
      String deviceId,
      String publicationId,
      ManagedPolicyExecutionJournal.State state) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    ItemPage.validate(limit, cursor);
    var filter = new StringBuilder("tenant_id=?");
    var arguments = new ArrayList<Object>(List.of(tenant));
    if (deviceId != null) {
      canonicalId(deviceId);
      filter.append(" AND device_id=?");
      arguments.add(deviceId);
    }
    if (publicationId != null) {
      canonicalId(publicationId);
      filter.append(" AND publication_id=?");
      arguments.add(publicationId);
    }
    if (state != null) {
      filter.append(" AND state=?");
      arguments.add(state.name());
    }
    if (cursor != null) {
      var anchorArguments = new ArrayList<>(arguments);
      anchorArguments.add(cursor);
      var anchors =
          db.query(
              "SELECT created_at FROM managed_policy_execution_tasks WHERE " + filter + " AND id=?",
              (row, index) -> row.getLong("created_at"),
              anchorArguments.toArray());
      if (anchors.size() != 1) throw DomainException.invalid("INVALID_CURSOR");
      filter.append(" AND (created_at<? OR (created_at=? AND id<?))");
      arguments.add(anchors.get(0));
      arguments.add(anchors.get(0));
      arguments.add(cursor);
    }
    arguments.add(limit + 1);
    var rows =
        db.query(
            "SELECT "
                + COLUMNS
                + " FROM managed_policy_execution_tasks WHERE "
                + filter
                + " ORDER BY created_at DESC,id DESC LIMIT ?",
            this::view,
            arguments.toArray());
    return ItemPage.from(rows, limit, ManagedPolicyExecutionJournal.View::id);
  }

  /**
   * Existing task authorization precedes event access, including empty timelines and later pages.
   */
  ItemPage<Event> events(String tenant, String actor, String id, int limit, String cursor) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    canonicalId(id);
    ItemPage.validate(limit, null);
    long after = revision(cursor);
    if (db.queryForList(
            "SELECT id FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            id)
        .isEmpty()) throw DomainException.denied();
    var rows =
        db.query(
            "SELECT revision,state,reason_code,occurred_at FROM managed_policy_execution_events"
                + " WHERE tenant_id=? AND task_id=? AND revision>? ORDER BY revision LIMIT ?",
            (row, index) ->
                new Event(
                    row.getLong("revision"),
                    ManagedPolicyExecutionJournal.State.valueOf(row.getString("state")),
                    ManagedPolicyExecutionJournal.Reason.valueOf(row.getString("reason_code")),
                    row.getLong("occurred_at")),
            tenant,
            id,
            after,
            limit + 1);
    return ItemPage.from(rows, limit, event -> Long.toString(event.revision()));
  }

  private ManagedPolicyExecutionJournal.View view(ResultSet row, int index) throws SQLException {
    return new ManagedPolicyExecutionJournal.View(
        row.getString("id"),
        row.getString("publication_id"),
        row.getString("device_id"),
        row.getString("registration_id"),
        ManagedPolicyExecutionJournal.State.valueOf(row.getString("state")),
        ManagedPolicyExecutionJournal.Reason.valueOf(row.getString("reason_code")),
        row.getLong("revision"),
        row.getLong("created_at"),
        row.getLong("updated_at"),
        row.getBoolean("cancel_requested"));
  }

  private static void canonicalId(String value) {
    try {
      if (!UUID.fromString(value).toString().equals(value)) throw new IllegalArgumentException();
    } catch (IllegalArgumentException invalid) {
      throw DomainException.invalid("INVALID_EXECUTION_ID");
    }
  }

  private static long revision(String cursor) {
    if (cursor == null) return 0;
    if (!cursor.matches("[1-9][0-9]{0,15}")) throw DomainException.invalid("INVALID_CURSOR");
    long value = Long.parseLong(cursor);
    if (value > MAX_REVISION) throw DomainException.invalid("INVALID_CURSOR");
    return value;
  }
}

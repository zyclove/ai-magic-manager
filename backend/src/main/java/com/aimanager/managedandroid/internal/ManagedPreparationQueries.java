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

/** Administrative read projections. Membership is checked on every page and summary request. */
@Service
class ManagedPreparationQueries {
  private static final String COLUMNS =
      "id,publication_id,policy_version_id,device_id,registration_id,state,reason_code,revision,execution_task_id,expires_at,created_at,updated_at";
  private final JdbcTemplate db;
  private final TenantAccess access;

  ManagedPreparationQueries(JdbcTemplate db, TenantAccess access) {
    this.db = db;
    this.access = access;
  }

  /**
   * Admission is a handoff to the execution journal; only independent device evidence proves
   * application.
   */
  record Summary(long total, long pending, long admitted, long rejected, long cancelled) {}

  /**
   * Immutable ID order keeps anchors usable through lease/state changes. A cursor must still belong
   * to this publication and tenant; it conveys no authorization. Each page is a fresh read, so
   * callers must use summary rather than adding page counts to infer a publication-wide state.
   */
  ItemPage<ManagedPreparationRequestJournal.View> list(
      String tenant, String actor, String publicationId, int limit, String cursor) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    canonicalPublication(publicationId);
    ItemPage.validate(limit, cursor);
    if (limit > 50) throw DomainException.invalid("INVALID_PAGE_SIZE");
    if (db.queryForList(
            "SELECT id FROM policy_publications WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            publicationId)
        .isEmpty()) throw DomainException.denied();
    var arguments = new ArrayList<Object>(List.of(tenant, publicationId));
    String after = "";
    if (cursor != null) {
      if (db.queryForList(
              "SELECT id FROM managed_policy_preparation_requests WHERE tenant_id=? AND"
                  + " publication_id=? AND id=?",
              String.class,
              tenant,
              publicationId,
              cursor)
          .isEmpty()) throw DomainException.invalid("INVALID_CURSOR");
      after = " AND id>?";
      arguments.add(cursor);
    }
    arguments.add(limit + 1);
    var rows =
        db.query(
            "SELECT "
                + COLUMNS
                + " FROM managed_policy_preparation_requests WHERE tenant_id=? AND publication_id=?"
                + after
                + " ORDER BY id LIMIT ?",
            this::view,
            arguments.toArray());
    return ItemPage.from(rows, limit, ManagedPreparationRequestJournal.View::id);
  }

  /**
   * One SQL statement produces all counters from the same database read snapshot. The left join
   * distinguishes an existing empty publication from an inaccessible publication. It does not make
   * a separately fetched detail page part of that snapshot.
   */
  Summary summary(String tenant, String actor, String publicationId) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    canonicalPublication(publicationId);
    var rows =
        db.query(
            "SELECT COUNT(r.id) AS total,"
                + " SUM(CASE WHEN r.state='PENDING' THEN 1 ELSE 0 END) AS pending,"
                + " SUM(CASE WHEN r.state='ADMITTED' THEN 1 ELSE 0 END) AS admitted,"
                + " SUM(CASE WHEN r.state='REJECTED' THEN 1 ELSE 0 END) AS rejected,"
                + " SUM(CASE WHEN r.state='CANCELLED' THEN 1 ELSE 0 END) AS cancelled"
                + " FROM policy_publications p LEFT JOIN managed_policy_preparation_requests r"
                + " ON r.tenant_id=p.tenant_id AND r.publication_id=p.id"
                + " WHERE p.tenant_id=? AND p.id=? GROUP BY p.tenant_id,p.id",
            (row, index) ->
                new Summary(
                    row.getLong("total"),
                    row.getLong("pending"),
                    row.getLong("admitted"),
                    row.getLong("rejected"),
                    row.getLong("cancelled")),
            tenant,
            publicationId);
    if (rows.size() != 1) throw DomainException.denied();
    return rows.get(0);
  }

  private ManagedPreparationRequestJournal.View view(ResultSet row, int index) throws SQLException {
    return new ManagedPreparationRequestJournal.View(
        row.getString("id"),
        row.getString("publication_id"),
        row.getString("policy_version_id"),
        row.getString("device_id"),
        row.getString("registration_id"),
        ManagedPreparationRequestJournal.State.valueOf(row.getString("state")),
        row.getString("reason_code"),
        row.getLong("revision"),
        row.getString("execution_task_id"),
        row.getLong("expires_at"),
        row.getLong("created_at"),
        row.getLong("updated_at"));
  }

  private static void canonicalPublication(String value) {
    try {
      if (value == null || !UUID.fromString(value).toString().equals(value))
        throw new IllegalArgumentException();
    } catch (IllegalArgumentException invalid) {
      throw DomainException.invalid("INVALID_PUBLICATION_ID");
    }
  }
}

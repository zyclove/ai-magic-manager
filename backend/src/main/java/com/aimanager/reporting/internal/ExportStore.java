package com.aimanager.reporting.internal;

import com.aimanager.audit.AuditSelection;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** SQL boundaries and one lock order: creator membership, export head, job. */
@Component
class ExportStore {
  static final String COLUMNS =
      "tenant_id,id,creator_key,member_version,state,range_from,range_to,requested_to,action_filter,resource_filter,correlation_filter,created_at,updated_at,expires_at,next_attempt_at,attempts,claim_token,lease_until,record_count,byte_count,failure_code";
  static final Set<String> ACTIVE = Set.of("QUEUED", "RUNNING", "READY");
  final JdbcTemplate db;

  ExportStore(JdbcTemplate db) {
    this.db = db;
  }

  record Member(long version, boolean allowed) {}

  Member member(String tenant, String key, boolean lock) {
    var rows =
        db.query(
            "SELECT version,role,revoked_at FROM tenant_members WHERE tenant_id=? AND actor_key=?"
                + (lock ? " FOR UPDATE" : ""),
            (r, n) ->
                new Member(
                    r.getLong("version"),
                    r.getObject("revoked_at") == null
                        && Set.of("OWNER", "GUARDIAN", "ORG_ADMIN", "AUDITOR")
                            .contains(r.getString("role"))),
            tenant,
            key);
    return rows.isEmpty() ? new Member(-1, false) : rows.get(0);
  }

  Member authorize(String tenant, String actor, boolean lock) {
    var member = member(tenant, ActorKeys.key(actor), lock);
    if (!member.allowed()) throw DomainException.denied();
    return member;
  }

  void head(String tenant) {
    // Duplicate INSERT takes a shared InnoDB lock and can deadlock on promotion.
    // Upsert acquires the exclusive record lock directly, including initialization.
    db.update(
        "INSERT INTO audit_export_heads(tenant_id) VALUES(?)"
            + " ON DUPLICATE KEY UPDATE tenant_id=tenant_id",
        tenant);
    db.queryForList(
        "SELECT tenant_id FROM audit_export_heads WHERE tenant_id=? FOR UPDATE", tenant);
  }

  Row find(String tenant, String id, boolean lock) {
    AuditSelection.uuid(id);
    return db
        .query(
            "SELECT "
                + COLUMNS
                + " FROM audit_exports WHERE tenant_id=? AND id=?"
                + (lock ? " FOR UPDATE" : ""),
            ExportStore::row,
            tenant,
            id)
        .stream()
        .findFirst()
        .orElse(null);
  }

  Row owned(String tenant, String id, String actor, boolean lock) {
    var row = find(tenant, id, lock);
    if (row == null || !row.creator().equals(ActorKeys.key(actor)))
      throw new DomainException(HttpStatus.NOT_FOUND, "EXPORT_UNAVAILABLE");
    return row;
  }

  static Row row(ResultSet r, int n) throws SQLException {
    return new Row(
        r.getString("tenant_id"),
        r.getString("id"),
        r.getString("creator_key"),
        r.getLong("member_version"),
        r.getString("state"),
        new AuditSelection(
            r.getLong("range_from"),
            r.getLong("range_to"),
            r.getString("action_filter"),
            r.getString("resource_filter"),
            r.getString("correlation_filter")),
        r.getLong("requested_to"),
        r.getLong("created_at"),
        r.getLong("updated_at"),
        r.getLong("expires_at"),
        r.getLong("next_attempt_at"),
        r.getInt("attempts"),
        r.getString("claim_token"),
        r.getObject("lease_until") == null ? null : r.getLong("lease_until"),
        r.getObject("record_count") == null ? null : r.getInt("record_count"),
        r.getObject("byte_count") == null ? null : r.getLong("byte_count"),
        r.getString("failure_code"));
  }

  void terminate(Row row, String state, String code, long now) {
    db.update(
        "UPDATE audit_exports SET"
            + " state=?,failure_code=?,updated_at=?,artifact=NULL,claim_token=NULL,lease_until=NULL"
            + " WHERE tenant_id=? AND id=?",
        state,
        code,
        now,
        row.tenant(),
        row.id());
  }

  String effective(Row row, Member member, long now) {
    if (!ACTIVE.contains(row.state())) return row.state();
    if (now >= row.expiresAt()) return "EXPIRED";
    return !member.allowed() || member.version() != row.memberVersion() ? "REVOKED" : row.state();
  }

  Job view(Row r, Member member, long now) {
    return new Job(
        r.id(),
        effective(r, member, now),
        r.createdAt(),
        r.updatedAt(),
        r.expiresAt(),
        r.selection().from(),
        r.selection().to(),
        r.requestedTo(),
        r.selection().action(),
        r.selection().resourceId(),
        r.selection().correlationId(),
        r.recordCount(),
        r.byteCount(),
        r.failureCode(),
        r.attempts());
  }

  record Row(
      String tenant,
      String id,
      String creator,
      long memberVersion,
      String state,
      AuditSelection selection,
      long requestedTo,
      long createdAt,
      long updatedAt,
      long expiresAt,
      long nextAttemptAt,
      int attempts,
      String claim,
      Long leaseUntil,
      Integer recordCount,
      Long byteCount,
      String failureCode) {
    String binding() {
      return binding(recordCount, byteCount);
    }

    String binding(Integer count, Long bytes) {
      return SecretMaterial.hash(
          tenant
              + "|"
              + id
              + "|"
              + creator
              + "|"
              + memberVersion
              + "|"
              + selection.fingerprintMaterial()
              + "|"
              + createdAt
              + "|"
              + expiresAt
              + "|"
              + requestedTo
              + "|"
              + count
              + "|"
              + bytes);
    }
  }

  record Job(
      String id,
      String state,
      long createdAt,
      long updatedAt,
      long expiresAt,
      long from,
      long to,
      long requestedTo,
      String action,
      String resourceId,
      String correlationId,
      Integer recordCount,
      Long byteCount,
      String failureCode,
      int attempts) {}
}

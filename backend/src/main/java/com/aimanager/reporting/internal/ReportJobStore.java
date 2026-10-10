package com.aimanager.reporting.internal;

import com.aimanager.audit.AuditSelection;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.*;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.*;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Lock order: creator membership, report head, job, report scope and source. */
@Component
class ReportJobStore {
  static final Set<String> ACTIVE = Set.of("QUEUED", "RUNNING", "READY");
  final JdbcTemplate db;
  final ObjectMapper json;

  ReportJobStore(JdbcTemplate db, ObjectMapper json) {
    this.db = db;
    this.json = json;
  }

  record Member(String actor, long version, boolean allowed) {}

  Member member(String tenant, String key, boolean lock) {
    var rows =
        db.query(
            "SELECT actor_id,version,role,revoked_at FROM tenant_members WHERE tenant_id=? AND"
                + " actor_key=?"
                + (lock ? " FOR UPDATE" : ""),
            (r, n) ->
                new Member(
                    r.getString(1),
                    r.getLong(2),
                    r.getObject(4) == null
                        && Set.of("OWNER", "GUARDIAN", "ORG_ADMIN").contains(r.getString(3))),
            tenant,
            key);
    if (rows.isEmpty()) return new Member(null, -1, false);
    var member = rows.get(0);
    if (!ActorKeys.key(member.actor()).equals(key))
      throw new IllegalStateException("Invalid report creator binding");
    return member;
  }

  Member authorize(String tenant, String actor, boolean lock) {
    var member = member(tenant, ActorKeys.key(actor), lock);
    if (!member.allowed()) throw DomainException.denied();
    return member;
  }

  void head(String tenant) {
    db.update(
        "INSERT INTO usage_report_job_heads(tenant_id) VALUES(?) ON DUPLICATE KEY UPDATE"
            + " tenant_id=tenant_id",
        tenant);
    db.queryForList(
        "SELECT tenant_id FROM usage_report_job_heads WHERE tenant_id=? FOR UPDATE", tenant);
  }

  record Row(
      String tenant,
      String id,
      String creator,
      long memberVersion,
      String state,
      ReportJobSelection selection,
      String selectionHash,
      int total,
      int completed,
      long bytes,
      long created,
      long updated,
      long expires,
      long nextAttempt,
      int attempts,
      String claim,
      Long lease,
      String failure) {
    String binding() {
      return SecretMaterial.hash(
          tenant
              + "|"
              + id
              + "|"
              + creator
              + "|"
              + memberVersion
              + "|"
              + selectionHash
              + "|"
              + created
              + "|"
              + expires);
    }
  }

  Row row(ResultSet r, int ignored) throws SQLException {
    final ReportJobSelection selection;
    try {
      if (!SecretMaterial.hash(r.getString("selection_json")).equals(r.getString("selection_hash")))
        throw new IllegalArgumentException();
      selection = json.readValue(r.getString("selection_json"), ReportJobSelection.class);
    } catch (Exception invalid) {
      throw new IllegalStateException("Invalid report selection");
    }
    return new Row(
        r.getString("tenant_id"),
        r.getString("id"),
        r.getString("creator_key"),
        r.getLong("member_version"),
        r.getString("state"),
        selection,
        r.getString("selection_hash"),
        r.getInt("total_devices"),
        r.getInt("completed_devices"),
        r.getLong("byte_count"),
        r.getLong("created_at"),
        r.getLong("updated_at"),
        r.getLong("expires_at"),
        r.getLong("next_attempt_at"),
        r.getInt("attempts"),
        r.getString("claim_token"),
        (Long) r.getObject("lease_until"),
        r.getString("failure_code"));
  }

  Row find(String tenant, String id, boolean lock) {
    AuditSelection.uuid(id);
    return db
        .query(
            "SELECT * FROM usage_report_jobs WHERE tenant_id=? AND id=?"
                + (lock ? " FOR UPDATE" : ""),
            this::row,
            tenant,
            id)
        .stream()
        .findFirst()
        .orElse(null);
  }

  Row owned(String tenant, String id, String actor, boolean lock) {
    var row = find(tenant, id, lock);
    if (row == null || !row.creator().equals(ActorKeys.key(actor)))
      throw new DomainException(HttpStatus.NOT_FOUND, "REPORT_JOB_UNAVAILABLE");
    return row;
  }

  String effective(Row row, Member member, long now) {
    if (!ACTIVE.contains(row.state())) return row.state();
    if (now >= row.expires()) return "EXPIRED";
    return !member.allowed() || member.version() != row.memberVersion() ? "REVOKED" : row.state();
  }

  void terminate(Row row, String state, String failure, long now) {
    db.update(
        "UPDATE usage_report_jobs SET"
            + " state=?,failure_code=?,updated_at=?,claim_token=NULL,lease_until=NULL WHERE"
            + " tenant_id=? AND id=?",
        state,
        failure,
        now,
        row.tenant(),
        row.id());
    db.update(
        "UPDATE usage_report_parts SET artifact=NULL WHERE tenant_id=? AND job_id=?",
        row.tenant(),
        row.id());
  }

  record Part(
      int ordinal,
      String deviceId,
      String registrationId,
      String subjectId,
      long authorizationVersion,
      boolean usageEnabled,
      Long byteCount,
      Long generatedAt) {}

  List<Part> parts(Row row) {
    return db.query(
        "SELECT"
            + " ordinal,device_id,registration_id,subject_id,authorization_version,usage_enabled,byte_count,generated_at"
            + " FROM usage_report_parts WHERE tenant_id=? AND job_id=? ORDER BY ordinal",
        (r, n) ->
            new Part(
                r.getInt(1),
                r.getString(2),
                r.getString(3),
                r.getString(4),
                r.getLong(5),
                r.getBoolean(6),
                (Long) r.getObject(7),
                (Long) r.getObject(8)),
        row.tenant(),
        row.id());
  }

  record Job(
      String id,
      String state,
      long createdAt,
      long updatedAt,
      long expiresAt,
      int totalDevices,
      int completedDevices,
      long byteCount,
      String failureCode,
      ReportJobSelection selection,
      List<Part> parts) {}

  Job view(Row row, Member member, long now) {
    return new Job(
        row.id(),
        effective(row, member, now),
        row.created(),
        row.updated(),
        row.expires(),
        row.total(),
        row.completed(),
        row.bytes(),
        row.failure(),
        row.selection(),
        parts(row));
  }
}

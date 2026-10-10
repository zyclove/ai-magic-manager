package com.aimanager.support.internal;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.*;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

@Component
class DiagnosticPackageStore {
  static final Set<String> ACTIVE = Set.of("QUEUED", "RUNNING", "READY");
  static final String COLUMNS =
      "id,tenant_id,requester_actor_id,authority_actor_id,authority_version,access_mode,grant_id,grant_version,device_id,subject_id,registration_id,type_mask,state,version,created_at,updated_at,expires_at,attempts,next_attempt_at,claim_token,lease_until,generated_at,byte_count,artifact_sha256,failure_code";
  final JdbcTemplate db;

  DiagnosticPackageStore(JdbcTemplate db) {
    this.db = db;
  }

  record Scope(
      String tenant,
      String requester,
      String authority,
      long authorityVersion,
      String mode,
      String grantId,
      Long grantVersion,
      String device,
      String subject,
      String registration,
      int types) {}

  record Row(
      String id,
      Scope scope,
      String state,
      long version,
      long created,
      long updated,
      long expires,
      int attempts,
      long nextAttempt,
      String claim,
      Long lease,
      Long generated,
      Long bytes,
      String hash,
      String failure) {}

  record Job(
      String id,
      String tenantId,
      String requesterActorId,
      String deviceId,
      String registrationId,
      String accessMode,
      String grantId,
      List<String> diagnosticTypes,
      String state,
      long version,
      long createdAt,
      long updatedAt,
      long expiresAt,
      Long generatedAt,
      Long byteCount,
      String sha256,
      String failureCode) {}

  record Ref(String id) {}

  void head(String tenant) {
    db.update(
        "INSERT INTO diagnostic_package_heads(tenant_id) VALUES(?) ON DUPLICATE KEY UPDATE"
            + " tenant_id=tenant_id",
        tenant);
  }

  Row row(ResultSet r, int ignored) throws SQLException {
    var scope =
        new Scope(
            r.getString("tenant_id"),
            r.getString("requester_actor_id"),
            r.getString("authority_actor_id"),
            r.getLong("authority_version"),
            r.getString("access_mode"),
            r.getString("grant_id"),
            r.getObject("grant_version", Long.class),
            r.getString("device_id"),
            r.getString("subject_id"),
            r.getString("registration_id"),
            r.getInt("type_mask"));
    return new Row(
        r.getString("id"),
        scope,
        r.getString("state"),
        r.getLong("version"),
        r.getLong("created_at"),
        r.getLong("updated_at"),
        r.getLong("expires_at"),
        r.getInt("attempts"),
        r.getLong("next_attempt_at"),
        r.getString("claim_token"),
        r.getObject("lease_until", Long.class),
        r.getObject("generated_at", Long.class),
        r.getObject("byte_count", Long.class),
        r.getString("artifact_sha256"),
        r.getString("failure_code"));
  }

  Row find(String id, boolean lock) {
    var rows =
        db.query(
            "SELECT "
                + COLUMNS
                + " FROM diagnostic_packages WHERE id=?"
                + (lock ? " FOR UPDATE" : ""),
            this::row,
            id);
    return rows.isEmpty() ? null : rows.get(0);
  }

  Row owned(String id, String actor, String tenant, String mode, boolean lock) {
    var rows =
        db.query(
            "SELECT "
                + COLUMNS
                + " FROM diagnostic_packages WHERE id=? AND requester_key=? AND access_mode=?"
                + (tenant == null ? "" : " AND tenant_id=?")
                + (lock ? " FOR UPDATE" : ""),
            this::row,
            tenant == null
                ? new Object[] {id, ActorKeys.key(actor), mode}
                : new Object[] {id, ActorKeys.key(actor), mode, tenant});
    if (rows.size() != 1 || !rows.get(0).scope().requester().equals(actor))
      throw DomainException.denied();
    return rows.get(0);
  }

  Job view(Row row, long now) {
    var s = row.scope();
    String state = ACTIVE.contains(row.state()) && row.expires() <= now ? "EXPIRED" : row.state();
    boolean ready = state.equals("READY");
    return new Job(
        row.id(),
        s.tenant(),
        s.requester(),
        s.device(),
        s.registration(),
        s.mode(),
        s.grantId(),
        SupportGrantTypes.list(s.types()),
        state,
        row.version(),
        row.created(),
        row.updated(),
        row.expires(),
        ready ? row.generated() : null,
        ready ? row.bytes() : null,
        ready ? row.hash() : null,
        row.failure());
  }

  void terminate(Row row, String state, String failure, long now) {
    db.update(
        "UPDATE diagnostic_packages SET"
            + " state=?,version=version+1,updated_at=?,artifact=NULL,generated_at=NULL,byte_count=NULL,artifact_sha256=NULL,claim_token=NULL,lease_until=NULL,failure_code=?"
            + " WHERE id=?",
        state,
        now,
        failure,
        row.id());
  }

  static String hash(byte[] data) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
    } catch (Exception failure) {
      throw new IllegalStateException("SHA-256 unavailable");
    }
  }

  static String binding(Row row, long generated, long bytes, String hash) {
    var s = row.scope();
    var fields =
        List.of(
            row.id(),
            s.tenant(),
            s.requester(),
            s.authority(),
            "" + s.authorityVersion(),
            s.mode(),
            Objects.toString(s.grantId(), ""),
            Objects.toString(s.grantVersion(), ""),
            s.device(),
            s.subject(),
            s.registration(),
            "" + s.types(),
            "" + row.created(),
            "" + row.expires(),
            "" + generated,
            "" + bytes,
            hash);
    var value = new StringBuilder();
    for (var field : fields) value.append(field.length()).append(':').append(field);
    return hash(value.toString().getBytes(StandardCharsets.UTF_8));
  }
}

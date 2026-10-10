package com.aimanager.retention.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

/** Short-lived preparation evidence. A preview never accepts or authorizes erasure. */
@Service
class ErasurePreviewService {
  record Preview(
      String id,
      String subjectId,
      long subjectVersion,
      String state,
      long createdAt,
      long expiresAt,
      long version,
      boolean executionAvailable,
      ErasurePreflightService.Preflight snapshot) {}

  private record Authority(
      String tenant, String subject, String actorKey, long memberVersion, long subjectVersion) {}

  private record Stored(
      String id,
      long subjectVersion,
      long memberVersion,
      String state,
      String snapshot,
      long createdAt,
      long expiresAt,
      long version) {}

  private static final long TTL = 300_000;
  private static final long RETENTION = 86_400_000;
  private final JdbcTemplate db;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final ErasurePreflightService preflight;
  private final SubjectDataCatalog catalog;
  private final AuditService audit;
  private final ObjectMapper json;
  private final Clock clock;

  ErasurePreviewService(
      JdbcTemplate db,
      TenantAccess access,
      RecentAuthentication recent,
      ErasurePreflightService preflight,
      SubjectDataCatalog catalog,
      AuditService audit,
      ObjectMapper json,
      Clock clock) {
    this.db = db;
    this.access = access;
    this.recent = recent;
    this.preflight = preflight;
    this.catalog = catalog;
    this.audit = audit;
    this.json = json;
    this.clock = clock;
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public Preview create(String tenant, String subject, Jwt actor, String etag, String key) {
    var authority = authorize(tenant, subject, actor);
    long expected = ResourceVersions.require(etag);
    if (key == null || key.isBlank() || key.length() > 128)
      throw DomainException.invalid("INVALID_IDEMPOTENCY_KEY");
    String keyHash = ActorKeys.key(key);
    var previous =
        db.query(
            "SELECT id FROM subject_erasure_previews WHERE tenant_id=? AND subject_id=? AND"
                + " creator_actor_key=? AND key_hash=?",
            (r, n) -> r.getString(1),
            tenant,
            subject,
            authority.actorKey(),
            keyHash);
    if (!previous.isEmpty()) {
      var stored = load(authority, previous.get(0));
      if (stored.subjectVersion() != expected)
        throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_CONFLICT");
      return materialize(authority, stored);
    }
    ResourceVersions.check(expected, authority.subjectVersion());
    long now = clock.millis();
    long count =
        db.queryForObject(
            "SELECT COUNT(*) FROM subject_erasure_previews WHERE tenant_id=? AND subject_id=? AND"
                + " creator_actor_key=? AND created_at>?",
            Long.class,
            tenant,
            subject,
            authority.actorKey(),
            now - 3_600_000);
    if (count >= 20)
      throw new DomainException(HttpStatus.TOO_MANY_REQUESTS, "ERASURE_PREVIEW_RATE_LIMITED");
    var snapshot = preflight.inspect(tenant, subject, actor);
    final String serialized;
    try {
      serialized = json.writeValueAsString(snapshot);
    } catch (JsonProcessingException failure) {
      throw unavailable();
    }
    db.update(
        "UPDATE subject_erasure_previews SET"
            + " state='SUPERSEDED',snapshot_json=NULL,version=version+1 WHERE tenant_id=? AND"
            + " subject_id=? AND creator_actor_key=? AND state='PREPARED'",
        tenant,
        subject,
        authority.actorKey());
    String id = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " subject_erasure_previews(tenant_id,id,subject_id,creator_actor_key,member_version,subject_version,key_hash,state,snapshot_json,created_at,expires_at,version)"
            + " VALUES(?,?,?,?,?,?,?,'PREPARED',?,?,?,0)",
        tenant,
        id,
        subject,
        authority.actorKey(),
        authority.memberVersion(),
        expected,
        keyHash,
        serialized,
        now,
        now + TTL);
    audit.record(tenant, actor.getSubject(), "SUBJECT_ERASURE_PREVIEW_CREATED", id);
    return materialize(authority, load(authority, id));
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public Preview get(String tenant, String subject, String id, Jwt actor) {
    var authority = authorize(tenant, subject, actor);
    var result = materialize(authority, load(authority, id));
    audit.record(tenant, actor.getSubject(), "SUBJECT_ERASURE_PREVIEW_VIEWED", id);
    return result;
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public Preview cancel(String tenant, String subject, String id, Jwt actor, String etag) {
    var authority = authorize(tenant, subject, actor);
    long expected = ResourceVersions.require(etag);
    var stored = load(authority, id);
    // Repeating the exact cancellation does not recreate the preview or add another audit event.
    if (stored.state().equals("CANCELLED")
        && (expected == stored.version() || expected == stored.version() - 1))
      return response(authority, stored, null);
    ResourceVersions.check(expected, stored.version());
    if (!stored.state().equals("PREPARED"))
      throw new DomainException(HttpStatus.CONFLICT, "ERASURE_PREVIEW_NOT_ACTIVE");
    // Cancelling intent remains possible even when the schema has changed or the preview expired.
    transition(authority, id, "CANCELLED");
    audit.record(tenant, actor.getSubject(), "SUBJECT_ERASURE_PREVIEW_CANCELLED", id);
    return response(authority, load(authority, id), null);
  }

  private Authority authorize(String tenant, String subject, Jwt actor) {
    long member = access.requireWriteVersion(tenant, actor.getSubject(), OWNER, ORG_ADMIN);
    recent.require(actor);
    var versions =
        db.query(
            "SELECT version FROM subjects WHERE tenant_id=? AND id=? FOR UPDATE",
            (r, n) -> r.getLong(1),
            tenant,
            subject);
    if (versions.isEmpty()) throw DomainException.denied();
    return new Authority(
        tenant, subject, ActorKeys.key(actor.getSubject()), member, versions.get(0));
  }

  private Stored load(Authority a, String id) {
    var rows =
        db.query(
            "SELECT"
                + " id,subject_version,member_version,state,snapshot_json,created_at,expires_at,version"
                + " FROM subject_erasure_previews WHERE tenant_id=? AND subject_id=? AND"
                + " creator_actor_key=? AND id=? FOR UPDATE",
            (r, n) ->
                new Stored(
                    r.getString(1),
                    r.getLong(2),
                    r.getLong(3),
                    r.getString(4),
                    r.getString(5),
                    r.getLong(6),
                    r.getLong(7),
                    r.getLong(8)),
            a.tenant(),
            a.subject(),
            a.actorKey(),
            id);
    if (rows.isEmpty() || rows.get(0).memberVersion() != a.memberVersion())
      throw DomainException.denied();
    return rows.get(0);
  }

  private Preview materialize(Authority a, Stored stored) {
    if (!stored.state().equals("PREPARED")) return response(a, stored, null);
    String terminal =
        stored.expiresAt() <= clock.millis()
            ? "EXPIRED"
            : stored.subjectVersion() != a.subjectVersion() ? "STALE" : null;
    if (terminal != null) {
      transition(a, stored.id(), terminal);
      return response(a, load(a, stored.id()), null);
    }
    var coverage = catalog.requireCurrentSchema();
    final ErasurePreflightService.Preflight snapshot;
    try {
      snapshot = json.readValue(stored.snapshot(), ErasurePreflightService.Preflight.class);
    } catch (Exception invalid) {
      throw unavailable();
    }
    if (snapshot == null
        || !a.subject().equals(snapshot.subjectId())
        || snapshot.subjectVersion() != stored.subjectVersion()
        || snapshot.executionAvailable()
        || snapshot.readyToErase()
        || snapshot.catalog() == null) throw unavailable();
    if (!coverage.sha256().equals(snapshot.catalog().sha256())) {
      transition(a, stored.id(), "STALE");
      return response(a, load(a, stored.id()), null);
    }
    return response(a, stored, snapshot);
  }

  private Preview response(Authority a, Stored s, ErasurePreflightService.Preflight snapshot) {
    return new Preview(
        s.id(),
        a.subject(),
        s.subjectVersion(),
        s.state(),
        s.createdAt(),
        s.expiresAt(),
        s.version(),
        false,
        snapshot);
  }

  private void transition(Authority a, String id, String state) {
    db.update(
        "UPDATE subject_erasure_previews SET state=?,snapshot_json=NULL,version=version+1 WHERE"
            + " tenant_id=? AND id=? AND state='PREPARED'",
        state,
        a.tenant(),
        id);
  }

  /** Bounded online housekeeping. This is not erasure of business data or backups. */
  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public int purge(int limit) {
    if (limit < 1 || limit > 100) throw new IllegalArgumentException("Invalid cleanup limit");
    long now = clock.millis();
    var expired =
        db.query(
            "SELECT tenant_id,id FROM subject_erasure_previews WHERE state='PREPARED' AND"
                + " expires_at<=? ORDER BY expires_at,tenant_id,id LIMIT ?",
            (r, n) -> List.of(r.getString(1), r.getString(2)),
            now,
            limit);
    int changed = 0;
    for (var row : expired)
      changed +=
          db.update(
              "UPDATE subject_erasure_previews SET"
                  + " state='EXPIRED',snapshot_json=NULL,version=version+1 WHERE tenant_id=? AND"
                  + " id=? AND state='PREPARED' AND expires_at<=?",
              row.get(0),
              row.get(1),
              now);
    var old =
        db.query(
            "SELECT tenant_id,id FROM subject_erasure_previews WHERE state<>'PREPARED' AND"
                + " created_at<=? ORDER BY created_at,tenant_id,id LIMIT ?",
            (r, n) -> List.of(r.getString(1), r.getString(2)),
            now - RETENTION,
            limit);
    for (var row : old)
      changed +=
          db.update(
              "DELETE FROM subject_erasure_previews WHERE tenant_id=? AND id=? AND"
                  + " state<>'PREPARED' AND created_at<=?",
              row.get(0),
              row.get(1),
              now - RETENTION);
    return changed;
  }

  private DomainException unavailable() {
    return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "ERASURE_PREVIEW_UNAVAILABLE");
  }
}

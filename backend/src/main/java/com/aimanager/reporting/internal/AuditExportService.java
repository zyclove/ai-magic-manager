package com.aimanager.reporting.internal;

import com.aimanager.audit.*;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.*;
import com.aimanager.shared.*;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class AuditExportService {
  private final ExportStore store;
  private final ExportCipher cipher;
  private final IdempotencyService idempotency;
  private final RecentAuthentication recent;
  private final AuditService audit;
  private final Clock clock;

  AuditExportService(
      ExportStore store,
      ExportCipher cipher,
      IdempotencyService idempotency,
      RecentAuthentication recent,
      AuditService audit,
      Clock clock) {
    this.store = store;
    this.cipher = cipher;
    this.idempotency = idempotency;
    this.recent = recent;
    this.audit = audit;
    this.clock = clock;
  }

  record Ref(String id) {}

  @Transactional(timeout = 10)
  public ExportStore.Job create(String tenant, Jwt actor, AuditSelection input, String key) {
    var member = store.authorize(tenant, actor.getSubject(), true);
    recent.require(actor);
    cipher.requireAvailable();
    if (key == null || key.isBlank()) throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
    store.head(tenant);
    var ref =
        idempotency.execute(
            tenant,
            actor.getSubject(),
            "AUDIT_EXPORT_CREATE",
            key,
            input.attributes(),
            Ref.class,
            () -> {
              long now = clock.millis();
              var selection =
                  new AuditSelection(
                      input.from(),
                      Math.min(input.to(), now),
                      input.action(),
                      input.resourceId(),
                      input.correlationId());
              String creator = ActorKeys.key(actor.getSubject());
              long recentCount =
                  store.db.queryForObject(
                      "SELECT COUNT(*) FROM audit_exports WHERE tenant_id=? AND creator_key=? AND"
                          + " created_at>?",
                      Long.class,
                      tenant,
                      creator,
                      now - 60000);
              long activeOwn =
                  store.db.queryForObject(
                      "SELECT COUNT(*) FROM audit_exports WHERE tenant_id=? AND creator_key=? AND"
                          + " expires_at>? AND state IN ('QUEUED','RUNNING','READY')",
                      Long.class,
                      tenant,
                      creator,
                      now);
              long activeTenant =
                  store.db.queryForObject(
                      "SELECT COUNT(*) FROM audit_exports WHERE tenant_id=? AND expires_at>? AND"
                          + " state IN ('QUEUED','RUNNING','READY')",
                      Long.class,
                      tenant,
                      now);
              if (recentCount > 0 || activeOwn >= 5 || activeTenant >= 100)
                throw new DomainException(HttpStatus.TOO_MANY_REQUESTS, "EXPORT_CAPACITY_REACHED");
              String id = UUID.randomUUID().toString();
              store.db.update(
                  "INSERT INTO"
                      + " audit_exports(tenant_id,id,creator_key,member_version,state,range_from,range_to,requested_to,action_filter,resource_filter,correlation_filter,created_at,updated_at,expires_at,next_attempt_at)"
                      + " VALUES(?,?,?,?,'QUEUED',?,?,?,?,?,?,?,?,?,?)",
                  tenant,
                  id,
                  creator,
                  member.version(),
                  selection.from(),
                  selection.to(),
                  input.to(),
                  input.action(),
                  input.resourceId(),
                  input.correlationId(),
                  now,
                  now,
                  now + 86400000,
                  now);
              audit.record(tenant, actor.getSubject(), "AUDIT_EXPORT_REQUESTED", id);
              return new Ref(id);
            });
    return store.view(
        store.owned(tenant, ref.id(), actor.getSubject(), true), member, clock.millis());
  }

  public ExportStore.Job get(String tenant, String id, Jwt actor) {
    var member = store.authorize(tenant, actor.getSubject(), false);
    return store.view(store.owned(tenant, id, actor.getSubject(), false), member, clock.millis());
  }

  public ItemPage<ExportStore.Job> list(String tenant, Jwt actor, int limit, String cursor) {
    var member = store.authorize(tenant, actor.getSubject(), false);
    if (limit < 1 || limit > 50) throw DomainException.invalid("INVALID_PAGE_SIZE");
    String creator = ActorKeys.key(actor.getSubject()),
        scope = SecretMaterial.hash(tenant + "|" + creator);
    var sql =
        new StringBuilder(
            "SELECT "
                + ExportStore.COLUMNS
                + " FROM audit_exports WHERE tenant_id=? AND creator_key=?");
    var values = new ArrayList<Object>(List.of(tenant, creator));
    if (cursor != null) {
      try {
        if (cursor.length() > 256) throw new IllegalArgumentException();
        var parts =
            new String(Base64.getUrlDecoder().decode(cursor), StandardCharsets.UTF_8)
                .split("\\|", -1);
        if (parts.length != 3 || !scope.equals(parts[0])) throw new IllegalArgumentException();
        long at = Long.parseLong(parts[1]);
        AuditSelection.uuid(parts[2]);
        if (at < 0 || !encode(scope, at, parts[2]).equals(cursor))
          throw new IllegalArgumentException();
        sql.append(" AND (created_at<? OR (created_at=? AND id<?))");
        values.add(at);
        values.add(at);
        values.add(parts[2]);
      } catch (IllegalArgumentException | DomainException invalid) {
        throw DomainException.invalid("INVALID_CURSOR");
      }
    }
    sql.append(" ORDER BY created_at DESC,id DESC LIMIT ?");
    values.add(limit + 1);
    var rows = store.db.query(sql.toString(), ExportStore::row, values.toArray());
    var page = ItemPage.from(rows, limit, r -> encode(scope, r.createdAt(), r.id()));
    return new ItemPage<>(
        page.items().stream().map(r -> store.view(r, member, clock.millis())).toList(),
        page.nextCursor());
  }

  private String encode(String scope, long time, String id) {
    return Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString((scope + "|" + time + "|" + id).getBytes(StandardCharsets.UTF_8));
  }

  @Transactional(timeout = 10)
  public ExportStore.Job cancel(String tenant, String id, Jwt actor) {
    var member = store.authorize(tenant, actor.getSubject(), true);
    store.head(tenant);
    var row = store.owned(tenant, id, actor.getSubject(), true);
    if (ExportStore.ACTIVE.contains(row.state())) {
      String state = store.effective(row, member, clock.millis());
      String target = ExportStore.ACTIVE.contains(state) ? "CANCELLED" : state;
      store.terminate(row, target, null, clock.millis());
      audit.record(tenant, actor.getSubject(), "AUDIT_EXPORT_" + target, id);
    }
    return store.view(store.find(tenant, id, true), member, clock.millis());
  }

  @Transactional(timeout = 10)
  public byte[] content(String tenant, String id, Jwt actor) {
    var member = store.authorize(tenant, actor.getSubject(), true);
    recent.require(actor);
    store.head(tenant);
    var row = store.owned(tenant, id, actor.getSubject(), true);
    if (member.version() != row.memberVersion()) throw DomainException.denied();
    if (!"READY".equals(store.effective(row, member, clock.millis())))
      throw new DomainException(HttpStatus.CONFLICT, "EXPORT_NOT_READY");
    var artifacts =
        store.db.query(
            "SELECT artifact FROM audit_exports WHERE tenant_id=? AND id=? AND"
                + " OCTET_LENGTH(artifact)<=?",
            (r, n) -> r.getString(1),
            tenant,
            id,
            12 * 1024 * 1024);
    if (artifacts.isEmpty())
      throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EXPORT_ARTIFACT_UNAVAILABLE");
    byte[] body = cipher.open(tenant, id, row.binding(), artifacts.get(0));
    if (row.byteCount() == null || body.length != row.byteCount() || body.length > 8 * 1024 * 1024)
      throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EXPORT_ARTIFACT_UNAVAILABLE");
    audit.record(tenant, actor.getSubject(), "AUDIT_EXPORT_DOWNLOADED", id);
    return body;
  }
}

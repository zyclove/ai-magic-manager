package com.aimanager.support.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.*;
import com.aimanager.shared.*;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.*;
import org.springframework.transaction.support.TransactionTemplate;

@Service
class DiagnosticPackageService {
  final DiagnosticPackageStore store;
  final DiagnosticPackageAccess scopes;
  final Clock clock;
  final AuditService audit;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final DiagnosticPackageCipher cipher;
  private final IdempotencyService idempotency;
  private final TransactionTemplate tx;

  DiagnosticPackageService(
      DiagnosticPackageStore store,
      DiagnosticPackageAccess scopes,
      TenantAccess access,
      RecentAuthentication recent,
      DiagnosticPackageCipher cipher,
      IdempotencyService idempotency,
      AuditService audit,
      Clock clock,
      PlatformTransactionManager transactions) {
    this.store = store;
    this.scopes = scopes;
    this.access = access;
    this.recent = recent;
    this.cipher = cipher;
    this.idempotency = idempotency;
    this.audit = audit;
    this.clock = clock;
    tx = new TransactionTemplate(transactions);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    tx.setTimeout(10);
  }

  DiagnosticPackageStore.Job createAdmin(
      String tenant, String device, String registration, Jwt actor, String etag, String key) {
    recent.require(actor);
    checkKey(key);
    long expected = ResourceVersions.require(etag);
    return tx.execute(
        status -> {
          var scope = scopes.admin(tenant, actor.getSubject(), device, registration);
          return create(scope, expected, key);
        });
  }

  DiagnosticPackageStore.Job createRecipient(String grant, Jwt actor, boolean adult, String key) {
    authenticate(actor, adult, "SUPPORT_GRANT");
    checkKey(key);
    return tx.execute(status -> create(scopes.recipient(grant, actor.getSubject()), null, key));
  }

  private DiagnosticPackageStore.Job create(
      DiagnosticPackageStore.Scope scope, Long expected, String key) {
    cipher.requireAvailable();
    var grant = scopes.lock(scope);
    var ref =
        idempotency.execute(
            scope.tenant(),
            scope.requester(),
            "diagnostic-package.create",
            key,
            Map.of(
                "mode",
                scope.mode(),
                "device",
                scope.device(),
                "registration",
                scope.registration(),
                "grant",
                Objects.toString(scope.grantId(), ""),
                "types",
                scope.types(),
                "deviceVersion",
                expected == null ? -1L : expected,
                "authorityVersion",
                scope.authorityVersion()),
            DiagnosticPackageStore.Ref.class,
            () -> {
              if (expected != null) scopes.deviceVersion(scope, expected);
              long now = clock.millis(),
                  expires =
                      grant == null ? now + 1800000 : Math.min(now + 1800000, grant.expiresAt());
              if (expires <= now) throw DomainException.denied();
              var active =
                  store.db.queryForList(
                      "SELECT id,requester_key FROM diagnostic_packages WHERE tenant_id=? AND state"
                          + " IN ('QUEUED','RUNNING','READY') AND expires_at>? ORDER BY id LIMIT"
                          + " 101 FOR UPDATE",
                      scope.tenant(),
                      now);
              if (active.size() >= 100
                  || active.stream()
                          .filter(
                              row ->
                                  ActorKeys.key(scope.requester()).equals(row.get("requester_key")))
                          .count()
                      >= 10)
                throw new DomainException(
                    HttpStatus.CONFLICT, "DIAGNOSTIC_PACKAGE_CAPACITY_REACHED");
              String id = UUID.randomUUID().toString();
              store.db.update(
                  "INSERT INTO"
                      + " diagnostic_packages(id,tenant_id,requester_actor_id,requester_key,authority_actor_id,authority_key,authority_version,access_mode,grant_id,grant_version,device_id,subject_id,registration_id,type_mask,state,created_at,updated_at,expires_at,next_attempt_at,next_validation_at)"
                      + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,'QUEUED',?,?,?,?,?)",
                  id,
                  scope.tenant(),
                  scope.requester(),
                  ActorKeys.key(scope.requester()),
                  scope.authority(),
                  ActorKeys.key(scope.authority()),
                  scope.authorityVersion(),
                  scope.mode(),
                  scope.grantId(),
                  scope.grantVersion(),
                  scope.device(),
                  scope.subject(),
                  scope.registration(),
                  scope.types(),
                  now,
                  now,
                  expires,
                  now,
                  now);
              audit.record(scope.tenant(), scope.requester(), "DIAGNOSTIC_PACKAGE_REQUESTED", id);
              return new DiagnosticPackageStore.Ref(id);
            });
    return store.view(
        store.owned(ref.id(), scope.requester(), scope.tenant(), scope.mode(), false),
        clock.millis());
  }

  private void authenticate(Jwt actor, boolean adult, String mode) {
    if (mode.equals("SUPPORT_GRANT") && !adult) throw DomainException.denied();
    recent.require(actor);
  }

  private DiagnosticPackageStore.Row owned(
      String tenant, String id, Jwt actor, String mode, boolean lock) {
    if (mode.equals("ADMIN"))
      access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    return store.owned(id, actor.getSubject(), tenant, mode, lock);
  }

  DiagnosticPackageStore.Job get(String tenant, String id, Jwt actor, boolean adult, String mode) {
    authenticate(actor, adult, mode);
    try {
      return tx.execute(
          status -> {
            var hint = owned(tenant, id, actor, mode, false);
            if (DiagnosticPackageStore.ACTIVE.contains(hint.state())
                && hint.expires() > clock.millis()) scopes.lock(hint.scope());
            else store.head(hint.scope().tenant());
            var row = owned(tenant, id, actor, mode, true);
            expire(row);
            return store.view(store.find(id, false), clock.millis());
          });
    } catch (DomainException failure) {
      if (!scopeFailure(failure)) throw failure;
      return tx.execute(
          status -> {
            var hint = owned(tenant, id, actor, mode, false);
            store.head(hint.scope().tenant());
            var row = owned(tenant, id, actor, mode, true);
            invalidate(row);
            return store.view(store.find(id, false), clock.millis());
          });
    }
  }

  ItemPage<DiagnosticPackageStore.Job> list(
      String tenant, Jwt actor, boolean adult, String mode, int limit, String cursor) {
    authenticate(actor, adult, mode);
    ItemPage.validate(limit, cursor);
    if (limit > 25) throw DomainException.invalid("INVALID_PAGE_LIMIT");
    var rows =
        tx.execute(
            status -> {
              if (mode.equals("ADMIN"))
                access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
              var args = new ArrayList<Object>();
              args.add(ActorKeys.key(actor.getSubject()));
              args.add(mode);
              if (tenant != null) args.add(tenant);
              args.add(cursor == null ? "" : cursor);
              args.add(limit + 1);
              return store.db.query(
                  "SELECT "
                      + DiagnosticPackageStore.COLUMNS
                      + " FROM diagnostic_packages WHERE requester_key=? AND access_mode=?"
                      + (tenant == null ? "" : " AND tenant_id=?")
                      + " AND id>? ORDER BY id LIMIT ?",
                  store::row,
                  args.toArray());
            });
    var values = new ArrayList<DiagnosticPackageStore.Job>();
    for (var row : rows) values.add(get(tenant, row.id(), actor, adult, mode));
    return ItemPage.from(values, limit, DiagnosticPackageStore.Job::id);
  }

  DiagnosticPackageStore.Job cancel(
      String tenant, String id, Jwt actor, boolean adult, String mode, String etag, String key) {
    authenticate(actor, adult, mode);
    checkKey(key);
    long expected = ResourceVersions.require(etag);
    return tx.execute(
        status -> {
          var hint = owned(tenant, id, actor, mode, false);
          store.head(hint.scope().tenant());
          var row = owned(tenant, id, actor, mode, true);
          idempotency.execute(
              row.scope().tenant(),
              actor.getSubject(),
              "diagnostic-package.cancel",
              key,
              Map.of("id", id, "version", expected),
              DiagnosticPackageStore.Ref.class,
              () -> {
                ResourceVersions.check(expected, row.version());
                if (DiagnosticPackageStore.ACTIVE.contains(row.state()))
                  terminate(row, row.expires() <= clock.millis() ? "EXPIRED" : "CANCELLED", null);
                return new DiagnosticPackageStore.Ref(id);
              });
          return store.view(store.find(id, false), clock.millis());
        });
  }

  byte[] content(String tenant, String id, Jwt actor, boolean adult, String mode) {
    authenticate(actor, adult, mode);
    try {
      return tx.execute(
          status -> {
            var hint = owned(tenant, id, actor, mode, false);
            if (hint.expires() <= clock.millis()) throw expired();
            var grant = scopes.lock(hint.scope());
            var row = owned(tenant, id, actor, mode, true);
            if (row.state().equals("REVOKED")) throw DomainException.denied();
            if (!row.state().equals("READY"))
              throw new DomainException(HttpStatus.CONFLICT, "DIAGNOSTIC_PACKAGE_NOT_READY");
            if (row.generated() == null
                || row.bytes() == null
                || row.hash() == null
                || row.bytes() < 1
                || row.bytes() > DiagnosticPackageCipher.MAX_BYTES)
              throw new DomainException(
                  HttpStatus.SERVICE_UNAVAILABLE, "DIAGNOSTIC_PACKAGE_UNAVAILABLE");
            String encrypted =
                store.db.queryForObject(
                    "SELECT artifact FROM diagnostic_packages WHERE id=?", String.class, id);
            byte[] bytes =
                cipher.open(
                    row.scope().tenant(),
                    id,
                    DiagnosticPackageStore.binding(row, row.generated(), row.bytes(), row.hash()),
                    encrypted);
            if (bytes.length != row.bytes()
                || !DiagnosticPackageStore.hash(bytes).equals(row.hash()))
              throw new DomainException(
                  HttpStatus.SERVICE_UNAVAILABLE, "DIAGNOSTIC_PACKAGE_UNAVAILABLE");
            if (row.expires() <= clock.millis()) throw expired();
            if (grant != null) scopes.active(grant);
            audit.record(
                row.scope().tenant(), actor.getSubject(), "DIAGNOSTIC_PACKAGE_DOWNLOADED", id);
            return bytes;
          });
    } catch (DomainException failure) {
      if (scopeFailure(failure) || failure.errorCode().equals("DIAGNOSTIC_PACKAGE_EXPIRED"))
        tx.executeWithoutResult(
            status -> {
              var hint = owned(tenant, id, actor, mode, false);
              store.head(hint.scope().tenant());
              invalidate(owned(tenant, id, actor, mode, true));
            });
      throw failure;
    }
  }

  void terminate(DiagnosticPackageStore.Row row, String state, String reason) {
    if (!DiagnosticPackageStore.ACTIVE.contains(row.state())) return;
    store.terminate(row, state, reason, clock.millis());
    audit.record(
        row.scope().tenant(), "system:diagnostics", "DIAGNOSTIC_PACKAGE_" + state, row.id());
  }

  void expire(DiagnosticPackageStore.Row row) {
    if (row.expires() <= clock.millis()) terminate(row, "EXPIRED", null);
  }

  void invalidate(DiagnosticPackageStore.Row row) {
    terminate(row, row.expires() <= clock.millis() ? "EXPIRED" : "REVOKED", null);
  }

  static boolean scopeFailure(DomainException failure) {
    return Set.of("SCOPE_DENIED", "DEVICE_NOT_ACTIVE", "CLASS_ARCHIVED", "SUBJECT_ARCHIVED")
        .contains(failure.errorCode());
  }

  static DomainException expired() {
    return new DomainException(HttpStatus.GONE, "DIAGNOSTIC_PACKAGE_EXPIRED");
  }

  private void checkKey(String key) {
    if (key == null || key.isBlank() || key.length() > 128)
      throw DomainException.invalid("INVALID_IDEMPOTENCY_KEY");
  }
}

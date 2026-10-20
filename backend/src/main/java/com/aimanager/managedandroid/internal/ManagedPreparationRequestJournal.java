package com.aimanager.managedandroid.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.Objects;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Durable preparation leases and local cancellation. No network operation, execution task creation
 * or scheduler is performed here. A lease authorizes one bounded read attempt; it is not permission
 * to write to a provider. Every later task handoff must independently revalidate the full result.
 */
@Service
class ManagedPreparationRequestJournal {
  private static final long MAX_COUNTER = 9007199254740990L;
  private final JdbcTemplate db;
  private final ManagedAgentBindingStore bindings;
  private final ManagedExecutionPublicationAccess publications;
  private final TenantAccess access;
  private final AuditService audit;
  private final ObjectMapper json;
  private final TransactionTemplate tx;
  private final long leaseMillis;
  private final int maximumAttempts;
  private final long retryMillis;

  ManagedPreparationRequestJournal(
      JdbcTemplate db,
      ManagedAgentBindingStore bindings,
      ManagedExecutionPublicationAccess publications,
      TenantAccess access,
      AuditService audit,
      PlatformTransactionManager transactions,
      ObjectMapper json,
      @Value("${manager.emm.execution.preparation.lease-seconds:60}") int leaseSeconds,
      @Value("${manager.emm.execution.preparation.maximum-attempts:5}") int maximumAttempts,
      @Value("${manager.emm.execution.preparation.retry-seconds:30}") int retrySeconds) {
    if (leaseSeconds < 5
        || leaseSeconds > 300
        || maximumAttempts < 1
        || maximumAttempts > 24
        || retrySeconds < 1
        || retrySeconds > 300)
      throw new IllegalArgumentException("Invalid preparation scheduling configuration");
    this.db = db;
    this.bindings = bindings;
    this.publications = publications;
    this.access = access;
    this.audit = audit;
    this.json = json;
    this.leaseMillis = leaseSeconds * 1000L;
    this.maximumAttempts = maximumAttempts;
    this.retryMillis = retrySeconds * 1000L;
    tx = new TransactionTemplate(transactions);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    tx.setTimeout(10);
  }

  enum State {
    PENDING,
    ADMITTED,
    REJECTED,
    CANCELLED
  }

  /**
   * Minimal internal scan result; never carries credentials, compiled policy or authority proof.
   */
  record Reference(String tenantId, String requestId) {}

  java.util.List<Reference> dueRequests(int limit) {
    separate("Preparation scan requires a separate transaction");
    if (limit < 1 || limit > 25)
      throw new IllegalArgumentException("Invalid preparation scan limit");
    return tx.execute(
        status -> {
          requireReadCommitted();
          long observedAt = now();
          // Expired rows must retire even when a connector is unavailable or a retry is in the
          // future.
          // Separate indexed ranges avoid sorting every pending request by an expiry CASE
          // expression.
          var selected =
              new java.util.ArrayList<>(
                  db.query(
                      "SELECT tenant_id,id FROM managed_policy_preparation_requests WHERE"
                          + " state='PENDING' AND expires_at<=? ORDER BY expires_at,id,tenant_id"
                          + " LIMIT ?",
                      (row, index) -> new Reference(row.getString(1), row.getString(2)),
                      observedAt,
                      limit));
          int remaining = limit - selected.size();
          if (remaining > 0)
            selected.addAll(
                db.query(
                    "SELECT tenant_id,id FROM managed_policy_preparation_requests WHERE"
                        + " state='PENDING' AND next_attempt_at<=? AND expires_at>? AND"
                        + " (lease_until IS NULL OR lease_until<=?) ORDER BY"
                        + " next_attempt_at,id,tenant_id LIMIT ?",
                    (row, index) -> new Reference(row.getString(1), row.getString(2)),
                    observedAt,
                    observedAt,
                    observedAt,
                    remaining));
          // No lease is taken here. The worker must claim again against current authoritative
          // state.
          return java.util.List.copyOf(selected);
        });
  }

  /** Internal capability reference; never serialize this into an API, event or ordinary log. */
  record Claim(
      String tenantId,
      String requestId,
      String token,
      long generation,
      long leaseUntil,
      long revision,
      String publicationId,
      ManagedAgentBindingStore.VerifiedBindingContext binding) {
    @Override
    public String toString() {
      return "ManagedPreparationClaim[REDACTED]";
    }
  }

  record View(
      String id,
      String publicationId,
      String versionId,
      String deviceId,
      String registrationId,
      State state,
      String reasonCode,
      long revision,
      String executionTaskId,
      long expiresAt,
      long createdAt,
      long updatedAt) {}

  /**
   * Locked server facts for the caller's short handoff transaction, never a provider-write permit.
   */
  record HandoffTarget(
      Claim claim,
      ManagedAgentBindingStore.VerifiedBindingContext binding,
      String versionId,
      long expiresAt) {
    @Override
    public String toString() {
      return "ManagedPreparationHandoffTarget[REDACTED]";
    }
  }

  private record Row(
      String tenant,
      String id,
      String publication,
      String version,
      String subject,
      String device,
      String registration,
      String binding,
      long bindingVersion,
      String actor,
      long authority,
      String contextHash,
      State state,
      long revision,
      String reason,
      String task,
      long generation,
      String token,
      Long leaseUntil,
      int attempts,
      long nextAt,
      long expiresAt,
      long createdAt,
      long updatedAt) {}

  Claim claim(String tenant, String request) {
    separate("Preparation claim requires a separate transaction");
    canonicalId(tenant);
    canonicalId(request);
    return tx.execute(
        status -> {
          requireReadCommitted();
          var seed = find(tenant, request, false);
          if (seed == null || seed.state() != State.PENDING) return null;
          if (terminalReason(seed, now()) != null) {
            // Expiry/attempt exhaustion only removes a server-owned read authorization. It must
            // work even when the provider is unavailable. This branch takes only the request lock
            // and always returns: never acquire domain locks after locking the request.
            var terminal = find(tenant, request, true);
            long observedAt = now();
            String reason = terminalReason(terminal, observedAt);
            if (reason != null)
              finish(terminal, State.REJECTED, reason, observedAt, observedAt, terminal.actor());
            return null;
          }
          // Never lock a request before acquiring the established authority/enterprise/device
          // locks.
          var context = captureOrRejected(seed);
          var current = find(tenant, request, true);
          if (current == null || current.state() != State.PENDING) return null;
          long now = now();
          if (context == null || !sameSource(seed, current)) {
            finish(current, State.REJECTED, "CONTEXT_CHANGED", now, now, current.actor());
            return null;
          }
          if (current.expiresAt() <= now) {
            finish(current, State.REJECTED, "DEADLINE_EXCEEDED", now, now, current.actor());
            return null;
          }
          // The final allowed attempt may still be running. Do not retire its valid lease merely
          // because attempts has reached the limit; inspect the limit only when another read is
          // due.
          if ((current.leaseUntil() != null && current.leaseUntil() > now)
              || current.nextAt() > now) return null;
          if (current.attempts() >= maximumAttempts) {
            finish(current, State.REJECTED, "ATTEMPTS_EXHAUSTED", now, now, current.actor());
            return null;
          }
          counters(current, true);
          String token = UUID.randomUUID().toString();
          long until = Math.min(current.expiresAt(), now + leaseMillis);
          exactlyOne(
              db.update(
                  "UPDATE managed_policy_preparation_requests SET generation=generation+1,"
                      + "revision=revision+1,attempts=attempts+1,lease_token=?,lease_until=?,reason_code='CLAIMED',updated_at=?"
                      + " WHERE tenant_id=? AND id=? AND revision=? AND state='PENDING'",
                  token,
                  until,
                  now,
                  tenant,
                  request,
                  current.revision()));
          return new Claim(
              tenant,
              request,
              token,
              current.generation() + 1,
              until,
              current.revision() + 1,
              current.publication(),
              context);
        });
  }

  /**
   * Must join the handoff transaction. Acquires current domain authority before the request row and
   * holds both until task creation and request association commit or roll back together.
   */
  HandoffTarget handoffTarget(Claim claim) {
    requireReadCommitted();
    if (claim == null || claim.binding() == null) throw conflict("PREPARATION_HANDOFF_STALE");
    canonicalId(claim.tenantId());
    canonicalId(claim.requestId());
    var seed = find(claim.tenantId(), claim.requestId(), false);
    if (!owns(seed, claim, now())) throw conflict("PREPARATION_HANDOFF_STALE");
    var context = captureOrRejected(seed);
    var current = find(claim.tenantId(), claim.requestId(), true);
    if (context == null
        || !sameSource(seed, current)
        || !owns(current, claim, now())
        || !context.equals(claim.binding())) throw conflict("PREPARATION_HANDOFF_STALE");
    return new HandoffTarget(claim, context, current.version(), current.expiresAt());
  }

  /** A successful answer is a point-in-time observation, never a substitute for atomic handoff. */
  boolean current(Claim claim) {
    separate("Preparation lease validation requires a separate transaction");
    if (claim == null) return false;
    canonicalId(claim.tenantId());
    canonicalId(claim.requestId());
    return Boolean.TRUE.equals(
        tx.execute(
            status -> {
              requireReadCommitted();
              var seed = find(claim.tenantId(), claim.requestId(), false);
              if (!owns(seed, claim, now())) return false;
              var context = captureOrRejected(seed);
              var current = find(claim.tenantId(), claim.requestId(), true);
              return context != null
                  && sameSource(seed, current)
                  && owns(current, claim, now())
                  && context.equals(claim.binding());
            }));
  }

  /** Only the still-current read attempt may release its lease or record a bounded retry. */
  boolean failed(Claim claim, boolean retryable) {
    separate("Preparation failure recording requires a separate transaction");
    if (claim == null) return false;
    canonicalId(claim.tenantId());
    canonicalId(claim.requestId());
    return Boolean.TRUE.equals(
        tx.execute(
            status -> {
              requireReadCommitted();
              var seed = find(claim.tenantId(), claim.requestId(), false);
              if (!owns(seed, claim, now())) return false;
              var context = captureOrRejected(seed);
              var current = find(claim.tenantId(), claim.requestId(), true);
              long now = now();
              if (!owns(current, claim, now)) return false;
              if (context == null
                  || !sameSource(seed, current)
                  || !context.equals(claim.binding())) {
                finish(current, State.REJECTED, "CONTEXT_CHANGED", now, now, current.actor());
                return true;
              }
              if (!retryable) {
                finish(current, State.REJECTED, "PREPARATION_FAILED", now, now, current.actor());
                return true;
              }
              long delay =
                  Math.min(300_000L, retryMillis * (1L << Math.min(current.attempts() - 1, 5)));
              if (now + delay >= current.expiresAt()) {
                finish(current, State.REJECTED, "DEADLINE_EXCEEDED", now, now, current.actor());
              } else if (current.attempts() >= maximumAttempts) {
                finish(current, State.REJECTED, "ATTEMPTS_EXHAUSTED", now, now, current.actor());
              } else {
                finish(
                    current,
                    State.PENDING,
                    "READ_RETRY_SCHEDULED",
                    now + delay,
                    now,
                    current.actor());
              }
              return true;
            }));
  }

  View get(String tenant, String actor, String request) {
    canonicalId(tenant);
    canonicalId(request);
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    return view(required(tenant, request, false));
  }

  /**
   * The HTTP caller must additionally require recent authentication before invoking this method.
   */
  View cancel(String tenant, String actor, String request, long revision) {
    canonicalId(tenant);
    canonicalId(request);
    return tx.execute(
        status -> {
          requireReadCommitted();
          access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
          var current = required(tenant, request, true);
          ResourceVersions.check(revision, current.revision());
          if (current.state() == State.CANCELLED) return view(current);
          if (current.state() == State.ADMITTED) throw conflict("PREPARATION_ALREADY_ADMITTED");
          if (current.state() != State.PENDING) throw conflict("PREPARATION_ALREADY_TERMINAL");
          // A replacement administrator can cancel after the original actor is revoked. Do not
          // acquire
          // original-actor, binding or enterprise locks while holding this request row.
          long now = now();
          finish(current, State.CANCELLED, "CANCELLED_BY_ADMINISTRATOR", now, now, actor);
          return view(required(tenant, request, false));
        });
  }

  private ManagedAgentBindingStore.VerifiedBindingContext captureOrRejected(Row row) {
    try {
      long authority = access.requireWriteVersion(row.tenant(), row.actor(), OWNER, ORG_ADMIN);
      if (authority != row.authority()) return null;
      var context =
          bindings.requireVerifiedContext(
              row.tenant(), row.actor(), row.binding(), row.bindingVersion());
      if (context == null
          || !Objects.equals(context.tenantId(), row.tenant())
          || !Objects.equals(context.actorId(), row.actor())
          || context.authorityVersion() != authority
          || !Objects.equals(context.subjectId(), row.subject())
          || !Objects.equals(context.deviceId(), row.device())
          || !Objects.equals(context.registrationId(), row.registration())
          || !Objects.equals(context.bindingId(), row.binding())
          || context.bindingVersion() != row.bindingVersion()
          || !Objects.equals(hash(context), row.contextHash())) return null;
      var publication =
          publications.requireTarget(
              row.tenant(), row.actor(), row.publication(), row.device(), row.registration());
      return publication != null && Objects.equals(publication.versionId(), row.version())
          ? context
          : null;
    } catch (DomainException rejection) {
      // Storage, timeouts and unexpected failures must roll back and remain observable. Only
      // explicit authority/resource rejections are business outcomes; never catch RuntimeException.
      if (rejection.status() == HttpStatus.FORBIDDEN
          || rejection.status() == HttpStatus.NOT_FOUND
          || rejection.status() == HttpStatus.CONFLICT
          || rejection.status() == HttpStatus.PRECONDITION_FAILED) return null;
      throw rejection;
    }
  }

  /** Never retire a still-valid final lease merely because no further attempt may be started. */
  private String terminalReason(Row row, long now) {
    if (row == null || row.state() != State.PENDING) return null;
    if (row.expiresAt() <= now) return "DEADLINE_EXCEEDED";
    if (row.attempts() >= maximumAttempts
        && row.nextAt() <= now
        && (row.leaseUntil() == null || row.leaseUntil() <= now)) return "ATTEMPTS_EXHAUSTED";
    return null;
  }

  private boolean sameSource(Row a, Row b) {
    return a != null
        && b != null
        && a.tenant().equals(b.tenant())
        && a.id().equals(b.id())
        && a.publication().equals(b.publication())
        && a.version().equals(b.version())
        && a.subject().equals(b.subject())
        && a.device().equals(b.device())
        && a.registration().equals(b.registration())
        && a.binding().equals(b.binding())
        && a.bindingVersion() == b.bindingVersion()
        && a.actor().equals(b.actor())
        && a.authority() == b.authority()
        && a.contextHash().equals(b.contextHash())
        && a.createdAt() == b.createdAt()
        && a.expiresAt() == b.expiresAt();
  }

  private boolean owns(Row row, Claim claim, long now) {
    return row != null
        && row.state() == State.PENDING
        && claim.binding() != null
        && row.tenant().equals(claim.tenantId())
        && row.id().equals(claim.requestId())
        && row.publication().equals(claim.publicationId())
        && row.revision() == claim.revision()
        && row.token() != null
        && row.token().equals(claim.token())
        && row.generation() == claim.generation()
        && row.leaseUntil() != null
        && row.leaseUntil() == claim.leaseUntil()
        && row.leaseUntil() > now
        && row.expiresAt() > now
        && row.contextHash().equals(hash(claim.binding()));
  }

  private void finish(Row row, State state, String reason, long nextAt, long now, String actor) {
    counters(row, false);
    if (state != State.PENDING && state != State.REJECTED && state != State.CANCELLED)
      throw new IllegalStateException("Preparation lease journal cannot admit execution tasks");
    exactlyOne(
        db.update(
            "UPDATE managed_policy_preparation_requests SET state=?,reason_code=?,"
                + "revision=revision+1,lease_token=NULL,lease_until=NULL,active_device_id=?,next_attempt_at=?,updated_at=?"
                + " WHERE tenant_id=? AND id=? AND revision=? AND state='PENDING'",
            state.name(),
            reason,
            state == State.PENDING ? row.device() : null,
            nextAt,
            now,
            row.tenant(),
            row.id(),
            row.revision()));
    if (state != State.PENDING)
      audit.record(
          row.tenant(),
          actor,
          state == State.CANCELLED ? "PREPARATION_CANCELLED" : "PREPARATION_REJECTED",
          row.id());
  }

  private Row required(String tenant, String request, boolean lock) {
    var row = find(tenant, request, lock);
    if (row == null)
      throw new DomainException(HttpStatus.NOT_FOUND, "PREPARATION_REQUEST_NOT_FOUND");
    return row;
  }

  private Row find(String tenant, String request, boolean lock) {
    var rows =
        db.query(
            "SELECT * FROM managed_policy_preparation_requests WHERE tenant_id=? AND id=?"
                + (lock ? " FOR UPDATE" : ""),
            this::row,
            tenant,
            request);
    return rows.isEmpty() ? null : rows.get(0);
  }

  private Row row(ResultSet r, int ignored) throws SQLException {
    return new Row(
        r.getString("tenant_id"),
        r.getString("id"),
        r.getString("publication_id"),
        r.getString("policy_version_id"),
        r.getString("subject_id"),
        r.getString("device_id"),
        r.getString("registration_id"),
        r.getString("binding_id"),
        r.getLong("binding_version"),
        r.getString("actor_id"),
        r.getLong("authority_version"),
        r.getString("context_sha256"),
        State.valueOf(r.getString("state")),
        r.getLong("revision"),
        r.getString("reason_code"),
        r.getString("execution_task_id"),
        r.getLong("generation"),
        r.getString("lease_token"),
        r.getObject("lease_until", Long.class),
        r.getInt("attempts"),
        r.getLong("next_attempt_at"),
        r.getLong("expires_at"),
        r.getLong("created_at"),
        r.getLong("updated_at"));
  }

  private View view(Row row) {
    return new View(
        row.id(),
        row.publication(),
        row.version(),
        row.device(),
        row.registration(),
        row.state(),
        row.reason(),
        row.revision(),
        row.task(),
        row.expiresAt(),
        row.createdAt(),
        row.updatedAt());
  }

  private String hash(ManagedAgentBindingStore.VerifiedBindingContext context) {
    try {
      return SecretMaterial.hash(json.writeValueAsString(context));
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Cannot serialize preparation authority");
    }
  }

  private long now() {
    return db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
  }

  private static void canonicalId(String value) {
    try {
      if (value == null || !UUID.fromString(value).toString().equals(value))
        throw DomainException.invalid("INVALID_PREPARATION_REFERENCE");
    } catch (IllegalArgumentException invalid) {
      throw DomainException.invalid("INVALID_PREPARATION_REFERENCE");
    }
  }

  private static void counters(Row row, boolean claiming) {
    if (row.revision() >= MAX_COUNTER || (claiming && row.generation() >= MAX_COUNTER))
      throw conflict("PREPARATION_COUNTER_EXHAUSTED");
  }

  private static void separate(String message) {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException(message);
  }

  private static void requireReadCommitted() {
    if (!TransactionSynchronizationManager.isActualTransactionActive()
        || !Objects.equals(
            TransactionSynchronizationManager.getCurrentTransactionIsolationLevel(),
            TransactionDefinition.ISOLATION_READ_COMMITTED))
      throw new IllegalStateException("Preparation journal requires READ_COMMITTED");
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private static void exactlyOne(int count) {
    if (count != 1)
      throw new IllegalStateException("Preparation checkpoint did not update one request");
  }
}

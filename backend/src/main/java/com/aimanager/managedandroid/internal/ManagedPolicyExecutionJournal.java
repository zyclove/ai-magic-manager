package com.aimanager.managedandroid.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import java.nio.charset.StandardCharsets;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Durable internal execution journal. No HTTP/controller/scheduler or provider call is made here.
 * Admission joins the publication transaction; worker checkpoints commit before external I/O.
 */
@Service
class ManagedPolicyExecutionJournal {
  private static final long MAX_REVISION = 9007199254740990L;
  private static final String DUE_STATES =
      "('READY_TO_WRITE','POLICY_WRITE_UNKNOWN','READY_TO_ASSIGN','ASSIGNMENT_UNKNOWN','WAITING_DEVICE')";
  private final JdbcTemplate db;
  private final ManagedAgentBindingStore bindings;
  private final ManagedExecutionPublicationAccess publications;
  private final TenantAccess access;
  private final AuditService audit;
  private final ManagedPolicyExecutionSettings settings;
  private final TransactionTemplate tx;
  private final ObjectMapper json =
      new ObjectMapper(
              JsonFactory.builder().enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build())
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);

  ManagedPolicyExecutionJournal(
      JdbcTemplate db,
      ManagedAgentBindingStore bindings,
      ManagedExecutionPublicationAccess publications,
      TenantAccess access,
      AuditService audit,
      ManagedPolicyExecutionSettings settings,
      PlatformTransactionManager transactions) {
    this.db = db;
    this.bindings = bindings;
    this.publications = publications;
    this.access = access;
    this.audit = audit;
    this.settings = settings;
    tx = new TransactionTemplate(transactions);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    tx.setTimeout(10);
  }

  enum State {
    READY_TO_WRITE,
    POLICY_WRITE_UNKNOWN,
    READY_TO_ASSIGN,
    ASSIGNMENT_UNKNOWN,
    WAITING_DEVICE,
    APPLIED,
    NEEDS_REVIEW,
    CANCELLED
  }

  enum Action {
    WRITE_POLICY,
    ASSIGN_POLICY,
    READ_POLICY,
    READ_DEVICE
  }

  enum Reason {
    QUEUED,
    CLAIMED,
    WRITE_DISPATCHED,
    ASSIGN_DISPATCHED,
    POLICY_CONFIRMED,
    ASSIGNMENT_CONFIRMED,
    DEVICE_PENDING,
    DEVICE_NON_COMPLIANT,
    DEVICE_APPLIED,
    MANUAL_DEVICE_RECHECK_REQUESTED,
    WRITE_OUTCOME_UNKNOWN,
    ASSIGNMENT_OUTCOME_UNKNOWN,
    READ_FAILED,
    RECONCILIATION_REQUIRES_REVIEW,
    DEADLINE_EXCEEDED,
    ATTEMPTS_EXHAUSTED,
    CANCELLED_BEFORE_ASSIGNMENT,
    CANCELLATION_REQUIRES_REVIEW,
    CONTEXT_CHANGED
  }

  record View(
      String id,
      String publicationId,
      String deviceId,
      String registrationId,
      State state,
      Reason reason,
      long revision,
      long createdAt,
      long updatedAt,
      boolean cancellationRequested) {}

  /** Internal only. Credentials and remote resource names must never enter ordinary UI/logging. */
  record Claim(
      String tenantId,
      String taskId,
      String token,
      long generation,
      Action action,
      long leaseUntil,
      String enterpriseId,
      String deviceId,
      String policyId,
      Long policyVersion,
      String documentJson,
      String documentSha256) {
    @Override
    public String toString() {
      return "ManagedExecutionClaim[REDACTED]";
    }
  }

  /** Server-owned task facts for preparation; no ownership proof or remote-write permission. */
  record WritePreparationTarget(
      Claim claim,
      String publicationId,
      long expiresAt,
      ManagedAgentBindingStore.VerifiedBindingContext binding,
      ManagedExecutionPublicationAccess.Publication publication) {
    @Override
    public String toString() {
      return "ManagedWritePreparationTarget[REDACTED]";
    }
  }

  private record Row(
      String tenant,
      String id,
      String publication,
      String versionId,
      String subject,
      String device,
      String registration,
      String binding,
      long bindingVersion,
      String actor,
      long authorityVersion,
      String contextHash,
      String document,
      String documentHash,
      String provider,
      String enterprise,
      String providerDevice,
      String policy,
      Long providerVersion,
      State state,
      long generation,
      long revision,
      String token,
      Long leaseUntil,
      Action action,
      int attempts,
      long nextAt,
      long expiresAt,
      boolean cancelled,
      Reason reason,
      long createdAt,
      long updatedAt) {}

  /**
   * Caller supplies a server-generated, versioned complete adapter document, never a child payload.
   * This validates provenance and freezes bytes, not provider support or remote resource ownership.
   */
  View enqueue(
      String tenant,
      String actor,
      String publication,
      String binding,
      long bindingVersion,
      String desiredDocument,
      long expiresAt) {
    return enqueue(
        tenant, actor, publication, binding, bindingVersion, desiredDocument, expiresAt, null);
  }

  /** Joins the handoff transaction: task, request association and both audits commit together. */
  View enqueuePrepared(
      ManagedPreparationRequestJournal.Claim claim,
      ManagedAndroidGateway.PolicyDocument document,
      long expiresAt) {
    requireReadCommitted();
    if (!TransactionSynchronizationManager.isActualTransactionActive()
        || claim == null
        || claim.binding() == null
        || document == null) throw conflict("PREPARATION_HANDOFF_STALE");
    var binding = claim.binding();
    if (!Objects.equals(claim.tenantId(), binding.tenantId())
        || !Objects.equals(document.agentPackage(), binding.agentPackageName())
        || !Objects.equals(document.managementMode(), binding.managementMode())
        || document.apiLevel() < 30
        || document.documentJson() == null
        || !Objects.equals(document.sha256(), SecretMaterial.hash(document.documentJson())))
      throw conflict("PREPARATION_RESULT_CHANGED");
    canonicalId(claim.requestId());
    return enqueue(
        binding.tenantId(),
        binding.actorId(),
        claim.publicationId(),
        binding.bindingId(),
        binding.bindingVersion(),
        document.documentJson(),
        expiresAt,
        claim);
  }

  private View enqueue(
      String tenant,
      String actor,
      String publication,
      String binding,
      long bindingVersion,
      String desiredDocument,
      long expiresAt,
      ManagedPreparationRequestJournal.Claim preparation) {
    canonicalId(publication);
    canonicalId(binding);
    String document = canonicalDocument(desiredDocument);
    return tx.execute(
        status -> {
          requireReadCommitted();
          var context = bindings.requireVerifiedContext(tenant, actor, binding, bindingVersion);
          var source =
              publications.requireTarget(
                  tenant, actor, publication, context.deviceId(), context.registrationId());
          String hash = SecretMaterial.hash(document), contextHash = contextHash(context);
          if (preparation != null)
            requirePreparation(preparation, context, source.versionId(), contextHash, expiresAt);
          var previous =
              db.query(
                  "SELECT * FROM managed_policy_execution_tasks WHERE tenant_id=?"
                      + " AND publication_id=? AND device_id=? FOR UPDATE",
                  this::row,
                  tenant,
                  publication,
                  context.deviceId());
          if (!previous.isEmpty()) {
            if (preparation != null) throw conflict("PREPARATION_HANDOFF_STALE");
            var old = previous.get(0);
            if (!old.documentHash().equals(hash)
                || !old.document().equals(document)
                || !old.contextHash().equals(contextHash)
                || !old.versionId().equals(source.versionId())
                || old.expiresAt() != expiresAt) throw conflict("EXECUTION_REQUEST_REUSED");
            return view(old);
          }
          long now = now();
          if (expiresAt <= now || expiresAt > now + 86_400_000L)
            throw DomainException.invalid("INVALID_EXECUTION_DEADLINE");
          // Preparation and execution share the device slot under the binding/domain locks. A
          // Only the validated lease owner may transfer its own preparation slot.
          if (preparation == null
              && !db.queryForList(
                      "SELECT id FROM managed_policy_preparation_requests WHERE tenant_id=?"
                          + " AND active_device_id=? FOR UPDATE",
                      tenant,
                      context.deviceId())
                  .isEmpty()) throw conflict("EXECUTION_DEVICE_BUSY");
          if (!db.queryForList(
                  "SELECT id FROM managed_policy_execution_tasks WHERE tenant_id=?"
                      + " AND active_device_id=? FOR UPDATE",
                  tenant,
                  context.deviceId())
              .isEmpty()) throw conflict("EXECUTION_DEVICE_BUSY");
          // Binding/device authority locks serialize admission; the unique slot also protects
          // replicas.
          if (db.queryForObject(
                  "SELECT COUNT(*) FROM managed_policy_execution_tasks WHERE tenant_id=?"
                      + " AND binding_id=?",
                  Long.class,
                  tenant,
                  binding)
              >= 100) throw conflict("EXECUTION_BINDING_HISTORY_LIMIT");
          String id = UUID.randomUUID().toString(),
              policy = "aim_" + UUID.randomUUID().toString().replace("-", "");
          db.update(
              "INSERT INTO"
                  + " managed_policy_execution_tasks(tenant_id,id,publication_id,policy_version_id,"
                  + "subject_id,device_id,registration_id,binding_id,binding_version,actor_id,authority_version,"
                  + "context_sha256,document_json,document_sha256,provider,enterprise_id,provider_device_id,provider_policy_id,"
                  + "state,active_device_id,next_attempt_at,expires_at,reason_code,created_at,updated_at)"
                  + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'READY_TO_WRITE',?,?,?,'QUEUED',?,?)",
              tenant,
              id,
              publication,
              source.versionId(),
              context.subjectId(),
              context.deviceId(),
              context.registrationId(),
              binding,
              bindingVersion,
              actor,
              context.authorityVersion(),
              contextHash,
              document,
              hash,
              context.provider(),
              context.enterpriseId(),
              context.providerDeviceId(),
              policy,
              context.deviceId(),
              now,
              expiresAt,
              now,
              now);
          var added = required(tenant, id, false);
          event(added, null, actor);
          if (preparation != null) {
            long admittedAt = now();
            exactlyOne(
                db.update(
                    "UPDATE managed_policy_preparation_requests SET state='ADMITTED',"
                        + "reason_code='EXECUTION_ADMITTED',execution_task_id=?,revision=revision+1,"
                        + "lease_token=NULL,lease_until=NULL,active_device_id=NULL,updated_at=?"
                        + " WHERE tenant_id=? AND id=? AND state='PENDING' AND revision=? AND"
                        + " generation=? AND lease_token=? AND lease_until=? AND lease_until>? AND"
                        + " expires_at>?",
                    id,
                    admittedAt,
                    tenant,
                    preparation.requestId(),
                    preparation.revision(),
                    preparation.generation(),
                    preparation.token(),
                    preparation.leaseUntil(),
                    admittedAt,
                    admittedAt));
            if (expiresAt <= now()) throw conflict("PREPARATION_HANDOFF_EXPIRED");
            audit.record(tenant, actor, "PREPARATION_ADMITTED", preparation.requestId());
          }
          return view(added);
        });
  }

  /** Domain locks precede this request lock; the execution slot is locked only afterwards. */
  private void requirePreparation(
      ManagedPreparationRequestJournal.Claim claim,
      ManagedAgentBindingStore.VerifiedBindingContext context,
      String version,
      String contextHash,
      long expiresAt) {
    if (!context.equals(claim.binding()) || claim.revision() >= MAX_REVISION)
      throw conflict("PREPARATION_HANDOFF_STALE");
    long observedAt = now();
    var matches =
        db.queryForList(
            "SELECT id FROM managed_policy_preparation_requests WHERE tenant_id=? AND id=?"
                + " AND publication_id=? AND policy_version_id=? AND subject_id=? AND device_id=?"
                + " AND registration_id=? AND binding_id=? AND binding_version=? AND actor_id=?"
                + " AND authority_version=? AND context_sha256=? AND state='PENDING'"
                + " AND active_device_id=? AND execution_task_id IS NULL AND revision=?"
                + " AND generation=? AND lease_token=? AND lease_until=? AND lease_until>?"
                + " AND expires_at>? AND expires_at>=? FOR UPDATE",
            claim.tenantId(),
            claim.requestId(),
            claim.publicationId(),
            version,
            context.subjectId(),
            context.deviceId(),
            context.registrationId(),
            context.bindingId(),
            context.bindingVersion(),
            context.actorId(),
            context.authorityVersion(),
            contextHash,
            context.deviceId(),
            claim.revision(),
            claim.generation(),
            claim.token(),
            claim.leaseUntil(),
            observedAt,
            observedAt,
            expiresAt);
    if (matches.size() != 1) throw conflict("PREPARATION_HANDOFF_STALE");
  }

  /** Only dispatchable writes: observation workers retain their own lease/attempt budgets. */
  List<Claim> claimWriteActions(String provider, int limit) {
    return claimDue(provider, limit, ClaimSelection.WRITES);
  }

  /**
   * Local terminal convergence, independent of provider availability. Expiry takes priority over
   * attempt exhaustion, followed by an uncertain policy write whose live lease has ended. Such a
   * write requires review: it never becomes another runnable write, a fabricated receipt, or an
   * automatically released device slot. This method performs no provider I/O.
   */
  int settleUnrunnableTasks(int limit) {
    workerBoundary();
    if (limit < 1 || limit > 25)
      throw new IllegalArgumentException("Invalid execution settlement limit");
    return tx.execute(
        status -> {
          requireReadCommitted();
          long observedAt = now();
          var selected =
              new ArrayList<>(
                  db.query(
                      "SELECT tenant_id,id FROM managed_policy_execution_tasks WHERE state IN "
                          + DUE_STATES
                          + " AND expires_at<=? ORDER BY expires_at,id,tenant_id LIMIT ?",
                      (row, index) -> new TaskReference(row.getString(1), row.getString(2)),
                      observedAt,
                      limit));
          int remaining = limit - selected.size();
          if (remaining > 0)
            selected.addAll(
                db.query(
                    "SELECT tenant_id,id FROM managed_policy_execution_tasks WHERE state IN "
                        + DUE_STATES
                        + " AND expires_at>? AND attempts>=? AND (lease_until IS NULL OR"
                        + " lease_until<=?) ORDER BY attempts,id,tenant_id LIMIT ?",
                    (row, index) -> new TaskReference(row.getString(1), row.getString(2)),
                    observedAt,
                    settings.maximumAttempts(),
                    observedAt,
                    remaining));
          remaining = limit - selected.size();
          if (remaining > 0)
            selected.addAll(
                db.query(
                    "SELECT tenant_id,id FROM managed_policy_execution_tasks WHERE"
                        + " state='POLICY_WRITE_UNKNOWN' AND expires_at>? AND attempts<? AND"
                        + " (lease_until IS NULL OR lease_until<=?) ORDER BY"
                        + " lease_until,id,tenant_id LIMIT ?",
                    (row, index) -> new TaskReference(row.getString(1), row.getString(2)),
                    observedAt,
                    settings.maximumAttempts(),
                    observedAt,
                    remaining));
          // Priority chooses the bounded set; a common lock order reduces cross-replica deadlocks.
          selected.sort(
              Comparator.comparing(TaskReference::tenant).thenComparing(TaskReference::id));
          int settled = 0;
          for (var reference : selected) {
            var locked =
                db.query(
                    "SELECT * FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=? FOR"
                        + " UPDATE",
                    this::row,
                    reference.tenant(),
                    reference.id());
            // A concurrent terminal transition and retention pass may remove a previously selected
            // row.
            if (locked.isEmpty()) continue;
            var current = locked.get(0);
            long checkedAt = now();
            Reason reason = settlementReason(current, checkedAt);
            if (reason == null) continue;
            finish(
                current,
                neverAssigned(current) ? State.CANCELLED : State.NEEDS_REVIEW,
                current.providerVersion(),
                reason,
                checkedAt);
            settled++;
          }
          return settled;
        });
  }

  private record TaskReference(String tenant, String id) {}

  private Reason settlementReason(Row current, long observedAt) {
    if (current.state() == State.APPLIED
        || current.state() == State.CANCELLED
        || current.state() == State.NEEDS_REVIEW) return null;
    if (current.expiresAt() <= observedAt) return Reason.DEADLINE_EXCEEDED;
    if (current.leaseUntil() != null && current.leaseUntil() > observedAt) return null;
    if (current.attempts() >= settings.maximumAttempts()) return Reason.ATTEMPTS_EXHAUSTED;
    return current.state() == State.POLICY_WRITE_UNKNOWN ? Reason.WRITE_OUTCOME_UNKNOWN : null;
  }

  /** Select at most 25 due tasks. All leases use database time shared by backend replicas. */
  List<Claim> claimDue(String provider, int limit) {
    return claimDue(provider, limit, ClaimSelection.ALL);
  }

  /** Only device observations: never leases or consumes attempts for pending provider writes. */
  List<Claim> claimDeviceObservations(String provider, int limit) {
    return claimDue(provider, limit, ClaimSelection.DEVICE_OBSERVATIONS);
  }

  private enum ClaimSelection {
    ALL(DUE_STATES),
    WRITES("('READY_TO_WRITE','READY_TO_ASSIGN')"),
    DEVICE_OBSERVATIONS("('ASSIGNMENT_UNKNOWN','WAITING_DEVICE')");

    private final String sqlStates;

    ClaimSelection(String sqlStates) {
      this.sqlStates = sqlStates;
    }

    boolean accepts(State state) {
      return switch (this) {
        case ALL -> true;
        case WRITES -> state == State.READY_TO_WRITE || state == State.READY_TO_ASSIGN;
        case DEVICE_OBSERVATIONS ->
            state == State.ASSIGNMENT_UNKNOWN || state == State.WAITING_DEVICE;
      };
    }
  }

  private List<Claim> claimDue(String provider, int limit, ClaimSelection selection) {
    workerBoundary();
    if (provider == null || !provider.matches("[A-Z][A-Z0-9_]{2,31}") || limit < 1 || limit > 25)
      throw new IllegalArgumentException("Invalid execution claim selection");
    return tx.execute(
        status -> {
          long now = now();
          var candidates =
              db.query(
                  "SELECT * FROM managed_policy_execution_tasks WHERE provider=?"
                      + " AND state IN "
                      + selection.sqlStates
                      + " AND next_attempt_at<=? AND (lease_until IS NULL OR lease_until<=?)"
                      + " ORDER BY next_attempt_at,id LIMIT ?",
                  this::row,
                  provider,
                  now,
                  now,
                  limit);
          var claims = new ArrayList<Claim>();
          for (var before : candidates) {
            var current = required(before.tenant(), before.id(), true);
            if (!due(current, now) || !current.provider().equals(provider)) continue;
            // Recheck after locking: selection and ownership can race between replicas.
            if (!selection.accepts(current.state())) continue;
            if (current.expiresAt() <= now || current.attempts() >= settings.maximumAttempts()) {
              finish(
                  current,
                  neverAssigned(current) ? State.CANCELLED : State.NEEDS_REVIEW,
                  current.providerVersion(),
                  current.expiresAt() <= now ? Reason.DEADLINE_EXCEEDED : Reason.ATTEMPTS_EXHAUSTED,
                  now);
              continue;
            }
            if (current.generation() >= MAX_REVISION || current.revision() >= MAX_REVISION)
              throw conflict("EXECUTION_VERSION_EXHAUSTED");
            String token = UUID.randomUUID().toString();
            Action action = action(current.state());
            long until = Math.min(current.expiresAt(), now + settings.leaseMillis());
            exactlyOne(
                db.update(
                    "UPDATE managed_policy_execution_tasks SET"
                        + " generation=generation+1,revision=revision+1,"
                        + "lease_token=?,lease_until=?,action=?,attempts=attempts+1,reason_code='CLAIMED',updated_at=?"
                        + " WHERE tenant_id=? AND id=? AND revision=?",
                    token,
                    until,
                    action.name(),
                    now,
                    current.tenant(),
                    current.id(),
                    current.revision()));
            var claimed = required(current.tenant(), current.id(), false);
            event(claimed, action, "system:managed-execution");
            claims.add(claim(claimed));
          }
          return List.copyOf(claims);
        });
  }

  /** Short preflight only; the eventual observation repeats ownership checks after remote I/O. */
  boolean deviceObservationCurrent(Claim claim) {
    workerBoundary();
    if (claim.action() != Action.READ_DEVICE)
      throw new IllegalArgumentException("Expected a device observation claim");
    return withDeviceObservationAuthority(claim, current -> true);
  }

  /**
   * Recheck authority both before remote reads (including after queueing) and before accepting a
   * receipt. Binding/publication locks precede the task lock, matching admission and write
   * dispatch. Domain rejection rolls back the entire validation transaction before a separate
   * lease-fenced checkpoint parks the uncertain assignment for review. In particular, a nested
   * MANDATORY rejection must not turn this checkpoint into an UnexpectedRollbackException.
   */
  private boolean withDeviceObservationAuthority(
      Claim claim, java.util.function.Function<Row, Boolean> accepted) {
    try {
      return tx.execute(
          status -> {
            requireReadCommitted();
            var before = required(claim.tenantId(), claim.taskId(), false);
            if (!currentDeviceObservation(before, claim)) return false;
            var context =
                bindings.requireVerifiedContext(
                    before.tenant(), before.actor(), before.binding(), before.bindingVersion());
            var publication =
                publications.requireTarget(
                    before.tenant(),
                    before.actor(),
                    before.publication(),
                    before.device(),
                    before.registration());
            var current = required(claim.tenantId(), claim.taskId(), true);
            if (!currentDeviceObservation(current, claim)) return false;
            if (!current.contextHash().equals(contextHash(context))
                || !current.versionId().equals(publication.versionId()))
              throw conflict("EXECUTION_CONTEXT_CHANGED");
            return accepted.apply(current);
          });
    } catch (DomainException rejected) {
      // A restored permission cannot revive this read. Keep the device slot until explicit review;
      // a cancelled, expired or superseded lease must never overwrite a newer worker's outcome.
      return tx.execute(
          status -> {
            var current = required(claim.tenantId(), claim.taskId(), true);
            if (currentDeviceObservation(current, claim))
              finish(
                  current,
                  State.NEEDS_REVIEW,
                  current.providerVersion(),
                  Reason.CONTEXT_CHANGED,
                  now());
            return false;
          });
    }
  }

  private boolean currentDeviceObservation(Row current, Claim claim) {
    return claim.action() == Action.READ_DEVICE
        && owns(current, claim)
        && !current.cancelled()
        && deviceObservationState(current.state());
  }

  private boolean deviceObservationState(State state) {
    return state == State.ASSIGNMENT_UNKNOWN || state == State.WAITING_DEVICE;
  }

  /**
   * Recover authoritative inputs from a current write lease without advancing it. Authority locks
   * precede the task lock, matching admission and cancellation. Provider calls belong outside this
   * transaction; the caller must obtain another target after those calls and compare the results.
   */
  WritePreparationTarget writePreparationTarget(Claim claim) {
    return writeTarget(claim, false);
  }

  /** Revalidates authority after dispatch; UNKNOWN is not permission to dispatch a second time. */
  WritePreparationTarget dispatchedTarget(Claim claim) {
    return writeTarget(claim, true);
  }

  private WritePreparationTarget writeTarget(Claim claim, boolean dispatched) {
    workerBoundary();
    if (claim == null
        || (claim.action() != Action.WRITE_POLICY && claim.action() != Action.ASSIGN_POLICY))
      throw new IllegalArgumentException("Expected a write preparation claim");
    return tx.execute(
        status -> {
          requireReadCommitted();
          var before = required(claim.tenantId(), claim.taskId(), false);
          var context =
              bindings.requireVerifiedContext(
                  before.tenant(), before.actor(), before.binding(), before.bindingVersion());
          var publication =
              publications.requireTarget(
                  before.tenant(),
                  before.actor(),
                  before.publication(),
                  before.device(),
                  before.registration());
          var current = required(claim.tenantId(), claim.taskId(), true);
          if (!current.contextHash().equals(contextHash(context))
              || !current.versionId().equals(publication.versionId()))
            throw conflict("EXECUTION_CONTEXT_CHANGED");
          State expected =
              dispatched
                  ? (claim.action() == Action.WRITE_POLICY
                      ? State.POLICY_WRITE_UNKNOWN
                      : State.ASSIGNMENT_UNKNOWN)
                  : (claim.action() == Action.WRITE_POLICY
                      ? State.READY_TO_WRITE
                      : State.READY_TO_ASSIGN);
          if (!owns(current, claim) || current.cancelled() || current.state() != expected)
            throw conflict("EXECUTION_PREPARATION_STALE");
          return new WritePreparationTarget(
              claim(current), current.publication(), current.expiresAt(), context, publication);
        });
  }

  /** Commit uncertainty BEFORE a network write. A claim alone never authorizes external I/O. */
  boolean beforeWrite(WritePreparationTarget target, long evidenceDeadline) {
    workerBoundary();
    if (target == null || target.claim() == null)
      throw new IllegalArgumentException("Expected a complete write preparation target");
    var claim = target.claim();
    if (claim.action() != Action.WRITE_POLICY && claim.action() != Action.ASSIGN_POLICY)
      throw new IllegalArgumentException("Expected a write claim");
    return tx.execute(
        status -> {
          requireReadCommitted();
          // Authority locks precede the task lock, matching admission and cancellation lock order.
          var before = required(claim.tenantId(), claim.taskId(), false);
          var context =
              bindings.requireVerifiedContext(
                  before.tenant(), before.actor(), before.binding(), before.bindingVersion());
          var publication =
              publications.requireTarget(
                  before.tenant(),
                  before.actor(),
                  before.publication(),
                  before.device(),
                  before.registration());
          if (!before.contextHash().equals(contextHash(context))
              || !before.versionId().equals(publication.versionId()))
            throw conflict("EXECUTION_CONTEXT_CHANGED");
          var current = required(claim.tenantId(), claim.taskId(), true);
          if (!owns(current, claim) || current.cancelled()) return false;
          State expected =
              claim.action() == Action.WRITE_POLICY ? State.READY_TO_WRITE : State.READY_TO_ASSIGN;
          if (current.state() != expected) return false;
          // Compare every prepared fact under authority/task locks. Database time matches leases
          // across replicas; a longer caller deadline cannot extend the current lease.
          var actual =
              new WritePreparationTarget(
                  claim(current), current.publication(), current.expiresAt(), context, publication);
          if (!actual.equals(target) || now() >= evidenceDeadline) return false;
          State next =
              claim.action() == Action.WRITE_POLICY
                  ? State.POLICY_WRITE_UNKNOWN
                  : State.ASSIGNMENT_UNKNOWN;
          Reason reason =
              claim.action() == Action.WRITE_POLICY
                  ? Reason.WRITE_DISPATCHED
                  : Reason.ASSIGN_DISPATCHED;
          update(
              current, next, current.providerVersion(), reason, now(), false, current.cancelled());
          return true;
        });
  }

  boolean policyWritten(Claim claim, ManagedAndroidGateway.PolicyReceipt receipt) {
    workerBoundary();
    return tx.execute(
        status -> {
          var current = required(claim.tenantId(), claim.taskId(), true);
          if (!owns(current, claim)
              || claim.action() != Action.WRITE_POLICY
              || current.state() != State.POLICY_WRITE_UNKNOWN) return false;
          if (receipt == null
              || !policyName(current).equals(receipt.policyName())
              || receipt.providerVersion() == null
              || receipt.providerVersion() < 1)
            throw new IllegalArgumentException("Invalid verified policy receipt");
          finish(
              current,
              State.READY_TO_ASSIGN,
              receipt.providerVersion(),
              Reason.POLICY_CONFIRMED,
              now());
          return true;
        });
  }

  boolean assignmentAccepted(Claim claim, ManagedAndroidGateway.AssignmentReceipt receipt) {
    workerBoundary();
    return tx.execute(
        status -> {
          var current = required(claim.tenantId(), claim.taskId(), true);
          if (!owns(current, claim)
              || claim.action() != Action.ASSIGN_POLICY
              || current.state() != State.ASSIGNMENT_UNKNOWN) return false;
          if (receipt == null
              || !deviceName(current).equals(receipt.deviceName())
              || !policyName(current).equals(receipt.requestedPolicyName()))
            throw new IllegalArgumentException("Invalid verified assignment receipt");
          finish(
              current,
              State.WAITING_DEVICE,
              current.providerVersion(),
              Reason.ASSIGNMENT_CONFIRMED,
              now());
          return true;
        });
  }

  /** Content-only MATCHED is deliberately insufficient to attribute an uncertain policy write. */
  boolean policyObserved(
      Claim claim, ManagedAndroidGateway.ApplicationPolicyInspection observation) {
    workerBoundary();
    return tx.execute(
        status -> {
          var current = required(claim.tenantId(), claim.taskId(), true);
          if (!owns(current, claim)
              || claim.action() != Action.READ_POLICY
              || current.state() != State.POLICY_WRITE_UNKNOWN) return false;
          if (observation == null
              || !policyName(current).equals(observation.policyName())
              || observation.state() == null)
            throw new IllegalArgumentException("Invalid policy observation");
          finish(
              current,
              State.NEEDS_REVIEW,
              current.providerVersion(),
              Reason.RECONCILIATION_REQUIRES_REVIEW,
              now());
          return true;
        });
  }

  /**
   * Records a whole-document observation after an uncertain write. Even an exact match does not
   * attribute that write to this task or prove exclusive policy ownership, so recovery stops for
   * review. Observed versions never replace the missing write receipt.
   */
  boolean completePolicyObserved(
      Claim claim, ManagedAndroidGateway.CompletePolicyInspection observation) {
    workerBoundary();
    return tx.execute(
        status -> {
          var current = required(claim.tenantId(), claim.taskId(), true);
          if (!owns(current, claim)
              || claim.action() != Action.READ_POLICY
              || current.state() != State.POLICY_WRITE_UNKNOWN) return false;
          if (observation == null
              || !policyName(current).equals(observation.policyName())
              || observation.state() == null)
            throw new IllegalArgumentException("Invalid complete policy observation");
          boolean validVersion =
              switch (observation.state()) {
                case NOT_FOUND -> observation.providerVersion() == null;
                case MATCHED, CONTENT_MISMATCH, VERSION_MISMATCH ->
                    observation.providerVersion() != null && observation.providerVersion() > 0;
              };
          if (!validVersion)
            throw new IllegalArgumentException("Invalid complete policy observation");
          finish(
              current,
              State.NEEDS_REVIEW,
              current.providerVersion(),
              Reason.RECONCILIATION_REQUIRES_REVIEW,
              now());
          return true;
        });
  }

  boolean deviceObserved(Claim claim, ManagedAndroidGateway.ManagedDeviceState observed) {
    workerBoundary();
    return withDeviceObservationAuthority(
        claim,
        current -> {
          if (observed == null
              || !deviceName(current).equals(observed.deviceName())
              || observed.state() == null
              || observed.nonComplianceReasons() == null)
            throw new IllegalArgumentException("Invalid verified device observation");
          String policy = policyName(current);
          boolean exact =
              policy.equals(observed.requestedPolicyName())
                  && policy.equals(observed.appliedPolicyName())
                  && current.providerVersion() != null
                  && current.providerVersion().equals(observed.appliedPolicyVersion());
          if (exact
              && observed.state() == ManagedAndroidGateway.ApplyState.APPLIED
              && "DEVICE_OWNER".equals(observed.managementMode())
              && observed.nonComplianceReasons() != null
              && observed.nonComplianceReasons().isEmpty())
            finish(current, State.APPLIED, current.providerVersion(), Reason.DEVICE_APPLIED, now());
          else if (current.state() == State.ASSIGNMENT_UNKNOWN
              && !policy.equals(observed.requestedPolicyName()))
            finish(
                current,
                State.NEEDS_REVIEW,
                current.providerVersion(),
                Reason.RECONCILIATION_REQUIRES_REVIEW,
                now());
          else
            defer(
                current,
                State.WAITING_DEVICE,
                observed.state() == ManagedAndroidGateway.ApplyState.NON_COMPLIANT
                    ? Reason.DEVICE_NON_COMPLIANT
                    : Reason.DEVICE_PENDING);
          return true;
        });
  }

  /** Never rewinds an uncertain write into a runnable write state. */
  boolean failed(Claim claim) {
    workerBoundary();
    return tx.execute(
        status -> {
          var current = required(claim.tenantId(), claim.taskId(), true);
          if (!owns(current, claim)) return false;
          if (claim.action() == Action.WRITE_POLICY && current.state() == State.READY_TO_WRITE
              || claim.action() == Action.ASSIGN_POLICY && current.state() == State.READY_TO_ASSIGN)
            finish(
                current, State.CANCELLED, current.providerVersion(), Reason.CONTEXT_CHANGED, now());
          else
            defer(
                current,
                current.state(),
                claim.action() == Action.WRITE_POLICY
                    ? Reason.WRITE_OUTCOME_UNKNOWN
                    : claim.action() == Action.ASSIGN_POLICY
                        ? Reason.ASSIGNMENT_OUTCOME_UNKNOWN
                        : Reason.READ_FAILED);
          return true;
        });
  }

  /**
   * A caller-facing service must also require recent authentication before invoking cancellation.
   */
  View cancel(String tenant, String actor, String id, long expectedRevision) {
    canonicalId(id);
    return tx.execute(
        status -> {
          access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
          var current = required(tenant, id, true);
          // Check under the same row lock, including already-cancelled tasks. Stale retries are not
          // new consent.
          ResourceVersions.check(expectedRevision, current.revision());
          if (current.cancelled() || current.state() == State.CANCELLED) return view(current);
          if (current.state() == State.APPLIED)
            throw conflict("EXECUTION_ALREADY_APPLIED_USE_NEW_POLICY");
          boolean beforeAssignment = neverAssigned(current);
          update(
              current,
              beforeAssignment ? State.CANCELLED : State.NEEDS_REVIEW,
              current.providerVersion(),
              beforeAssignment
                  ? Reason.CANCELLED_BEFORE_ASSIGNMENT
                  : Reason.CANCELLATION_REQUIRES_REVIEW,
              now(),
              true,
              true);
          audit.record(tenant, actor, "MANAGED_EXECUTION_CANCEL_REQUESTED", id);
          return view(required(tenant, id, false));
        });
  }

  enum ReviewReason {
    ELIGIBLE,
    ADMINISTRATOR_REQUIRED,
    EXECUTION_RECHECK_REQUIRES_REVIEW,
    EXECUTION_RECHECK_CANCELLED,
    EXECUTION_RECHECK_REQUIRES_POLICY_RECEIPT,
    EXECUTION_RECHECK_UNAVAILABLE,
    EXECUTION_CONTEXT_CHANGED,
    EXECUTION_RECHECK_LEASE_ACTIVE,
    EXECUTION_RECHECK_WINDOW_CLOSED,
    EXECUTION_VERSION_EXHAUSTED
  }

  /** Deliberately excludes provider versions, remote resource names and original actor details. */
  record ReviewEligibility(
      String id,
      String publicationId,
      String deviceId,
      String registrationId,
      long revision,
      boolean allowed,
      ReviewReason reason) {}

  private record ReviewCandidate(Row row, DomainException contextFailure) {}

  /** Read-only permission preflight. The eventual write repeats authorization under locks. */
  void requireReviewAdministrator(String tenant, String actor, String id) {
    canonicalId(id);
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
    required(tenant, id, false);
  }

  /**
   * A current, non-cached explanation rather than an authorization token. This method takes short
   * authority/task locks but does not alter counters, leases, audit rows or task events.
   */
  ReviewEligibility reviewEligibility(
      String tenant, String actor, String id, boolean available, String provider) {
    canonicalId(id);
    return tx.execute(
        status -> {
          requireReadCommitted();
          var grant = access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
          var current = required(tenant, id, false);
          if (grant.role() == AUDITOR)
            return eligibility(current, ReviewReason.ADMINISTRATOR_REQUIRED);
          if (!available) return eligibility(current, ReviewReason.EXECUTION_RECHECK_UNAVAILABLE);
          try {
            var candidate = reviewCandidate(tenant, actor, id);
            // A nested Spring domain read may have marked the transaction rollback-only. This
            // projection writes nothing: explicitly roll back the rejected read instead of
            // attempting
            // a successful commit and turning the expected denial into UnexpectedRollbackException.
            if (candidate.contextFailure() != null) status.setRollbackOnly();
            return eligibility(candidate.row(), reviewReason(candidate, provider, now()));
          } catch (DomainException authorityFailure) {
            // The original publisher may have lost authority. Recheck the requesting administrator
            // under a write lock: their own revocation must still be a 403, not a successful
            // projection.
            access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
            status.setRollbackOnly();
            return eligibility(required(tenant, id, true), ReviewReason.EXECUTION_CONTEXT_CHANGED);
          }
        });
  }

  /**
   * Starts another read-only observation round under fresh administrative consent. The original
   * task expiry and policy receipt are immutable here; unresolved/cancelled writes cannot be
   * retried. A caller-facing service must require recent authentication and an available read
   * consumer.
   */
  View requestDeviceRecheck(
      String tenant, String actor, String id, long expectedRevision, String provider) {
    canonicalId(id);
    return tx.execute(
        status -> {
          requireReadCommitted();
          access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
          var candidate = reviewCandidate(tenant, actor, id);
          var current = candidate.row();
          ResourceVersions.check(expectedRevision, current.revision());
          long observedAt = now();
          var reason = reviewReason(candidate, provider, observedAt);
          if (reason != ReviewReason.ELIGIBLE) {
            // Preserve meaningful write-side authority failures while the projection only exposes a
            // stable context-change reason. Both paths still use the same eligibility decision.
            if (reason == ReviewReason.EXECUTION_CONTEXT_CHANGED
                && candidate.contextFailure() != null) throw candidate.contextFailure();
            throw conflict(reason.name());
          }
          // A new claim gets a fresh generation/token. Reset and state/audit/event changes are
          // atomic.
          exactlyOne(
              db.update(
                  "UPDATE managed_policy_execution_tasks SET attempts=0 WHERE tenant_id=? AND id=?"
                      + " AND revision=?",
                  tenant,
                  id,
                  current.revision()));
          update(
              current,
              State.WAITING_DEVICE,
              current.providerVersion(),
              Reason.MANUAL_DEVICE_RECHECK_REQUESTED,
              observedAt,
              true,
              false);
          audit.record(tenant, actor, "MANAGED_EXECUTION_DEVICE_RECHECK_REQUESTED", id);
          return view(required(tenant, id, false));
        });
  }

  /** Stable membership order precedes the existing binding/publication -> task lock order. */
  private ReviewCandidate reviewCandidate(String tenant, String actor, String id) {
    var before = required(tenant, id, false);
    access.requireWriteRoles(tenant, List.of(actor, before.actor()), OWNER, ORG_ADMIN);
    ManagedAgentBindingStore.VerifiedBindingContext context = null;
    ManagedExecutionPublicationAccess.Publication publication = null;
    DomainException contextFailure = null;
    try {
      context =
          bindings.requireVerifiedContext(
              tenant, before.actor(), before.binding(), before.bindingVersion());
      publication =
          publications.requireTarget(
              tenant, before.actor(), before.publication(), before.device(), before.registration());
    } catch (DomainException changed) {
      // Only expected domain rejections are converted. Infrastructure errors must remain failures.
      contextFailure = changed;
    }
    var current = required(tenant, id, true);
    if (contextFailure == null
        && (!current.contextHash().equals(contextHash(context))
            || !current.versionId().equals(publication.versionId())))
      contextFailure = conflict("EXECUTION_CONTEXT_CHANGED");
    return new ReviewCandidate(current, contextFailure);
  }

  /** One ordered predicate shared by the explanation and the atomic write-side recheck. */
  private ReviewReason reviewReason(ReviewCandidate candidate, String provider, long observedAt) {
    var current = candidate.row();
    if (current.state() != State.NEEDS_REVIEW)
      return ReviewReason.EXECUTION_RECHECK_REQUIRES_REVIEW;
    if (current.cancelled()) return ReviewReason.EXECUTION_RECHECK_CANCELLED;
    if (current.providerVersion() == null || current.providerVersion() < 1)
      return ReviewReason.EXECUTION_RECHECK_REQUIRES_POLICY_RECEIPT;
    if (!Objects.equals(provider, current.provider()))
      return ReviewReason.EXECUTION_RECHECK_UNAVAILABLE;
    if (candidate.contextFailure() != null) return ReviewReason.EXECUTION_CONTEXT_CHANGED;
    if (current.leaseUntil() != null && current.leaseUntil() > observedAt)
      return ReviewReason.EXECUTION_RECHECK_LEASE_ACTIVE;
    if (current.expiresAt() - observedAt < settings.leaseMillis())
      return ReviewReason.EXECUTION_RECHECK_WINDOW_CLOSED;
    if (current.generation() >= MAX_REVISION || current.revision() >= MAX_REVISION)
      return ReviewReason.EXECUTION_VERSION_EXHAUSTED;
    return ReviewReason.ELIGIBLE;
  }

  private ReviewEligibility eligibility(Row current, ReviewReason reason) {
    return new ReviewEligibility(
        current.id(),
        current.publication(),
        current.device(),
        current.registration(),
        current.revision(),
        reason == ReviewReason.ELIGIBLE,
        reason);
  }

  View get(String tenant, String actor, String id) {
    canonicalId(id);
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN, AUDITOR);
    return view(required(tenant, id, false));
  }

  private void defer(Row current, State next, Reason reason) {
    long now = now();
    if (current.attempts() >= settings.maximumAttempts() || current.expiresAt() <= now) {
      finish(
          current,
          State.NEEDS_REVIEW,
          current.providerVersion(),
          current.expiresAt() <= now ? Reason.DEADLINE_EXCEEDED : Reason.ATTEMPTS_EXHAUSTED,
          now());
      return;
    }
    long delay =
        Math.min(300_000L, settings.retryMillis() * (1L << Math.min(current.attempts() - 1, 5)));
    finish(
        current,
        next,
        current.providerVersion(),
        reason,
        Math.min(current.expiresAt(), now + delay));
  }

  private void finish(Row row, State state, Long version, Reason reason, long nextAt) {
    update(row, state, version, reason, nextAt, true, row.cancelled());
  }

  private void update(
      Row row,
      State state,
      Long version,
      Reason reason,
      long nextAt,
      boolean releaseLease,
      boolean cancel) {
    if (row.revision() >= MAX_REVISION) throw conflict("EXECUTION_VERSION_EXHAUSTED");
    String slot = state == State.APPLIED || state == State.CANCELLED ? null : row.device();
    exactlyOne(
        db.update(
            "UPDATE managed_policy_execution_tasks SET state=?,provider_version=?,reason_code=?,"
                + "next_attempt_at=?,active_device_id=?,revision=revision+1,cancel_requested=?,updated_at=?,lease_token=?,lease_until=?,action=?"
                + " WHERE tenant_id=? AND id=? AND revision=?",
            state.name(),
            version,
            reason.name(),
            nextAt,
            slot,
            cancel,
            now(),
            releaseLease ? null : row.token(),
            releaseLease ? null : row.leaseUntil(),
            releaseLease ? null : row.action().name(),
            row.tenant(),
            row.id(),
            row.revision()));
    event(required(row.tenant(), row.id(), false), row.action(), "system:managed-execution");
  }

  private void event(Row row, Action action, String actor) {
    db.update(
        "INSERT INTO"
            + " managed_policy_execution_events(tenant_id,task_id,revision,generation,state,action,reason_code,occurred_at)"
            + " VALUES(?,?,?,?,?,?,?,?)",
        row.tenant(),
        row.id(),
        row.revision(),
        row.generation(),
        row.state().name(),
        action == null ? null : action.name(),
        row.reason().name(),
        row.updatedAt());
    audit.record(row.tenant(), actor, "MANAGED_EXECUTION_" + row.reason().name(), row.id());
  }

  private boolean owns(Row row, Claim claim) {
    return row.generation() == claim.generation()
        && Objects.equals(row.token(), claim.token())
        && row.token() != null
        && row.action() == claim.action()
        && row.leaseUntil() != null
        && row.leaseUntil() == claim.leaseUntil()
        && row.enterprise().equals(claim.enterpriseId())
        && row.providerDevice().equals(claim.deviceId())
        && row.policy().equals(claim.policyId())
        && Objects.equals(row.providerVersion(), claim.policyVersion())
        && row.documentHash().equals(claim.documentSha256())
        && row.document().equals(claim.documentJson())
        && row.leaseUntil() > now()
        && row.expiresAt() > now();
  }

  private boolean neverAssigned(Row row) {
    return row.state() == State.READY_TO_WRITE || row.state() == State.READY_TO_ASSIGN;
  }

  private boolean due(Row row, long now) {
    return row.state() != State.APPLIED
        && row.state() != State.CANCELLED
        && row.state() != State.NEEDS_REVIEW
        && row.nextAt() <= now
        && (row.leaseUntil() == null || row.leaseUntil() <= now);
  }

  private Action action(State state) {
    return switch (state) {
      case READY_TO_WRITE -> Action.WRITE_POLICY;
      case POLICY_WRITE_UNKNOWN -> Action.READ_POLICY;
      case READY_TO_ASSIGN -> Action.ASSIGN_POLICY;
      case ASSIGNMENT_UNKNOWN, WAITING_DEVICE -> Action.READ_DEVICE;
      default -> throw new IllegalStateException("Task has no schedulable action");
    };
  }

  private Claim claim(Row row) {
    return new Claim(
        row.tenant(),
        row.id(),
        row.token(),
        row.generation(),
        row.action(),
        row.leaseUntil(),
        row.enterprise(),
        row.providerDevice(),
        row.policy(),
        row.providerVersion(),
        row.document(),
        row.documentHash());
  }

  private View view(Row row) {
    return new View(
        row.id(),
        row.publication(),
        row.device(),
        row.registration(),
        row.state(),
        row.reason(),
        row.revision(),
        row.createdAt(),
        row.updatedAt(),
        row.cancelled());
  }

  private Row required(String tenant, String id, boolean lock) {
    var rows =
        db.query(
            "SELECT * FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?"
                + (lock ? " FOR UPDATE" : ""),
            this::row,
            tenant,
            id);
    if (rows.size() != 1) throw DomainException.denied();
    return rows.get(0);
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
        r.getString("document_json"),
        r.getString("document_sha256"),
        r.getString("provider"),
        r.getString("enterprise_id"),
        r.getString("provider_device_id"),
        r.getString("provider_policy_id"),
        r.getObject("provider_version", Long.class),
        State.valueOf(r.getString("state")),
        r.getLong("generation"),
        r.getLong("revision"),
        r.getString("lease_token"),
        r.getObject("lease_until", Long.class),
        r.getString("action") == null ? null : Action.valueOf(r.getString("action")),
        r.getInt("attempts"),
        r.getLong("next_attempt_at"),
        r.getLong("expires_at"),
        r.getBoolean("cancel_requested"),
        Reason.valueOf(r.getString("reason_code")),
        r.getLong("created_at"),
        r.getLong("updated_at"));
  }

  private String contextHash(ManagedAgentBindingStore.VerifiedBindingContext context) {
    try {
      return SecretMaterial.hash(json.writeValueAsString(context));
    } catch (Exception invalid) {
      throw new IllegalStateException("Execution context serialization failed");
    }
  }

  private String canonicalDocument(String document) {
    if (document == null || document.getBytes(StandardCharsets.UTF_8).length > 65536)
      throw DomainException.invalid("INVALID_EXECUTION_DOCUMENT");
    try {
      Map<?, ?> value = json.readValue(document, Map.class);
      if (value == null
          || !value.keySet().equals(Set.of("schemaVersion", "adapterRevision", "policy"))
          || !Integer.valueOf(1).equals(value.get("schemaVersion"))
          || !(value.get("adapterRevision") instanceof String revision)
          || !revision.matches("[A-Za-z0-9._:-]{1,128}")
          || !(value.get("policy") instanceof Map<?, ?>))
        throw DomainException.invalid("INVALID_EXECUTION_DOCUMENT");
      String canonical = json.writeValueAsString(value);
      if (canonical.getBytes(StandardCharsets.UTF_8).length > 65536)
        throw DomainException.invalid("INVALID_EXECUTION_DOCUMENT");
      return canonical;
    } catch (Exception invalid) {
      throw DomainException.invalid("INVALID_EXECUTION_DOCUMENT");
    }
  }

  private String policyName(Row row) {
    return "enterprises/" + row.enterprise() + "/policies/" + row.policy();
  }

  private String deviceName(Row row) {
    return "enterprises/" + row.enterprise() + "/devices/" + row.providerDevice();
  }

  private long now() {
    return db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
  }

  private void workerBoundary() {
    if (TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException(
          "Execution worker checkpoints require separate short transactions");
  }

  private void requireReadCommitted() {
    if (!Objects.equals(
        TransactionSynchronizationManager.getCurrentTransactionIsolationLevel(),
        TransactionDefinition.ISOLATION_READ_COMMITTED))
      throw new IllegalStateException("Execution admission requires READ_COMMITTED");
  }

  private static void canonicalId(String id) {
    try {
      if (!UUID.fromString(id).toString().equals(id)) throw new IllegalArgumentException();
    } catch (RuntimeException invalid) {
      throw DomainException.invalid("INVALID_EXECUTION_REFERENCE");
    }
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private static void exactlyOne(int rows) {
    if (rows != 1) throw conflict("EXECUTION_CONCURRENT_CHANGE");
  }
}

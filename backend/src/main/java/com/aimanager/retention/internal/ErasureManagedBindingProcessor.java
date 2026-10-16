package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.sql.Timestamp;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * Internal, bounded cleanup of terminated local agent associations. Provider enrollment records,
 * provider devices, audit events and contract capacity are not changed. This step does not open
 * public erasure admission or complete the recovery job.
 */
@Component
class ErasureManagedBindingProcessor {
  private static final String STEP = "MANAGED_AGENT_BINDINGS";
  private final ErasureRecoveryJobs jobs;
  private final JdbcTemplate db;
  private final SubjectDataCatalog catalog;

  record Result(
      String phase, int deletedRows, long totalRows, long batches, int deletedExecutionTasks) {
    boolean complete() {
      return phase.equals("DONE");
    }
  }

  private record Step(String phase, long rows, long batches) {}

  private record Key(String id, long version) {}

  private record Scope(ErasureLedger.Request request, List<Object> pairs) {
    String matches(String alias, String deviceColumn) {
      if (pairs.isEmpty()) return "1=0";
      return "("
          + String.join(
              " OR ",
              Collections.nCopies(
                  pairs.size() / 2,
                  "(" + alias + "." + deviceColumn + "=? AND " + alias + ".registration_id=?)"))
          + ")";
    }

    Object[] args(Object... tail) {
      var values = new ArrayList<Object>();
      values.add(request.tenantId());
      values.addAll(pairs);
      values.addAll(Arrays.asList(tail));
      return values.toArray();
    }

    Object[] ownershipArgs() {
      var values = new ArrayList<Object>();
      values.add(request.tenantId());
      values.add(request.subjectId());
      values.addAll(pairs);
      values.add(request.subjectId());
      values.addAll(pairs);
      return values.toArray();
    }
  }

  ErasureManagedBindingProcessor(
      ErasureRecoveryJobs jobs, JdbcTemplate db, SubjectDataCatalog catalog) {
    this.jobs = jobs;
    this.db = db;
    this.catalog = catalog;
  }

  Result process(ErasureRecoveryJobs.Claim claim, int limit) {
    if (limit < 1 || limit > 25)
      throw new IllegalArgumentException("Invalid erasure work batch size");
    return jobs.applyBatch(
        claim,
        () -> {
          catalog.requireCurrentSchema();
          var request = claim.job().entry().request();
          var pairs = new ArrayList<Object>();
          for (var registration : request.registrations()) {
            pairs.add(registration.deviceId());
            pairs.add(registration.registrationId());
          }
          var scope = new Scope(request, List.copyOf(pairs));
          verifyScope(scope);
          verifyTerminated(request);
          var step = step(request.requestId());
          if (step.phase().equals("DONE")) {
            if (hasData(request)) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
            return new Result("DONE", 0, step.rows(), step.batches(), 0);
          }
          if (step.rows() > Long.MAX_VALUE - limit || step.batches() == Long.MAX_VALUE)
            throw failure("ERASURE_STEP_CORRUPT");
          var keys =
              db.query(
                  "SELECT id,version FROM managed_agent_bindings WHERE tenant_id=? AND"
                      + " subject_id=? ORDER BY id LIMIT ? FOR UPDATE",
                  (row, number) -> new Key(row.getString(1), row.getLong(2)),
                  request.tenantId(),
                  request.subjectId(),
                  limit);
          int budget = limit, deletedBindings = 0, deletedExecutions = 0;
          for (var key : keys) {
            if (budget == 0) break;
            // Spend the same row budget on execution tasks before deleting their parent binding.
            // Each task's bounded event history cascades; unfinished writes never reach this step.
            var tasks =
                db.query(
                    "SELECT id,revision FROM managed_policy_execution_tasks WHERE tenant_id=?"
                        + " AND binding_id=? ORDER BY id LIMIT ? FOR UPDATE",
                    (r, n) -> new Key(r.getString(1), r.getLong(2)),
                    request.tenantId(),
                    key.id(),
                    budget);
            for (var task : tasks) {
              if (db.queryForObject(
                      "SELECT COUNT(*) FROM managed_policy_execution_events WHERE tenant_id=?"
                          + " AND task_id=?",
                      Long.class,
                      request.tenantId(),
                      task.id())
                  > 100) throw failure("ERASURE_EXECUTION_HISTORY_LIMIT_EXCEEDED");
              exactlyOne(
                  db.update(
                      "DELETE FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=? AND"
                          + " revision=? AND state IN ('APPLIED','CANCELLED') AND lease_token IS"
                          + " NULL AND lease_until IS NULL AND action IS NULL AND active_device_id"
                          + " IS NULL",
                      request.tenantId(),
                      task.id(),
                      task.version()));
              budget--;
              deletedExecutions++;
            }
            if (budget == 0
                || exists(
                    "SELECT 1 FROM managed_policy_execution_tasks WHERE tenant_id=?"
                        + " AND binding_id=? LIMIT 1",
                    request.tenantId(),
                    key.id())) break;
            // Normal writes cap facts at 200 under this binding lock. Refuse corrupt/imported
            // oversized sets before a cascade; progress counts remain parent binding rows.
            if (db.queryForObject(
                    "SELECT COUNT(*) FROM managed_application_evidence WHERE tenant_id=? AND"
                        + " binding_id=?",
                    Long.class,
                    request.tenantId(),
                    key.id())
                > 200) throw failure("ERASURE_APPLICATION_EVIDENCE_LIMIT_EXCEEDED");
            exactlyOne(
                db.update(
                    "DELETE FROM managed_agent_bindings WHERE tenant_id=? AND subject_id=? AND"
                        + " id=? AND version=? AND state IN ('REVOKED','EXPIRED') AND nonce IS NULL"
                        + " AND active_device_id IS NULL AND active_enrollment_id IS NULL",
                    request.tenantId(),
                    request.subjectId(),
                    key.id(),
                    key.version()));
            budget--;
            deletedBindings++;
          }
          String phase = hasData(request) ? "DATA" : "DONE";
          exactlyOne(
              db.update(
                  "UPDATE erasure_recovery_steps SET phase=?,rows_processed=?,batches_processed=?,"
                      + "updated_at=? WHERE request_id=? AND step_code=? AND handler_version=1",
                  phase,
                  step.rows() + deletedBindings,
                  step.batches() + 1,
                  now(),
                  request.requestId(),
                  STEP));
          return new Result(
              phase,
              deletedBindings,
              step.rows() + deletedBindings,
              step.batches() + 1,
              deletedExecutions);
        });
  }

  private void verifyScope(Scope scope) {
    for (var source : List.of("devices d", "managed_agent_bindings d")) {
      String deviceColumn = source.startsWith("devices ") ? "id" : "device_id";
      String match = scope.matches("d", deviceColumn);
      if (exists(
          "SELECT 1 FROM "
              + source
              + " WHERE d.tenant_id=? AND ((d.subject_id=? AND NOT ("
              + match
              + ")) OR (d.subject_id<>? AND "
              + match
              + ")) LIMIT 1",
          scope.ownershipArgs())) throw failure("ERASURE_SCOPE_CHANGED");
    }
    if (exists(
            "SELECT 1 FROM devices d WHERE d.tenant_id=? AND "
                + scope.matches("d", "id")
                + " AND d.state<>'REVOKED' LIMIT 1",
            scope.args())
        || exists(
            "SELECT 1 FROM device_credential_scopes c WHERE c.tenant_id=? AND "
                + scope.matches("c", "device_id")
                + " AND c.active=true LIMIT 1",
            scope.args())
        || exists(
            "SELECT 1 FROM device_credentials c WHERE c.tenant_id=? AND "
                + scope.matches("c", "device_id")
                + " AND c.active=true AND c.revoked_at IS NULL AND c.expires_at>? LIMIT 1",
            scope.args(now()))) throw failure("ERASURE_DEVICE_EXIT_REQUIRED");
    // Separate FKs do not prove that the enrollment and agent belong to the same student.
    if (exists(
        "SELECT 1 FROM managed_agent_bindings b LEFT JOIN managed_enrollment_intents e ON"
            + " e.tenant_id=b.tenant_id AND e.id=b.enrollment_id WHERE b.tenant_id=? AND"
            + " b.subject_id=? AND (e.id IS NULL OR e.subject_id<>b.subject_id) LIMIT 1",
        scope.request().tenantId(),
        scope.request().subjectId())) throw failure("ERASURE_MANAGED_BINDING_SCOPE_CORRUPT");
  }

  private void verifyTerminated(ErasureLedger.Request request) {
    if (exists(
        "SELECT 1 FROM managed_policy_execution_tasks t JOIN managed_agent_bindings b ON"
            + " b.tenant_id=t.tenant_id AND b.id=t.binding_id WHERE t.tenant_id=? AND"
            + " (t.subject_id=? OR b.subject_id=?) AND (t.subject_id<>b.subject_id OR"
            + " t.device_id<>b.device_id OR t.registration_id<>b.registration_id) LIMIT 1",
        request.tenantId(),
        request.subjectId(),
        request.subjectId())) throw failure("ERASURE_EXECUTION_SCOPE_CORRUPT");
    if (exists(
        "SELECT 1 FROM managed_policy_execution_tasks WHERE tenant_id=? AND subject_id=? AND (state"
            + " NOT IN ('APPLIED','CANCELLED') OR lease_token IS NOT NULL OR lease_until IS NOT"
            + " NULL OR action IS NOT NULL OR active_device_id IS NOT NULL) LIMIT 1",
        request.tenantId(),
        request.subjectId())) throw failure("ERASURE_EXECUTION_RECONCILIATION_REQUIRED");
    if (exists(
        "SELECT 1 FROM managed_agent_bindings WHERE tenant_id=? AND subject_id=? AND state"
            + " NOT IN ('REVOKED','EXPIRED') LIMIT 1",
        request.tenantId(),
        request.subjectId())) throw failure("ERASURE_MANAGED_BINDING_EXIT_REQUIRED");
    if (exists(
        "SELECT 1 FROM managed_agent_bindings WHERE tenant_id=? AND subject_id=? AND (nonce IS NOT"
            + " NULL OR active_device_id IS NOT NULL OR active_enrollment_id IS NOT NULL OR"
            + " version<1) LIMIT 1",
        request.tenantId(),
        request.subjectId())) throw failure("ERASURE_MANAGED_BINDING_STATE_CORRUPT");
  }

  private Step step(String request) {
    var rows =
        db.query(
            "SELECT handler_version,phase,cursor_id,rows_processed,batches_processed FROM"
                + " erasure_recovery_steps WHERE request_id=? AND step_code=? FOR UPDATE",
            (row, number) -> {
              if (row.getInt(1) != 1) throw failure("ERASURE_STEP_VERSION_UNSUPPORTED");
              String phase = row.getString(2);
              long processed = row.getLong(4), batches = row.getLong(5);
              if (!Set.of("DATA", "DONE").contains(phase)
                  || row.getString(3) != null
                  || processed < 0
                  || batches < 0) throw failure("ERASURE_STEP_CORRUPT");
              return new Step(phase, processed, batches);
            },
            request,
            STEP);
    if (!rows.isEmpty()) return rows.get(0);
    exactlyOne(
        db.update(
            "INSERT INTO erasure_recovery_steps(request_id,step_code,handler_version,phase,"
                + "rows_processed,batches_processed,updated_at) VALUES(?,?,1,'DATA',0,0,0)",
            request,
            STEP));
    return new Step("DATA", 0, 0);
  }

  private boolean hasData(ErasureLedger.Request request) {
    return exists(
        "SELECT 1 FROM managed_agent_bindings WHERE tenant_id=? AND subject_id=? LIMIT 1",
        request.tenantId(),
        request.subjectId());
  }

  private boolean exists(String sql, Object... args) {
    return !db.queryForList(sql, args).isEmpty();
  }

  private long now() {
    return db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
  }

  private static void exactlyOne(int rows) {
    if (rows != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
  }

  private static ErasureLedger.Failure failure(String code) {
    return new ErasureLedger.Failure(code);
  }
}

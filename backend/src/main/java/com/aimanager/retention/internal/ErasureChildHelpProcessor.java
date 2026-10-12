package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Deletes one subject's help records in fenced batches; never completes the whole erasure. */
@Component
class ErasureChildHelpProcessor {
  private static final String STEP = "CHILD_HELP_REQUESTS";
  private final ErasureRecoveryJobs jobs;
  private final JdbcTemplate db;
  private final SubjectDataCatalog catalog;

  record Result(String phase, int deletedRows, long totalRows, long batches) {
    boolean complete() {
      return phase.equals("DONE");
    }
  }

  private record Step(String phase, long rows, long batches) {}

  ErasureChildHelpProcessor(
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
          var scope = claim.job().entry().request();
          verifyScope(scope);
          verifyExited(scope);
          var step = step(scope.requestId());
          if (step.phase().equals("DONE")) {
            if (hasData(scope)) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
            return new Result("DONE", 0, step.rows(), step.batches());
          }
          if (step.rows() > Long.MAX_VALUE - limit || step.batches() == Long.MAX_VALUE)
            throw failure("ERASURE_STEP_CORRUPT");
          var ids =
              db.queryForList(
                  "SELECT id FROM child_help_requests WHERE tenant_id=? AND subject_id=?"
                      + " ORDER BY id LIMIT ? FOR UPDATE",
                  String.class,
                  scope.tenantId(),
                  scope.subjectId(),
                  limit);
          for (String id : ids)
            exactlyOne(
                db.update(
                    "DELETE FROM child_help_requests WHERE tenant_id=? AND subject_id=? AND id=?",
                    scope.tenantId(),
                    scope.subjectId(),
                    id));
          String phase = hasData(scope) ? "DATA" : "DONE";
          exactlyOne(
              db.update(
                  "UPDATE erasure_recovery_steps SET phase=?,rows_processed=?,batches_processed=?,"
                      + "updated_at=? WHERE request_id=? AND step_code=? AND handler_version=1",
                  phase,
                  step.rows() + ids.size(),
                  step.batches() + 1,
                  now(),
                  scope.requestId(),
                  STEP));
          return new Result(phase, ids.size(), step.rows() + ids.size(), step.batches() + 1);
        });
  }

  private void verifyScope(ErasureLedger.Request scope) {
    var pairs = new ArrayList<String>();
    var pairValues = new ArrayList<Object>();
    for (var registration : scope.registrations()) {
      pairs.add("(device_id=? AND registration_id=?)");
      pairValues.add(registration.deviceId());
      pairValues.add(registration.registrationId());
    }
    String predicate = pairs.isEmpty() ? "1=0" : "(" + String.join(" OR ", pairs) + ")";
    for (String table : List.of("devices", "child_help_requests")) {
      String match = table.equals("devices") ? predicate.replace("device_id", "id") : predicate;
      var args = new ArrayList<Object>(List.of(scope.tenantId(), scope.subjectId()));
      args.addAll(pairValues);
      args.add(scope.subjectId());
      args.addAll(pairValues);
      if (exists(
          "SELECT 1 FROM "
              + table
              + " WHERE tenant_id=? AND ((subject_id=? AND NOT ("
              + match
              + ")) OR (subject_id<>? AND "
              + match
              + ")) LIMIT 1",
          args.toArray())) throw failure("ERASURE_SCOPE_CHANGED");
    }
  }

  private void verifyExited(ErasureLedger.Request scope) {
    if (exists(
        "SELECT 1 FROM devices WHERE tenant_id=? AND subject_id=? AND state<>'REVOKED' LIMIT 1",
        scope.tenantId(),
        scope.subjectId())) throw failure("ERASURE_DEVICE_EXIT_REQUIRED");
  }

  private Step step(String request) {
    var rows =
        db.query(
            "SELECT handler_version,phase,cursor_id,rows_processed,batches_processed FROM"
                + " erasure_recovery_steps WHERE request_id=? AND step_code=? FOR UPDATE",
            (row, index) -> {
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

  private boolean hasData(ErasureLedger.Request scope) {
    return exists(
        "SELECT 1 FROM child_help_requests WHERE tenant_id=? AND subject_id=? LIMIT 1",
        scope.tenantId(),
        scope.subjectId());
  }

  private long now() {
    return db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
  }

  private boolean exists(String sql, Object... parameters) {
    return !db.queryForList(sql, parameters).isEmpty();
  }

  private static void exactlyOne(int changed) {
    if (changed != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
  }

  private static ErasureLedger.Failure failure(String code) {
    return new ErasureLedger.Failure(code);
  }
}

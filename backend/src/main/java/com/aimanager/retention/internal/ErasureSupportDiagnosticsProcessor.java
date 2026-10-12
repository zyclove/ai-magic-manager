package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.sql.Timestamp;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Internal step only; the full subject-erasure workflow remains separately gated. */
@Component
class ErasureSupportDiagnosticsProcessor {
  private static final String STEP = "SUPPORT_DIAGNOSTICS";
  private static final List<String> STORES = List.of("diagnostic_packages", "support_grants");
  private final ErasureRecoveryJobs jobs;
  private final JdbcTemplate db;
  private final SubjectDataCatalog catalog;

  record Result(String phase, int deletedRows, long totalRows, long batches) {
    boolean complete() {
      return phase.equals("DONE");
    }
  }

  private record Step(String phase, long rows, long batches) {}

  ErasureSupportDiagnosticsProcessor(
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
          verifyLinks(scope);
          var step = step(scope.requestId());
          if (step.phase().equals("DONE")) {
            if (hasData(scope)) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
            return new Result("DONE", 0, step.rows(), step.batches());
          }
          if (step.rows() > Long.MAX_VALUE - limit || step.batches() == Long.MAX_VALUE)
            throw failure("ERASURE_STEP_CORRUPT");
          int deleted = 0;
          for (String table : STORES) {
            int remaining = limit - deleted;
            if (remaining == 0) break;
            var ids =
                db.queryForList(
                    "SELECT id FROM "
                        + table
                        + " WHERE tenant_id=? AND subject_id=? ORDER BY id LIMIT ? FOR UPDATE",
                    String.class,
                    scope.tenantId(),
                    scope.subjectId(),
                    remaining);
            for (String id : ids) {
              exactlyOne(
                  db.update(
                      "DELETE FROM " + table + " WHERE tenant_id=? AND subject_id=? AND id=?",
                      scope.tenantId(),
                      scope.subjectId(),
                      id));
              deleted++;
            }
          }
          String phase = hasData(scope) ? "DATA" : "DONE";
          long time = db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
          exactlyOne(
              db.update(
                  "UPDATE erasure_recovery_steps SET phase=?,rows_processed=?,batches_processed=?,"
                      + "updated_at=? WHERE request_id=? AND step_code=? AND handler_version=1",
                  phase,
                  step.rows() + deleted,
                  step.batches() + 1,
                  time,
                  scope.requestId(),
                  STEP));
          return new Result(phase, deleted, step.rows() + deleted, step.batches() + 1);
        });
  }

  private Step step(String request) {
    var rows =
        db.query(
            "SELECT handler_version,phase,cursor_id,rows_processed,batches_processed FROM"
                + " erasure_recovery_steps WHERE request_id=? AND step_code=? FOR UPDATE",
            (r, n) -> {
              if (r.getInt(1) != 1) throw failure("ERASURE_STEP_VERSION_UNSUPPORTED");
              String phase = r.getString(2);
              long processed = r.getLong(4), batches = r.getLong(5);
              if (!Set.of("DATA", "DONE").contains(phase)
                  || r.getString(3) != null
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

  private void verifyScope(ErasureLedger.Request scope) {
    var pairs = new ArrayList<String>();
    var values = new ArrayList<Object>();
    for (var registration : scope.registrations()) {
      pairs.add("(device_id=? AND registration_id=?)");
      values.add(registration.deviceId());
      values.add(registration.registrationId());
    }
    String predicate = pairs.isEmpty() ? "1=0" : "(" + String.join(" OR ", pairs) + ")";
    for (String table : List.of("devices", "diagnostic_packages", "support_grants")) {
      String match = table.equals("devices") ? predicate.replace("device_id", "id") : predicate;
      var args = new ArrayList<Object>(List.of(scope.tenantId(), scope.subjectId()));
      args.addAll(values);
      args.add(scope.subjectId());
      args.addAll(values);
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

  private void verifyLinks(ErasureLedger.Request scope) {
    if (exists(
        "SELECT 1 FROM diagnostic_packages d LEFT JOIN support_grants g ON"
            + " g.tenant_id=d.tenant_id AND g.id=d.grant_id WHERE d.tenant_id=?"
            + " AND d.grant_id IS NOT NULL AND (d.subject_id=? OR g.subject_id=?)"
            + " AND (g.id IS NULL OR d.subject_id<>g.subject_id OR d.device_id<>g.device_id"
            + " OR d.registration_id<>g.registration_id) LIMIT 1",
        scope.tenantId(),
        scope.subjectId(),
        scope.subjectId())) throw failure("ERASURE_SUPPORT_SCOPE_CORRUPT");
  }

  private boolean hasData(ErasureLedger.Request scope) {
    for (String table : STORES)
      if (exists(
          "SELECT 1 FROM " + table + " WHERE tenant_id=? AND subject_id=? LIMIT 1",
          scope.tenantId(),
          scope.subjectId())) return true;
    return false;
  }

  private boolean exists(String sql, Object... parameters) {
    return !db.queryForList(sql, parameters).isEmpty();
  }

  private static void exactlyOne(int rows) {
    if (rows != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
  }

  private static ErasureLedger.Failure failure(String code) {
    return new ErasureLedger.Failure(code);
  }
}

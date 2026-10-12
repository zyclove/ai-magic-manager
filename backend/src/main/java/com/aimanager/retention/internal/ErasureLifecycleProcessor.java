package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.sql.Timestamp;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Internal server lifecycle-copy step. Local-device erasure remains explicitly unverified. */
@Component
class ErasureLifecycleProcessor {
  private static final String STEP = "DEVICE_LIFECYCLE";
  private final ErasureRecoveryJobs jobs;
  private final JdbcTemplate db;
  private final SubjectDataCatalog catalog;

  record Result(
      String phase,
      int deletedRows,
      long totalRows,
      long batches,
      int unverifiedLocalRegistrations) {
    boolean complete() {
      return phase.equals("DONE");
    }
  }

  private record Step(String phase, long rows, long batches) {}

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

    String where(String alias, String deviceColumn) {
      return alias + ".tenant_id=? AND " + matches(alias, deviceColumn);
    }

    Object[] args(Object... tail) {
      var values = new ArrayList<Object>();
      values.add(request.tenantId());
      values.addAll(pairs);
      values.addAll(Arrays.asList(tail));
      return values.toArray();
    }
  }

  /** Only constant, reviewed table and column names enter these statements. */
  private record Store(
      String table,
      String alias,
      List<String> keys,
      String from,
      String where,
      boolean tenantKey,
      List<Object> bindings) {
    Object[] values(Object... tail) {
      var result = new ArrayList<Object>(bindings);
      result.addAll(Arrays.asList(tail));
      return result.toArray();
    }

    String selection() {
      return String.join(",", keys.stream().map(k -> alias + "." + k).toList());
    }
  }

  ErasureLifecycleProcessor(ErasureRecoveryJobs jobs, JdbcTemplate db, SubjectDataCatalog catalog) {
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
          verifyLinks(scope);
          verifyCleanupWindow(scope);
          var stores = stores(scope);
          var step = step(request.requestId());
          if (step.phase().equals("DONE")) {
            if (hasData(stores)) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
            return new Result(
                "DONE", 0, step.rows(), step.batches(), request.registrations().size());
          }
          if (step.rows() > Long.MAX_VALUE - limit || step.batches() == Long.MAX_VALUE)
            throw failure("ERASURE_STEP_CORRUPT");
          int deleted = 0;
          for (var store : stores) {
            int remaining = limit - deleted;
            if (remaining == 0) break;
            var keys =
                db.query(
                    "SELECT "
                        + store.selection()
                        + " FROM "
                        + store.from()
                        + " WHERE "
                        + store.where()
                        + " ORDER BY "
                        + store.selection()
                        + " LIMIT ? FOR UPDATE",
                    (row, number) -> {
                      var key = new ArrayList<Object>();
                      if (store.tenantKey()) key.add(request.tenantId());
                      for (int n = 1; n <= store.keys().size(); n++) key.add(row.getString(n));
                      return key;
                    },
                    store.values(remaining));
            String predicate =
                (store.tenantKey() ? "tenant_id=? AND " : "")
                    + String.join(" AND ", store.keys().stream().map(k -> k + "=?").toList());
            for (var key : keys) {
              exactlyOne(
                  db.update("DELETE FROM " + store.table() + " WHERE " + predicate, key.toArray()));
              deleted++;
            }
          }
          String phase = hasData(stores) ? "DATA" : "DONE";
          exactlyOne(
              db.update(
                  "UPDATE erasure_recovery_steps SET phase=?,rows_processed=?,batches_processed=?,"
                      + "updated_at=? WHERE request_id=? AND step_code=? AND handler_version=1",
                  phase,
                  step.rows() + deleted,
                  step.batches() + 1,
                  now(),
                  request.requestId(),
                  STEP));
          return new Result(
              phase,
              deleted,
              step.rows() + deleted,
              step.batches() + 1,
              request.registrations().size());
        });
  }

  private List<Store> stores(Scope scope) {
    var owner = List.<Object>of(scope.request().tenantId(), scope.request().subjectId());
    var pairs = Arrays.asList(scope.args());
    return List.of(
        new Store(
            "enrollment_proofs",
            "p",
            List.of("enrollment_id", "purpose", "jti_hash"),
            "enrollment_proofs p JOIN device_enrollments e ON e.tenant_id=p.tenant_id AND"
                + " e.id=p.enrollment_id",
            "e.tenant_id=? AND e.subject_id=?",
            true,
            owner),
        new Store(
            "device_enrollments",
            "e",
            List.of("id"),
            "device_enrollments e",
            "e.tenant_id=? AND e.subject_id=?",
            true,
            owner),
        new Store(
            "deprovision_previews",
            "p",
            List.of("id"),
            "deprovision_previews p",
            scope.where("p", "device_id"),
            true,
            pairs),
        new Store(
            "deprovision_heads",
            "h",
            List.of("device_id", "registration_id"),
            "deprovision_heads h",
            scope.where("h", "device_id"),
            true,
            pairs),
        new Store(
            "cleanup_receipts",
            "c",
            List.of("operation_id", "receipt_id"),
            "cleanup_receipts c JOIN deprovision_operations o ON o.tenant_id=c.tenant_id AND"
                + " o.id=c.operation_id",
            scope.where("o", "device_id"),
            true,
            pairs),
        new Store(
            "deprovision_operations",
            "o",
            List.of("id"),
            "deprovision_operations o",
            scope.where("o", "device_id"),
            true,
            pairs));
  }

  private void verifyScope(Scope scope) {
    var args = new ArrayList<Object>();
    args.add(scope.request().tenantId());
    args.add(scope.request().subjectId());
    args.addAll(scope.pairs());
    args.add(scope.request().subjectId());
    args.addAll(scope.pairs());
    String match = scope.matches("d", "id");
    if (exists(
        "SELECT 1 FROM devices d WHERE d.tenant_id=? AND ((d.subject_id=? AND NOT ("
            + match
            + ")) OR (d.subject_id<>? AND "
            + match
            + ")) LIMIT 1",
        args.toArray())) throw failure("ERASURE_SCOPE_CHANGED");
    if (exists(
            "SELECT 1 FROM devices d WHERE "
                + scope.where("d", "id")
                + " AND d.state<>'REVOKED' LIMIT 1",
            scope.args())
        || exists(
            "SELECT 1 FROM device_credential_scopes c WHERE "
                + scope.where("c", "device_id")
                + " AND c.active=true LIMIT 1",
            scope.args())
        || exists(
            "SELECT 1 FROM device_credentials c WHERE "
                + scope.where("c", "device_id")
                + " AND c.active=true AND c.revoked_at IS NULL AND c.expires_at>? LIMIT 1",
            scope.args(now()))) throw failure("ERASURE_DEVICE_EXIT_REQUIRED");
  }

  private void verifyLinks(Scope scope) {
    var devices =
        scope.request().registrations().stream()
            .map(ErasureLedger.Registration::deviceId)
            .distinct()
            .toList();
    var enrollmentArgs = new ArrayList<Object>();
    enrollmentArgs.add(scope.request().tenantId());
    enrollmentArgs.add(scope.request().subjectId());
    enrollmentArgs.addAll(devices);
    if (exists(
        "SELECT 1 FROM device_enrollments e WHERE e.tenant_id=? AND e.subject_id=?"
            + " AND e.device_id IS NOT NULL AND NOT ("
            + in("e.device_id", devices.size())
            + ") LIMIT 1",
        enrollmentArgs.toArray())) throw failure("ERASURE_LIFECYCLE_SCOPE_CORRUPT");

    var registrations =
        scope.request().registrations().stream()
            .map(ErasureLedger.Registration::registrationId)
            .toList();
    var registrationArgs = new ArrayList<Object>();
    registrationArgs.add(scope.request().tenantId());
    registrationArgs.addAll(registrations);
    registrationArgs.addAll(scope.pairs());
    for (String table :
        List.of("deprovision_previews", "deprovision_heads", "deprovision_operations")) {
      if (exists(
          "SELECT 1 FROM "
              + table
              + " c WHERE c.tenant_id=? AND "
              + in("c.registration_id", registrations.size())
              + " AND NOT ("
              + scope.matches("c", "device_id")
              + ") LIMIT 1",
          registrationArgs.toArray())) throw failure("ERASURE_LIFECYCLE_SCOPE_CORRUPT");
    }
    // These links have no SQL foreign key. Check both ends before any leaf is removed.
    var edgeArgs = new ArrayList<Object>(Arrays.asList(scope.args()));
    edgeArgs.addAll(Arrays.asList(scope.args()));
    for (String table : List.of("deprovision_previews", "deprovision_heads")) {
      if (exists(
          "SELECT 1 FROM "
              + table
              + " c LEFT JOIN deprovision_operations o ON o.tenant_id=c.tenant_id AND"
              + " o.id=c.operation_id WHERE c.operation_id IS NOT NULL AND (("
              + scope.where("c", "device_id")
              + ") OR ("
              + scope.where("o", "device_id")
              + ")) AND (o.id IS NULL OR c.device_id<>o.device_id OR"
              + " c.registration_id<>o.registration_id) LIMIT 1",
          edgeArgs.toArray())) throw failure("ERASURE_LIFECYCLE_SCOPE_CORRUPT");
    }
  }

  private static String in(String column, int size) {
    return size == 0
        ? "1=0"
        : column + " IN (" + String.join(",", Collections.nCopies(size, "?")) + ")";
  }

  private void verifyCleanupWindow(Scope scope) {
    if (exists(
        "SELECT 1 FROM deprovision_operations o WHERE "
            + scope.where("o", "device_id")
            + " AND (o.state NOT IN ('WAITING_FOR_AGENT','COMMAND_SERVED','COMMAND_RECEIVED',"
            + "'CLEANUP_FAILED','CLEANUP_REPORTED','CLEANUP_EXPIRED','CLEANUP_CANCELLED') OR"
            + " o.local_evidence NOT IN ('NONE','DEVICE_REPORT_UNVERIFIED') OR (o.state IN"
            + " ('CLEANUP_REPORTED','CLEANUP_FAILED') AND"
            + " o.local_evidence<>'DEVICE_REPORT_UNVERIFIED')) LIMIT 1",
        scope.args())) throw failure("ERASURE_LIFECYCLE_STATE_CORRUPT");
    // Even a reported result can still need its original server acknowledgement.
    // Expiry only ends protocol availability; it never verifies local erasure.
    if (exists(
        "SELECT 1 FROM deprovision_operations o WHERE "
            + scope.where("o", "device_id")
            + " AND o.state<>'CLEANUP_CANCELLED' AND o.absolute_not_after>? LIMIT 1",
        scope.args(now()))) throw failure("ERASURE_LOCAL_CLEANUP_PENDING");
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

  private boolean hasData(List<Store> stores) {
    for (var store : stores)
      if (exists(
          "SELECT 1 FROM " + store.from() + " WHERE " + store.where() + " LIMIT 1", store.values()))
        return true;
    return false;
  }

  private long now() {
    return db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
  }

  private boolean exists(String sql, Object... args) {
    return !db.queryForList(sql, args).isEmpty();
  }

  private static void exactlyOne(int rows) {
    if (rows != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
  }

  private static ErasureLedger.Failure failure(String code) {
    return new ErasureLedger.Failure(code);
  }
}

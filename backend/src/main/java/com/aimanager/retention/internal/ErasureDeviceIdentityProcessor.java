package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.sql.Timestamp;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Internal step. Device rows remain available to the rest of the erasure workflow. */
@Component
class ErasureDeviceIdentityProcessor {
  private static final String STEP = "DEVICE_IDENTITY";
  private final ErasureRecoveryJobs jobs;
  private final JdbcTemplate db;
  private final SubjectDataCatalog catalog;

  record Result(String phase, int deletedRows, long totalRows, long batches) {
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
      String table, String alias, List<String> keys, String from, String where, boolean tenantKey) {
    String selection() {
      return String.join(",", keys.stream().map(k -> alias + "." + k).toList());
    }
  }

  ErasureDeviceIdentityProcessor(
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
          verifyRotations(scope);
          var stores = stores(scope);
          var step = step(request.requestId());
          if (step.phase().equals("DONE")) {
            if (hasData(scope, stores)) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
            return new Result("DONE", 0, step.rows(), step.batches());
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
                    scope.args(remaining));
            String predicate =
                (store.tenantKey() ? "tenant_id=? AND " : "")
                    + String.join(" AND ", store.keys().stream().map(k -> k + "=?").toList());
            for (var key : keys) {
              exactlyOne(
                  db.update("DELETE FROM " + store.table() + " WHERE " + predicate, key.toArray()));
              deleted++;
            }
          }
          String phase = hasData(scope, stores) ? "DATA" : "DONE";
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
          return new Result(phase, deleted, step.rows() + deleted, step.batches() + 1);
        });
  }

  private List<Store> stores(Scope scope) {
    return List.of(
        new Store(
            "device_credential_rotations",
            "r",
            List.of("parent_id"),
            "device_credential_rotations r JOIN device_credentials c ON c.id=r.parent_id",
            scope.where("c", "device_id"),
            false),
        new Store(
            "device_credentials",
            "c",
            List.of("id"),
            "device_credentials c",
            scope.where("c", "device_id"),
            true),
        new Store(
            "device_credential_scopes",
            "c",
            List.of("registration_id", "device_id"),
            "device_credential_scopes c",
            scope.where("c", "device_id"),
            true),
        new Store(
            "device_group_members",
            "c",
            List.of("group_id", "device_id", "registration_id"),
            "device_group_members c",
            scope.where("c", "device_id"),
            true),
        new Store(
            "device_capabilities",
            "c",
            List.of("device_id", "capability_key"),
            "device_capabilities c JOIN devices d ON d.tenant_id=c.tenant_id AND d.id=c.device_id",
            scope.where("d", "id"),
            true));
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

  private void verifyRotations(Scope scope) {
    var args = new ArrayList<Object>(Arrays.asList(scope.args()));
    args.addAll(Arrays.asList(scope.args()));
    if (exists(
        "SELECT 1 FROM device_credential_rotations r LEFT JOIN device_credentials p ON"
            + " p.id=r.parent_id LEFT JOIN device_credentials n ON n.id=r.new_id WHERE (("
            + scope.where("p", "device_id")
            + ") OR ("
            + scope.where("n", "device_id")
            + ")) AND (p.id IS NULL OR n.id IS NULL OR p.tenant_id<>n.tenant_id OR"
            + " p.device_id<>n.device_id OR p.registration_id<>n.registration_id) LIMIT 1",
        args.toArray())) throw failure("ERASURE_CREDENTIAL_SCOPE_CORRUPT");
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

  private boolean hasData(Scope scope, List<Store> stores) {
    for (var store : stores)
      if (exists(
          "SELECT 1 FROM " + store.from() + " WHERE " + store.where() + " LIMIT 1", scope.args()))
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

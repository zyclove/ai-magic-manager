package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import java.sql.Timestamp;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Internal configuration-copy step; shared policies and device lifecycle evidence remain. */
@Component
class ErasureConfigurationProcessor {
  private static final String STEP = "CONFIGURATION_DELIVERY";
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

  ErasureConfigurationProcessor(
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
          verifyLinks(scope);
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
    String join =
        " JOIN configuration_device_heads h ON h.tenant_id=c.tenant_id"
            + " AND h.registration_id=c.registration_id";
    return List.of(
        new Store(
            "configuration_receipts",
            "c",
            List.of("registration_id", "id"),
            "configuration_receipts c" + join,
            scope.where("h", "device_id"),
            true),
        new Store(
            "configuration_streams",
            "c",
            List.of("registration_id", "policy_id"),
            "configuration_streams c" + join,
            scope.where("h", "device_id"),
            true),
        new Store(
            "configuration_deliveries",
            "c",
            List.of("id"),
            "configuration_deliveries c" + join,
            scope.where("h", "device_id"),
            true),
        new Store(
            "configuration_device_heads",
            "h",
            List.of("registration_id"),
            "configuration_device_heads h",
            scope.where("h", "device_id"),
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

  private void verifyLinks(Scope scope) {
    var registrations =
        scope.request().registrations().stream()
            .map(ErasureLedger.Registration::registrationId)
            .toList();
    String in =
        registrations.isEmpty()
            ? "1=0"
            : "h.registration_id IN ("
                + String.join(",", Collections.nCopies(registrations.size(), "?"))
                + ")";
    var headArgs = new ArrayList<Object>();
    headArgs.add(scope.request().tenantId());
    headArgs.addAll(registrations);
    headArgs.addAll(scope.pairs());
    if (exists(
        "SELECT 1 FROM configuration_device_heads h WHERE h.tenant_id=? AND "
            + in
            + " AND NOT ("
            + scope.matches("h", "device_id")
            + ") LIMIT 1",
        headArgs.toArray())) throw failure("ERASURE_CONFIGURATION_SCOPE_CORRUPT");

    var args = new ArrayList<Object>(Arrays.asList(scope.args()));
    args.addAll(Arrays.asList(scope.args()));
    var devices =
        scope.request().registrations().stream()
            .map(ErasureLedger.Registration::deviceId)
            .distinct()
            .toList();
    String deviceIn =
        devices.isEmpty()
            ? "1=0"
            : "d.device_id IN (" + String.join(",", Collections.nCopies(devices.size(), "?")) + ")";
    var deliveryArgs = new ArrayList<Object>();
    deliveryArgs.add(scope.request().tenantId());
    deliveryArgs.addAll(devices);
    deliveryArgs.add(scope.request().tenantId());
    deliveryArgs.addAll(devices);
    // A corrupt device field can conceal a target copy behind an unrelated
    // registration. Validate either device endpoint; deletion remains scoped
    // to the exact accepted registration pairs below.
    if (exists(
        "SELECT 1 FROM configuration_deliveries d LEFT JOIN configuration_device_heads h"
            + " ON h.tenant_id=d.tenant_id AND h.registration_id=d.registration_id WHERE"
            + " ((d.tenant_id=? AND "
            + deviceIn
            + ") OR (h.tenant_id=? AND "
            + deviceIn.replace("d.device_id", "h.device_id")
            + ")) AND (h.registration_id IS NULL OR d.device_id<>h.device_id) LIMIT 1",
        deliveryArgs.toArray())) throw failure("ERASURE_CONFIGURATION_SCOPE_CORRUPT");

    // Each leaf has independent foreign keys to its head and delivery. Neither
    // foreign key proves both edges refer to the same device registration.
    for (String table : List.of("configuration_receipts", "configuration_streams")) {
      var leafArgs = new ArrayList<Object>(args);
      leafArgs.add(scope.request().tenantId());
      leafArgs.addAll(registrations);
      String childRegistration = in.replace("h.registration_id", "c.registration_id");
      String policy = table.equals("configuration_streams") ? " OR c.policy_id<>d.policy_id" : "";
      if (exists(
          "SELECT 1 FROM "
              + table
              + " c LEFT JOIN configuration_device_heads h ON h.tenant_id=c.tenant_id AND"
              + " h.registration_id=c.registration_id LEFT JOIN configuration_deliveries d ON"
              + " d.tenant_id=c.tenant_id AND d.id=c.delivery_id WHERE (("
              + scope.where("d", "device_id")
              + ") OR ("
              + scope.where("h", "device_id")
              + ") OR (c.tenant_id=? AND "
              + childRegistration
              + ")) AND (h.registration_id IS NULL OR d.id IS NULL OR"
              + " c.registration_id<>d.registration_id OR h.device_id<>d.device_id"
              + policy
              + ") LIMIT 1",
          leafArgs.toArray())) throw failure("ERASURE_CONFIGURATION_SCOPE_CORRUPT");
    }
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

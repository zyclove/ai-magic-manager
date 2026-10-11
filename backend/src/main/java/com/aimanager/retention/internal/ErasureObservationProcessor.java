package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.json.JsonMapper;
import java.sql.Timestamp;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Internal domain processor; a completed step never means completed subject erasure. */
@Component
class ErasureObservationProcessor {
  private static final String STEP = "OBSERVATION_REPORTS";
  private static final List<String> STORES =
      List.of(
          "usage_observation_batches",
          "usage_observation_heads",
          "application_inventory_snapshots",
          "device_observation_settings");
  private final ErasureRecoveryJobs jobs;
  private final JdbcTemplate db;
  private final SubjectDataCatalog catalog;
  private final JsonMapper json =
      JsonMapper.builder()
          .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .build();

  record Result(String phase, int deletedRows, long totalRows, long batches) {
    boolean complete() {
      return phase.equals("DONE");
    }
  }

  private record Step(String phase, String cursor, long rows, long batches) {}

  private record Scope(
      ErasureLedger.Request request,
      Set<ErasureLedger.Registration> registrations,
      String predicate,
      List<Object> parameters) {}

  private record Report(String id, String selection, String hash, int total) {}

  private record Part(int ordinal, String device, String registration, String subject) {}

  private record Key(String device, String registration, long sequence) {}

  ErasureObservationProcessor(
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
          var scope = scope(claim.job().entry().request());
          var step = step(scope.request().requestId());
          if (step.phase().equals("DONE")) {
            if (hasData(scope)
                || !db.queryForList(
                        "SELECT 1 FROM usage_report_parts WHERE tenant_id=? AND (subject_id=? OR "
                            + scope.predicate()
                            + ") LIMIT 1",
                        args(
                            List.of(scope.request().tenantId(), scope.request().subjectId()),
                            scope.parameters()))
                    .isEmpty()) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
            return new Result("DONE", 0, step.rows(), step.batches());
          }
          if (step.rows() > Long.MAX_VALUE - 5025 || step.batches() == Long.MAX_VALUE)
            throw failure("ERASURE_STEP_CORRUPT");
          String phase = step.phase(), cursor = step.cursor();
          int deleted = 0;
          if (phase.equals("REPORTS")) {
            var parameters = new ArrayList<Object>();
            parameters.add(scope.request().tenantId());
            if (cursor != null) parameters.add(cursor);
            parameters.add(limit);
            var reports =
                db.query(
                    "SELECT id,CASE WHEN OCTET_LENGTH(selection_json)<=65536 THEN selection_json"
                        + " ELSE NULL END AS selection_json,selection_hash,total_devices FROM"
                        + " usage_report_jobs WHERE tenant_id=?"
                        + (cursor == null ? "" : " AND id>?")
                        + " ORDER BY id LIMIT ? FOR UPDATE",
                    (r, n) ->
                        new Report(r.getString(1), r.getString(2), r.getString(3), r.getInt(4)),
                    parameters.toArray());
            for (var report : reports) {
              deleted += report(scope, report);
              cursor = report.id();
            }
            if (reports.size() < limit) {
              phase = "DATA";
              cursor = null;
            }
          } else {
            for (var table : STORES) {
              int remaining = limit - deleted;
              if (remaining == 0) break;
              boolean batches = table.equals("usage_observation_batches");
              var keys =
                  db.query(
                      "SELECT device_id,registration_id,"
                          + (batches ? "sequence_number" : "0")
                          + " FROM "
                          + table
                          + " WHERE tenant_id=? AND "
                          + scope.predicate()
                          + " ORDER BY device_id"
                          + (batches ? ",sequence_number" : "")
                          + " LIMIT ? FOR UPDATE",
                      (r, n) -> new Key(r.getString(1), r.getString(2), r.getLong(3)),
                      args(
                          List.of(scope.request().tenantId()),
                          scope.parameters(),
                          List.of(remaining)));
              for (var key : keys) {
                var parameters =
                    new ArrayList<Object>(
                        List.of(scope.request().tenantId(), key.device(), key.registration()));
                if (batches) parameters.add(key.sequence());
                int count =
                    db.update(
                        "DELETE FROM "
                            + table
                            + " WHERE tenant_id=? AND device_id=? AND registration_id=?"
                            + (batches ? " AND sequence_number=?" : ""),
                        parameters.toArray());
                if (count != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
                deleted++;
              }
            }
            if (!hasData(scope)) phase = "DONE";
          }
          long time =
              db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class)
                  .toInstant()
                  .toEpochMilli();
          int written =
              db.update(
                  "UPDATE erasure_recovery_steps SET"
                      + " phase=?,cursor_id=?,rows_processed=?,batches_processed=?,updated_at=?"
                      + " WHERE request_id=? AND step_code=? AND handler_version=1",
                  phase,
                  cursor,
                  step.rows() + deleted,
                  step.batches() + 1,
                  time,
                  scope.request().requestId(),
                  STEP);
          if (written != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
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
              String phase = r.getString(2), cursor = r.getString(3);
              long processed = r.getLong(4), batches = r.getLong(5);
              if (!Set.of("REPORTS", "DATA", "DONE").contains(phase)
                  || processed < 0
                  || batches < 0
                  || (cursor != null && (!phase.equals("REPORTS") || !uuid(cursor))))
                throw failure("ERASURE_STEP_CORRUPT");
              return new Step(phase, cursor, processed, batches);
            },
            request,
            STEP);
    if (!rows.isEmpty()) return rows.get(0);
    db.update(
        "INSERT INTO"
            + " erasure_recovery_steps(request_id,step_code,handler_version,phase,rows_processed,batches_processed,updated_at)"
            + " VALUES(?,?,1,'REPORTS',0,0,0)",
        request,
        STEP);
    return new Step("REPORTS", null, 0, 0);
  }

  private Scope scope(ErasureLedger.Request request) {
    var registrations = new HashSet<>(request.registrations());
    var parameters = new ArrayList<Object>();
    var predicates = new ArrayList<String>();
    for (var registration : request.registrations()) {
      predicates.add("(device_id=? AND registration_id=?)");
      parameters.add(registration.deviceId());
      parameters.add(registration.registrationId());
    }
    String predicate = predicates.isEmpty() ? "1=0" : "(" + String.join(" OR ", predicates) + ")";
    var current =
        db.query(
            "SELECT id,registration_id FROM devices WHERE tenant_id=? AND subject_id=? LIMIT 1001",
            (r, n) -> new ErasureLedger.Registration(r.getString(1), r.getString(2)),
            request.tenantId(),
            request.subjectId());
    if (current.size() > 1000 || !registrations.containsAll(current))
      throw failure("ERASURE_SCOPE_CHANGED");
    if (!registrations.isEmpty()) {
      // SQL identifiers here are fixed schema constants, never caller input.
      String devicePredicate = predicate.replace("device_id", "id");
      var conflicts =
          db.queryForList(
              "SELECT 1 FROM devices WHERE tenant_id=? AND subject_id<>? AND "
                  + devicePredicate
                  + " LIMIT 1",
              args(List.of(request.tenantId(), request.subjectId()), parameters));
      if (!conflicts.isEmpty()) throw failure("ERASURE_SCOPE_CHANGED");
    }
    return new Scope(request, Set.copyOf(registrations), predicate, List.copyOf(parameters));
  }

  private int report(Scope scope, Report report) {
    if (!uuid(report.id())
        || report.selection() == null
        || report.total() < 1
        || report.total() > 200
        || !SecretMaterial.hash(report.selection()).equals(report.hash()))
      throw failure("ERASURE_REPORT_SCOPE_CORRUPT");
    var parts =
        db.query(
            "SELECT ordinal,device_id,registration_id,subject_id FROM usage_report_parts WHERE"
                + " tenant_id=? AND job_id=? ORDER BY ordinal LIMIT 201 FOR UPDATE",
            (r, n) -> new Part(r.getInt(1), r.getString(2), r.getString(3), r.getString(4)),
            scope.request().tenantId(),
            report.id());
    if (parts.size() != report.total()) throw failure("ERASURE_REPORT_SCOPE_CORRUPT");
    JsonNode selection;
    var selected = new HashSet<String>();
    try {
      selection = json.readTree(report.selection());
      if (!selection.isObject()
          || !selection.path("deviceIds").isArray()
          || selection.path("deviceIds").size() != report.total())
        throw new IllegalArgumentException();
      for (var value : selection.path("deviceIds")) {
        if (!value.isTextual() || !uuid(value.textValue()) || !selected.add(value.textValue()))
          throw new IllegalArgumentException();
      }
      var selectedScope = selection.path("scope");
      if (!selectedScope.isObject()
          || !selectedScope.path("kind").isTextual()
          || !Set.of("DEVICES", "SUBJECT", "CLASS")
              .contains(selectedScope.path("kind").textValue()))
        throw new IllegalArgumentException();
      if (!selectedScope.path("kind").textValue().equals("DEVICES")
          && !uuid(selectedScope.path("id").textValue())) throw new IllegalArgumentException();
    } catch (Exception invalid) {
      throw failure("ERASURE_REPORT_SCOPE_CORRUPT");
    }
    boolean affected = false;
    for (int n = 0; n < parts.size(); n++) {
      var part = parts.get(n);
      if (part.ordinal() != n
          || !uuid(part.registration())
          || !uuid(part.subject())
          || !selected.remove(part.device())) throw failure("ERASURE_REPORT_SCOPE_CORRUPT");
      if (selection.path("scope").path("kind").asText().equals("SUBJECT")
          && !part.subject().equals(selection.path("scope").path("id").asText()))
        throw failure("ERASURE_REPORT_SCOPE_CORRUPT");
      boolean matches =
          scope
              .registrations()
              .contains(new ErasureLedger.Registration(part.device(), part.registration()));
      boolean subject = part.subject().equals(scope.request().subjectId());
      if (matches != subject) throw failure("ERASURE_SCOPE_CHANGED");
      affected |= matches;
    }
    if (!selected.isEmpty()) throw failure("ERASURE_REPORT_SCOPE_CORRUPT");
    if (!affected) return 0;
    int removed =
        db.update(
            "DELETE FROM usage_report_parts WHERE tenant_id=? AND job_id=?",
            scope.request().tenantId(),
            report.id());
    if (removed != parts.size()
        || db.update(
                "DELETE FROM usage_report_jobs WHERE tenant_id=? AND id=?",
                scope.request().tenantId(),
                report.id())
            != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
    return removed + 1;
  }

  private boolean hasData(Scope scope) {
    for (var table : STORES) {
      if (!db.queryForList(
              "SELECT 1 FROM " + table + " WHERE tenant_id=? AND " + scope.predicate() + " LIMIT 1",
              args(List.of(scope.request().tenantId()), scope.parameters()))
          .isEmpty()) return true;
    }
    return false;
  }

  @SafeVarargs
  private static Object[] args(List<?>... groups) {
    var result = new ArrayList<Object>();
    for (var group : groups) result.addAll(group);
    return result.toArray();
  }

  private static boolean uuid(String value) {
    return value != null
        && value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
  }

  private static ErasureLedger.Failure failure(String code) {
    return new ErasureLedger.Failure(code);
  }
}

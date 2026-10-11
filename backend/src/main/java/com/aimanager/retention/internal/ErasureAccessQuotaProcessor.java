package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.json.JsonMapper;
import java.sql.Timestamp;
import java.time.LocalDate;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Internal domain step. Completion is not a global erasure or access-restoration certificate. */
@Component
class ErasureAccessQuotaProcessor {
  private static final String STEP = "ACCESS_QUOTA";

  // All identifiers and joins below are fixed, reviewed schema constants.
  private record Store(String table, List<String> keys, String owner) {}

  private static Store direct(String table, String... keys) {
    return new Store(table, List.of(keys), "t.subject_id=?");
  }

  private static Store request(String table, boolean document, String... keys) {
    String owner =
        document
            ? "EXISTS (SELECT 1 FROM access_window_documents d JOIN access_requests r ON"
                + " r.tenant_id=d.tenant_id AND r.id=d.request_id WHERE d.tenant_id=t.tenant_id"
                + " AND d.id=t.document_id AND r.subject_id=?)"
            : "EXISTS (SELECT 1 FROM access_requests r WHERE r.tenant_id=t.tenant_id AND"
                + " r.id=t.request_id AND r.subject_id=?)";
    return new Store(table, List.of(keys), owner);
  }

  private static Store quota(String table, String parent, String reference, String... keys) {
    return new Store(
        table,
        List.of(keys),
        "EXISTS (SELECT 1 FROM "
            + parent
            + " p WHERE p.tenant_id=t.tenant_id AND p.id=t."
            + reference
            + " AND p.subject_id=?)");
  }

  private static final List<Store> STORES =
      List.of(
          quota(
              "notification_reads",
              "notification_events",
              "notification_id",
              "notification_id",
              "actor_key"),
          direct("notification_events", "id"),
          request("access_window_attempt_receipts", true, "document_id", "attempt_number", "phase"),
          request("access_window_attempts", true, "document_id", "attempt_number"),
          request("access_window_receipts", true, "document_id", "phase"),
          request("access_window_documents", false, "id"),
          request("access_request_decisions", false, "request_id"),
          direct("access_request_slots", "subject_id", "registration_id", "application_id"),
          direct("access_requests", "id"),
          quota("quota_ledger", "quota_pools", "pool_id", "id"),
          quota("quota_lease_pools", "quota_leases", "lease_id", "lease_id", "pool_id"),
          direct("quota_leases", "id"),
          direct("quota_pools", "id"),
          quota("quota_plan_revisions", "quota_plans", "plan_id", "plan_id", "version"),
          direct("quota_plans", "id"),
          direct("quota_calendars", "subject_id"));

  private record EventShape(String table, String key, Set<String> fields) {}

  private static final Map<String, EventShape> EVENTS =
      Map.of(
          "QUOTA_POOL_CREATED", new EventShape("quota_pools", "poolId", Set.of("poolId", "source")),
          "QUOTA_ADJUSTED",
              new EventShape("quota_pools", "poolId", Set.of("poolId", "deltaSeconds")),
          "QUOTA_RESERVED",
              new EventShape("quota_leases", "leaseId", Set.of("leaseId", "reservedSeconds")),
          "QUOTA_SETTLED",
              new EventShape(
                  "quota_leases",
                  "leaseId",
                  Set.of("leaseId", "sequence", "cumulativeUsedSeconds", "finished")),
          "QUOTA_PLAN_CREATED",
              new EventShape("quota_plans", "planId", Set.of("planId", "version")),
          "QUOTA_PLAN_UPDATED",
              new EventShape(
                  "quota_plans", "planId", Set.of("planId", "version", "effectiveFrom")));
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

  private record Event(String id, String aggregate, String type, String payload) {}

  ErasureAccessQuotaProcessor(
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
          verifyLinks(scope.tenantId());
          var step = step(scope.requestId());
          if (!step.phase().equals("EVENTS")) verifyRemainingEvents(scope);
          if (step.rows() > Long.MAX_VALUE - limit || step.batches() == Long.MAX_VALUE)
            throw failure("ERASURE_STEP_CORRUPT");
          String phase = step.phase(), cursor = step.cursor();
          if (phase.equals("DONE")) {
            if (hasData(scope)) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
            phase = "RECHECK";
          } else if (phase.equals("DATA")) phase = "VERIFY";
          int deleted = 0;
          boolean eraseData = false;
          if (Set.of("EVENTS", "VERIFY", "RECHECK").contains(phase)) {
            var args = new ArrayList<Object>(List.of(scope.tenantId()));
            if (cursor != null) args.add(cursor);
            args.add(limit);
            var events =
                db.query(
                    "SELECT id,aggregate_id,event_type,CASE WHEN OCTET_LENGTH(event_json)<=65536"
                        + " THEN event_json ELSE NULL END FROM quota_outbox WHERE tenant_id=?"
                        + (cursor == null ? "" : " AND id>?")
                        + " ORDER BY id LIMIT ? FOR UPDATE",
                    (r, n) ->
                        new Event(r.getString(1), r.getString(2), r.getString(3), r.getString(4)),
                    args.toArray());
            for (var event : events) {
              if (eventSubject(scope.tenantId(), event).equals(scope.subjectId())) {
                if (!phase.equals("EVENTS")) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
                exactlyOne(
                    db.update(
                        "DELETE FROM quota_outbox WHERE tenant_id=? AND id=?",
                        scope.tenantId(),
                        event.id()));
                deleted++;
              }
              cursor = event.id();
            }
            if (events.size() < limit) {
              if (phase.equals("RECHECK")) {
                if (hasData(scope)) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
                phase = "DONE";
                if (step.phase().equals("DONE"))
                  return new Result("DONE", 0, step.rows(), step.batches());
              } else {
                eraseData = phase.equals("VERIFY");
                phase = "DATA";
              }
              cursor = null;
            }
          }
          if (eraseData) {
            for (var store : STORES) {
              int remaining = limit - deleted;
              if (remaining == 0) break;
              var keys =
                  db.query(
                      "SELECT "
                          + String.join(",", store.keys().stream().map(k -> "t." + k).toList())
                          + " FROM "
                          + store.table()
                          + " t WHERE t.tenant_id=? AND "
                          + store.owner()
                          + " ORDER BY "
                          + String.join(",", store.keys().stream().map(k -> "t." + k).toList())
                          + " LIMIT ? FOR UPDATE",
                      (r, n) -> {
                        var values = new ArrayList<Object>();
                        for (int i = 1; i <= store.keys().size(); i++) values.add(r.getObject(i));
                        return values;
                      },
                      scope.tenantId(),
                      scope.subjectId(),
                      remaining);
              for (var key : keys) {
                var args = new ArrayList<Object>(List.of(scope.tenantId()));
                args.addAll(key);
                exactlyOne(
                    db.update(
                        "DELETE FROM "
                            + store.table()
                            + " WHERE tenant_id=? AND "
                            + String.join(
                                " AND ", store.keys().stream().map(k -> k + "=?").toList()),
                        args.toArray()));
                deleted++;
              }
            }
            if (!hasData(scope)) phase = "DONE";
          }
          long time = db.queryForObject("SELECT CURRENT_TIMESTAMP", Timestamp.class).getTime();
          exactlyOne(
              db.update(
                  "UPDATE erasure_recovery_steps SET"
                      + " phase=?,cursor_id=?,rows_processed=?,batches_processed=?,updated_at=?"
                      + " WHERE request_id=? AND step_code=? AND handler_version=1",
                  phase,
                  cursor,
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
              String phase = r.getString(2), cursor = r.getString(3);
              long count = r.getLong(4), batches = r.getLong(5);
              if (!Set.of("EVENTS", "VERIFY", "RECHECK", "DATA", "DONE").contains(phase)
                  || count < 0
                  || batches < 0
                  || (cursor != null
                      && (!Set.of("EVENTS", "VERIFY", "RECHECK").contains(phase) || !uuid(cursor))))
                throw failure("ERASURE_STEP_CORRUPT");
              return new Step(phase, cursor, count, batches);
            },
            request,
            STEP);
    if (!rows.isEmpty()) return rows.get(0);
    db.update(
        "INSERT INTO"
            + " erasure_recovery_steps(request_id,step_code,handler_version,phase,rows_processed,batches_processed,updated_at)"
            + " VALUES(?,?,1,'EVENTS',0,0,0)",
        request,
        STEP);
    return new Step("EVENTS", null, 0, 0);
  }

  private void verifyScope(ErasureLedger.Request scope) {
    var accepted = new HashSet<>(scope.registrations());
    var current =
        db.query(
            "SELECT id,registration_id FROM devices WHERE tenant_id=? AND subject_id=? LIMIT 1001",
            (r, n) -> new ErasureLedger.Registration(r.getString(1), r.getString(2)),
            scope.tenantId(),
            scope.subjectId());
    if (current.size() > 1000 || !accepted.containsAll(current))
      throw failure("ERASURE_SCOPE_CHANGED");
    var pairs = new ArrayList<String>();
    var values = new ArrayList<Object>();
    for (var item : scope.registrations()) {
      pairs.add("(device_id=? AND registration_id=?)");
      values.add(item.deviceId());
      values.add(item.registrationId());
    }
    String predicate = pairs.isEmpty() ? "1=0" : "(" + String.join(" OR ", pairs) + ")";
    for (var table : List.of("devices", "access_requests", "quota_leases")) {
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
    var registrations =
        scope.registrations().stream()
            .map(ErasureLedger.Registration::registrationId)
            .distinct()
            .toList();
    String match =
        registrations.isEmpty()
            ? "1=0"
            : "registration_id IN ("
                + String.join(",", Collections.nCopies(registrations.size(), "?"))
                + ")";
    var args = new ArrayList<Object>(List.of(scope.tenantId(), scope.subjectId()));
    args.addAll(registrations);
    args.add(scope.subjectId());
    args.addAll(registrations);
    if (exists(
        "SELECT 1 FROM access_request_slots WHERE tenant_id=? AND ((subject_id=? AND NOT ("
            + match
            + ")) OR (subject_id<>? AND "
            + match
            + ")) LIMIT 1",
        args.toArray())) throw failure("ERASURE_SCOPE_CHANGED");
  }

  private void verifyLinks(String tenant) {
    if (exists(
        "SELECT 1 FROM notification_events n JOIN access_requests r ON r.tenant_id=n.tenant_id AND"
            + " r.id=n.request_id WHERE n.tenant_id=? AND (n.subject_id<>r.subject_id OR"
            + " n.device_id<>r.device_id) LIMIT 1",
        tenant)) throw failure("ERASURE_NOTIFICATION_SCOPE_CORRUPT");
    for (String query :
        List.of(
            "SELECT 1 FROM quota_lease_pools x JOIN quota_leases l ON l.tenant_id=x.tenant_id AND"
                + " l.id=x.lease_id JOIN quota_pools p ON p.tenant_id=x.tenant_id AND"
                + " p.id=x.pool_id WHERE x.tenant_id=? AND l.subject_id<>p.subject_id LIMIT 1",
            "SELECT 1 FROM quota_ledger x JOIN quota_pools p ON p.tenant_id=x.tenant_id AND"
                + " p.id=x.pool_id LEFT JOIN quota_leases l ON l.tenant_id=x.tenant_id AND"
                + " l.id=x.lease_id WHERE x.tenant_id=? AND x.lease_id IS NOT NULL AND (l.id IS"
                + " NULL OR l.subject_id<>p.subject_id) LIMIT 1",
            "SELECT 1 FROM quota_pools p JOIN quota_plans q ON q.tenant_id=p.tenant_id AND"
                + " q.id=p.plan_id WHERE p.tenant_id=? AND p.subject_id<>q.subject_id LIMIT 1")) {
      if (exists(query, tenant)) throw failure("ERASURE_QUOTA_SCOPE_CORRUPT");
    }
    if (exists(
        "SELECT 1 FROM access_request_slots s JOIN access_requests r ON r.tenant_id=s.tenant_id AND"
            + " r.id=s.last_request_id WHERE s.tenant_id=? AND (s.subject_id<>r.subject_id OR"
            + " s.registration_id<>r.registration_id OR s.application_id<>r.application_id) LIMIT"
            + " 1",
        tenant)) throw failure("ERASURE_SCOPE_CHANGED");
  }

  private String eventSubject(String tenant, Event event) {
    var shape = EVENTS.get(event.type());
    if (shape == null || !uuid(event.id()) || !uuid(event.aggregate()) || event.payload() == null)
      throw failure("ERASURE_QUOTA_EVENT_CORRUPT");
    try {
      JsonNode node = json.readTree(event.payload());
      var fields = new HashSet<String>();
      if (node != null) node.fieldNames().forEachRemaining(fields::add);
      if (node == null
          || !node.isObject()
          || !fields.equals(shape.fields())
          || !node.path(shape.key()).isTextual()
          || !event.aggregate().equals(node.path(shape.key()).textValue()))
        throw new IllegalArgumentException();
      for (var field : fields) {
        var value = node.path(field);
        if (field.equals(shape.key())) continue;
        if (field.equals("source")) {
          if (!value.isTextual() || !Set.of("MANUAL", "PLAN").contains(value.textValue()))
            throw new IllegalArgumentException();
        } else if (field.equals("finished")) {
          if (!value.isBoolean()) throw new IllegalArgumentException();
        } else if (field.equals("effectiveFrom")) {
          if (!value.isTextual()) throw new IllegalArgumentException();
          LocalDate.parse(value.textValue());
        } else if (!value.isIntegralNumber()
            || !value.canConvertToLong()
            || (!field.equals("deltaSeconds") && value.longValue() < 0))
          throw new IllegalArgumentException();
      }
    } catch (Exception invalid) {
      throw failure("ERASURE_QUOTA_EVENT_CORRUPT");
    }
    var subjects =
        db.queryForList(
            "SELECT subject_id FROM " + shape.table() + " WHERE tenant_id=? AND id=?",
            String.class,
            tenant,
            event.aggregate());
    if (subjects.size() != 1 || !uuid(subjects.get(0)))
      throw failure("ERASURE_QUOTA_EVENT_CORRUPT");
    return subjects.get(0);
  }

  private void verifyRemainingEvents(ErasureLedger.Request scope) {
    String types = String.join(",", EVENTS.keySet().stream().map(t -> "'" + t + "'").toList());
    if (exists(
        "SELECT 1 FROM quota_outbox WHERE tenant_id=? AND event_type NOT IN ("
            + types
            + ") LIMIT 1",
        scope.tenantId())) throw failure("ERASURE_QUOTA_EVENT_CORRUPT");
    for (var entry : EVENTS.entrySet()) {
      String parent =
          "SELECT 1 FROM "
              + entry.getValue().table()
              + " p WHERE p.tenant_id=e.tenant_id AND p.id=e.aggregate_id";
      if (exists(
          "SELECT 1 FROM quota_outbox e WHERE e.tenant_id=? AND e.event_type=? AND NOT EXISTS ("
              + parent
              + ") LIMIT 1",
          scope.tenantId(),
          entry.getKey())) throw failure("ERASURE_QUOTA_EVENT_CORRUPT");
      if (exists(
          "SELECT 1 FROM quota_outbox e WHERE e.tenant_id=? AND e.event_type=? AND EXISTS ("
              + parent
              + " AND p.subject_id=?) LIMIT 1",
          scope.tenantId(),
          entry.getKey(),
          scope.subjectId())) throw failure("ERASURE_STEP_RECHECK_REQUIRED");
    }
  }

  private boolean hasData(ErasureLedger.Request scope) {
    for (var store : STORES)
      if (exists(
          "SELECT 1 FROM "
              + store.table()
              + " t WHERE t.tenant_id=? AND "
              + store.owner()
              + " LIMIT 1",
          scope.tenantId(),
          scope.subjectId())) return true;
    return false;
  }

  private boolean exists(String query, Object... args) {
    return !db.queryForList(query, args).isEmpty();
  }

  private static boolean uuid(String value) {
    return value != null
        && value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
  }

  private static void exactlyOne(int count) {
    if (count != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
  }

  private static ErasureLedger.Failure failure(String code) {
    return new ErasureLedger.Failure(code);
  }
}

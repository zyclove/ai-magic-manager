package com.aimanager.retention.internal;

import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.identity.ActorKeys;
import com.aimanager.retention.ErasureLedger;
import com.aimanager.shared.SecretMaterial;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Set;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/**
 * Internal response-copy step under the global recovery pause. Completion never denotes completed
 * subject erasure or permits normal writers to resume.
 */
@Component
class ErasureIdempotencyProcessor {
  private static final String STEP = "IDEMPOTENCY_RESPONSES";
  private static final String ZERO_HASH = "0".repeat(64);
  private static final String MATCH =
      "scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?";
  private static final String JOIN =
      "o.scope_id=r.scope_id AND o.actor_key=r.actor_key"
          + " AND o.operation_key=r.operation_key AND o.key_hash=r.key_hash";
  private static final String UUID_PATTERN =
      "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
  private static final String TARGET_DATA =
      "(r.response_state<>'ERASED' OR r.response_body IS NOT NULL OR r.actor_id<>''"
          + " OR r.operation<>'' OR r.request_hash<>'" + ZERO_HASH + "')";
  private final ErasureRecoveryJobs jobs;
  private final JdbcTemplate db;
  private final SubjectDataCatalog catalog;

  record Result(
      String phase,
      int redactedRows,
      long totalRows,
      long batches,
      boolean classificationBlocked) {
    boolean complete() {
      return phase.equals("DONE");
    }
  }

  private record Step(String phase, String cursor, long rows, long batches) {}

  private record Key(String scope, String actor, String operation, String key) {
    Object[] arguments() {
      return new Object[] {scope, actor, operation, key};
    }
  }

  private record Discovered(String id, Key key) {}

  private static final Comparator<Key> KEY_ORDER =
      Comparator.comparing(Key::scope)
          .thenComparing(Key::actor)
          .thenComparing(Key::operation)
          .thenComparing(Key::key);

  private static final Comparator<Discovered> LOCK_ORDER =
      Comparator.comparing(Discovered::key, KEY_ORDER);

  private record Response(
      String id, Key key, String actor, String operation, String requestHash, String state,
      boolean bodyAbsent) {}

  private record Owner(String id, String tenant, String subject) {}

  private record OwnerRow(Key key, Owner owner) {}

  ErasureIdempotencyProcessor(
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
          var step = step(scope.requestId());
          if (step.phase().equals("DONE")) {
            if (unclassified() || hasTargetData(scope))
              throw failure("ERASURE_STEP_RECHECK_REQUIRED");
          }
          if (step.rows() > Long.MAX_VALUE - limit || step.batches() == Long.MAX_VALUE)
            throw failure("ERASURE_STEP_CORRUPT");

          String phase;
          String cursor = null;
          int redacted = 0;
          boolean blocked = false;
          if (step.phase().equals("DATA")) {
            // Discover without locking owners first. Normal mutations acquire the parent before
            // its ownership rows; the erasure path uses the same order and rechecks every owner.
            var discovered =
                db.query(
                    "SELECT r.id,r.scope_id,r.actor_key,r.operation_key,r.key_hash"
                        + " FROM idempotency_requests r JOIN idempotency_subject_owners o ON "
                        + JOIN
                        + " WHERE o.tenant_id=? AND o.subject_key=? AND "
                        + TARGET_DATA
                        + " ORDER BY r.scope_id,r.actor_key,r.operation_key,r.key_hash LIMIT ?",
                    (r, n) -> new Discovered(r.getString(1),
                        new Key(r.getString(2), r.getString(3), r.getString(4), r.getString(5))),
                    scope.tenantId(),
                    ResponseOwnership.subjectKey(scope.tenantId(), scope.subjectId()),
                    limit);
            var ordered = new ArrayList<>(discovered);
            ordered.sort(LOCK_ORDER);
            for (var selected : ordered) {
              var key = selected.key();
              var response = lock(selected);
              var owners = owners(key);
              if (response.state().equals("ERASED") && !cleanMarker(response))
                throw failure("ERASURE_STEP_RECHECK_REQUIRED");
              validate(response, owners);
              // A different valid subject job may have redacted a shared response after discovery.
              // Its retained, valid tombstone does not represent a reappearing source.
              if (response.state().equals("ERASED")) continue;
              if (!response.state().equals("SCOPED")
                  || owners.stream().noneMatch(o -> o.tenant().equals(scope.tenantId())
                      && o.subject().equals(
                          ResponseOwnership.subjectKey(scope.tenantId(), scope.subjectId()))))
                throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
              exactlyOne(
                  db.update(
                      "UPDATE idempotency_requests SET response_body=NULL,actor_id='',operation='',"
                          + "request_hash='" + ZERO_HASH + "',response_state='ERASED' WHERE "
                          + MATCH + " AND response_state='SCOPED'",
                      key.arguments()));
              redacted++;
            }
            phase = hasTargetData(scope) ? "DATA" : "VERIFY";
          } else if (step.phase().equals("RECHECK")) {
            var page = ownerVerificationPage(step.cursor(), limit);
            blocked = unclassified();
            if (blocked) {
              phase = "VERIFY";
            } else if (hasTargetData(scope)) {
              phase = "DATA";
            } else if (page.size() == limit) {
              phase = "RECHECK";
              cursor = page.get(page.size() - 1).owner().id();
            } else {
              phase = "DONE";
            }
          } else {
            // Verification is a subsequent batch. An unknown copy can block completion without
            // rolling back response copies already safely redacted by earlier DATA batches.
            var page = verificationPage(step.phase().equals("DONE") ? null : step.cursor(), limit);
            blocked = unclassified();
            if (blocked) {
              // Classification can have changed an earlier row while this step was blocked.
              // Restart the parent scan after resolution instead of trusting its previous cursor.
              phase = "VERIFY";
            } else if (hasTargetData(scope)) {
              phase = "DATA";
            } else if (page.size() == limit) {
              phase = "VERIFY";
              cursor = page.get(page.size() - 1).id();
            } else {
              // Parent enumeration cannot reveal restored ownership rows whose parent is absent.
              // Enumerate those independently before making this step complete.
              phase = "RECHECK";
            }
          }
          exactlyOne(
              db.update(
                  "UPDATE erasure_recovery_steps SET phase=?,cursor_id=?,rows_processed=?,"
                      + "batches_processed=?,updated_at=? WHERE request_id=? AND step_code=?"
                      + " AND handler_version=1",
                  phase,
                  cursor,
                  step.rows() + redacted,
                  step.batches() + 1,
                  now(),
                  scope.requestId(),
                  STEP));
          return new Result(phase, redacted, step.rows() + redacted, step.batches() + 1, blocked);
        });
  }

  private Response lock(Discovered selected) {
    var response = lockParent(selected.key());
    if (response == null || !selected.id().equals(response.id()))
      throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
    return response;
  }

  private Response lockParent(Key key) {
    var rows =
        db.query(
            "SELECT id,actor_id,operation,request_hash,response_state,"
                + "CASE WHEN response_body IS NULL THEN TRUE ELSE FALSE END AS body_absent"
                + " FROM idempotency_requests WHERE " + MATCH + " FOR UPDATE",
            (r, n) -> new Response(r.getString(1), key, r.getString(2), r.getString(3),
                r.getString(4), r.getString(5), r.getBoolean(6)),
            key.arguments());
    if (rows.size() > 1) throw corrupt();
    return rows.isEmpty() ? null : rows.get(0);
  }

  private List<Owner> owners(Key key) {
    var owners =
        db.query(
            "SELECT id,tenant_id,subject_key FROM idempotency_subject_owners WHERE " + MATCH
                + " ORDER BY tenant_id,subject_key LIMIT 101 FOR UPDATE",
            (r, n) -> new Owner(r.getString(1), r.getString(2), r.getString(3)),
            key.arguments());
    if (owners.size() > 100) throw corrupt();
    return owners;
  }

  private void validate(Response response, List<Owner> owners) {
    var key = response.key();
    if (!uuid(response.id()) || !hex(key.actor()) || !hex(key.operation()) || !hex(key.key())
        || !hex(response.requestHash())
        || response.state() == null
        || !Set.of("SCOPED", "NON_SUBJECT", "UNCLASSIFIED", "ERASED").contains(response.state()))
      throw corrupt();
    if (response.state().equals("ERASED")) {
      if (!cleanMarker(response)) throw corrupt();
    } else {
      if (response.actor() == null || response.actor().isBlank()
          || response.operation() == null || response.operation().isBlank()
          || !ActorKeys.key(response.actor()).equals(key.actor())
          || !SecretMaterial.hash(response.operation()).equals(key.operation())
          || (!response.state().equals("UNCLASSIFIED") && response.bodyAbsent()))
        throw corrupt();
    }
    if (Set.of("SCOPED", "ERASED").contains(response.state())) {
      if (!uuid(key.scope()) || owners.isEmpty()) throw corrupt();
      for (var owner : owners)
        if (!uuid(owner.id()) || !key.scope().equals(owner.tenant()) || !hex(owner.subject()))
          throw corrupt();
    } else if (!owners.isEmpty()) throw corrupt();
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
              if (!Set.of("DATA", "VERIFY", "RECHECK", "DONE").contains(phase)
                  || (cursor != null
                      && (!Set.of("VERIFY", "RECHECK").contains(phase) || !uuid(cursor)))
                  || processed < 0 || batches < 0)
                throw failure("ERASURE_STEP_CORRUPT");
              return new Step(phase, cursor, processed, batches);
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
    return new Step("DATA", null, 0, 0);
  }

  private boolean hasTargetData(ErasureLedger.Request scope) {
    return exists(
        "SELECT 1 FROM idempotency_requests r JOIN idempotency_subject_owners o ON "
            + JOIN + " WHERE o.tenant_id=? AND o.subject_key=? AND " + TARGET_DATA + " LIMIT 1",
        scope.tenantId(),
        ResponseOwnership.subjectKey(scope.tenantId(), scope.subjectId()));
  }

  private boolean unclassified() {
    // scope_id includes global operations, so tenant filtering would silently miss possible copies.
    return exists("SELECT 1 FROM idempotency_requests WHERE response_state='UNCLASSIFIED' LIMIT 1");
  }

  private List<Discovered> verificationPage(String cursor, int limit) {
    var arguments = new ArrayList<Object>();
    if (cursor != null) arguments.add(cursor);
    arguments.add(limit);
    var page =
        db.query(
            "SELECT id,scope_id,actor_key,operation_key,key_hash FROM idempotency_requests"
                + (cursor == null ? "" : " WHERE id>?") + " ORDER BY id LIMIT ?",
            (r, n) -> new Discovered(r.getString(1),
                new Key(r.getString(2), r.getString(3), r.getString(4), r.getString(5))),
            arguments.toArray());
    var ordered = new ArrayList<>(page);
    ordered.sort(LOCK_ORDER);
    for (var selected : ordered) {
      var response = lock(selected);
      validate(response, owners(selected.key()));
    }
    return page;
  }

  private List<OwnerRow> ownerVerificationPage(String cursor, int limit) {
    var arguments = new ArrayList<Object>();
    if (cursor != null) arguments.add(cursor);
    arguments.add(limit);
    var page =
        db.query(
            "SELECT id,scope_id,actor_key,operation_key,key_hash,tenant_id,subject_key"
                + " FROM idempotency_subject_owners"
                + (cursor == null ? "" : " WHERE id>?") + " ORDER BY id LIMIT ?",
            (r, n) -> new OwnerRow(
                new Key(r.getString(2), r.getString(3), r.getString(4), r.getString(5)),
                new Owner(r.getString(1), r.getString(6), r.getString(7))),
            arguments.toArray());
    var ordered = new ArrayList<>(page);
    ordered.sort(Comparator.comparing(OwnerRow::key, KEY_ORDER)
        .thenComparing(row -> row.owner().id()));
    Key previous = null;
    Response parent = null;
    for (var selected : ordered) {
      var key = selected.key();
      if (!key.equals(previous)) {
        parent = lockParent(key);
        if (parent == null) throw corrupt();
        previous = key;
      }
      // Parent first, then this exact owner. This also detects ownership restored with foreign-key
      // checks disabled; a parent-only scan would silently omit such an orphan.
      var expected = selected.owner();
      var owners =
          db.query(
              "SELECT id,tenant_id,subject_key FROM idempotency_subject_owners WHERE " + MATCH
                  + " AND id=? AND tenant_id=? AND subject_key=? FOR UPDATE",
              (r, n) -> new Owner(r.getString(1), r.getString(2), r.getString(3)),
              key.scope(), key.actor(), key.operation(), key.key(),
              expected.id(), expected.tenant(), expected.subject());
      if (owners.size() != 1 || !expected.equals(owners.get(0)))
        throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
      validate(parent, owners);
    }
    return page;
  }

  private static boolean cleanMarker(Response response) {
    return response.bodyAbsent() && "".equals(response.actor())
        && "".equals(response.operation()) && ZERO_HASH.equals(response.requestHash());
  }

  private boolean exists(String sql, Object... arguments) {
    return !db.queryForList(sql, arguments).isEmpty();
  }

  private long now() {
    return db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
  }

  private static boolean hex(String value) {
    return value != null && value.matches("[0-9a-f]{64}");
  }

  private static boolean uuid(String value) {
    return value != null && value.matches(UUID_PATTERN);
  }

  private static void exactlyOne(int changed) {
    if (changed != 1) throw failure("ERASURE_STEP_CONCURRENT_CHANGE");
  }

  private static ErasureLedger.Failure corrupt() {
    return failure("ERASURE_IDEMPOTENCY_SCOPE_CORRUPT");
  }

  private static ErasureLedger.Failure failure(String code) {
    return new ErasureLedger.Failure(code);
  }
}

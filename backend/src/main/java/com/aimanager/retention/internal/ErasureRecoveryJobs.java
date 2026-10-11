package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.MapperFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import java.nio.charset.StandardCharsets;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.*;
import java.util.function.Supplier;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionException;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Durable journal projection, not proof of isolation or completed erasure. Lock order: recovery
 * head then jobs; lease operations lock a job only. Deliberately no completion operation and no
 * automatic deletion worker.
 */
@Component
class ErasureRecoveryJobs {
  record Batch(
      int imported,
      ErasureLedger.Checkpoint read,
      ErasureLedger.Checkpoint head,
      boolean endOfSnapshot) {}

  record Job(String ledgerId, ErasureLedger.Entry entry, String state, long fence) {}

  record Claim(Job job, String worker, long fence, long until) {}

  enum RetryReason {
    HANDLER_UNAVAILABLE,
    STORAGE_UNAVAILABLE,
    EXTERNAL_PENDING
  }

  private record Stored(Job job, String owner, Long until, long next) {}

  private static final String COLUMNS =
      "ledger_id,sequence_number,request_id,tenant_id,subject_id,CASE WHEN"
          + " OCTET_LENGTH(request_json)<=262144 THEN request_json ELSE NULL END AS request_json,"
          + "request_hash,previous_hash,entry_hash,accepted_at,state,fence,lease_owner,lease_until,next_attempt_at";
  private final JdbcTemplate db;
  private final ErasureLedger ledger;
  private final TransactionTemplate tx;
  private final JsonMapper json =
      JsonMapper.builder()
          .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .disable(MapperFeature.ALLOW_COERCION_OF_SCALARS)
          .build();

  ErasureRecoveryJobs(JdbcTemplate db, PlatformTransactionManager manager, ErasureLedger ledger) {
    this.db = db;
    this.ledger = ledger;
    tx = new TransactionTemplate(manager);
    tx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    tx.setTimeout(20);
  }

  Batch reconcile(int limit) {
    if (limit < 1 || limit > 100) throw new IllegalArgumentException("Invalid recovery batch size");
    var observed = ledger.head();
    return transaction(
        () -> {
          db.update(
              "INSERT INTO"
                  + " erasure_recovery_state(singleton_id,ledger_id,read_sequence,read_hash,updated_at)"
                  + " VALUES(1,?,0,?,?) ON DUPLICATE KEY UPDATE singleton_id=singleton_id",
              observed.ledgerId(),
              LedgerIntegrity.genesis(observed.ledgerId()),
              now());
          var cursor =
              db.queryForObject(
                  "SELECT ledger_id,read_sequence,read_hash FROM erasure_recovery_state WHERE"
                      + " singleton_id=1 FOR UPDATE",
                  (r, n) -> checkpoint(r.getString(1), r.getLong(2), r.getString(3)));
          if (!cursor.ledgerId().equals(observed.ledgerId()))
            throw failure("ERASURE_RECOVERY_IDENTITY_MISMATCH");
          // A valid tail cannot conceal missing previously imported jobs. Sequence numbers are
          // unique
          // and positive, so this count proves presence of every position through the cursor.
          long retained =
              db.queryForObject(
                  "SELECT COUNT(*) FROM erasure_recovery_jobs WHERE ledger_id=? AND"
                      + " sequence_number<=?",
                  Long.class,
                  cursor.ledgerId(),
                  cursor.sequence());
          if (retained != cursor.sequence()) throw corrupt();
          if (cursor.sequence() > 0) {
            var anchors =
                db.query(
                    "SELECT "
                        + COLUMNS
                        + " FROM erasure_recovery_jobs WHERE ledger_id=? AND sequence_number=?",
                    this::row,
                    cursor.ledgerId(),
                    cursor.sequence());
            if (anchors.size() != 1 || !anchors.get(0).job().entry().hash().equals(cursor.hash()))
              throw corrupt();
          }
          var page = ledger.readAfter(cursor, limit);
          if (!page.head().ledgerId().equals(cursor.ledgerId()) || page.entries().size() > limit)
            throw corrupt();
          long sequence = cursor.sequence();
          String previous = cursor.hash();
          int imported = 0;
          for (var entry : page.entries()) {
            if (sequence == Long.MAX_VALUE
                || entry.sequence() != sequence + 1
                || !entry.previousHash().equals(previous)) throw corrupt();
            validateEntry(cursor.ledgerId(), entry);
            var existing = load(entry.request().requestId(), true);
            if (existing == null) {
              String payload = encode(entry.request());
              long time = now();
              db.update(
                  "INSERT INTO"
                      + " erasure_recovery_jobs(request_id,ledger_id,sequence_number,tenant_id,subject_id,request_json,request_hash,previous_hash,entry_hash,accepted_at,state,fence,next_attempt_at,created_at,updated_at)"
                      + " VALUES(?,?,?,?,?,?,?,?,?,?,'ACCEPTED',0,0,?,?)",
                  entry.request().requestId(),
                  cursor.ledgerId(),
                  entry.sequence(),
                  entry.request().tenantId(),
                  entry.request().subjectId(),
                  payload,
                  LedgerIntegrity.requestHash(entry.request()),
                  entry.previousHash(),
                  entry.hash(),
                  entry.acceptedAt(),
                  time,
                  time);
              imported++;
            } else if (!existing.job().ledgerId().equals(cursor.ledgerId())
                || !existing.job().entry().equals(entry)) throw corrupt();
            sequence = entry.sequence();
            previous = entry.hash();
          }
          var next = checkpoint(cursor.ledgerId(), sequence, previous);
          if (!next.equals(page.nextRead())
              || next.sequence() > page.head().sequence()
              || page.endOfSnapshot() != (next.equals(page.head()))
              || (page.entries().isEmpty() && !page.endOfSnapshot())) throw corrupt();
          db.update(
              "UPDATE erasure_recovery_state SET read_sequence=?,read_hash=?,updated_at=? WHERE"
                  + " singleton_id=1",
              next.sequence(),
              next.hash(),
              now());
          return new Batch(imported, next, page.head(), page.endOfSnapshot());
        });
  }

  Job find(String requestId) {
    uuid(requestId);
    return transaction(
        () -> {
          var stored = load(requestId, false);
          return stored == null ? null : stored.job();
        });
  }

  Claim claim(String worker, int seconds) {
    uuid(worker);
    leaseSeconds(seconds);
    return transaction(
        () -> {
          long time = now();
          var rows =
              db.query(
                  "SELECT "
                      + COLUMNS
                      + " FROM erasure_recovery_jobs WHERE (state IN ('ACCEPTED','RETRY_REQUIRED')"
                      + " AND next_attempt_at<=?) OR (state='CLAIMED' AND lease_until<=?) ORDER BY"
                      + " sequence_number LIMIT 1 FOR UPDATE",
                  this::row,
                  time,
                  time);
          if (rows.isEmpty()) return null;
          var stored = rows.get(0);
          var job = stored.job();
          var entry = job.entry();
          // Compare to the independent journal, not just consistent hashes in the business mirror.
          var page =
              ledger.readAfter(
                  checkpoint(job.ledgerId(), entry.sequence() - 1, entry.previousHash()), 1);
          if (page.entries().size() != 1 || !entry.equals(page.entries().get(0))) throw corrupt();
          if (job.fence() == Long.MAX_VALUE) throw failure("ERASURE_RECOVERY_FENCE_EXHAUSTED");
          long fence = job.fence() + 1;
          time = now();
          long until = time + seconds * 1000L;
          db.update(
              "UPDATE erasure_recovery_jobs SET"
                  + " state='CLAIMED',fence=?,lease_owner=?,lease_until=?,failure_code=NULL,updated_at=?"
                  + " WHERE request_id=?",
              fence,
              worker,
              until,
              time,
              entry.request().requestId());
          return new Claim(new Job(job.ledgerId(), entry, "CLAIMED", fence), worker, fence, until);
        });
  }

  Claim renew(Claim claim, int seconds) {
    Objects.requireNonNull(claim);
    leaseSeconds(seconds);
    return transaction(
        () -> {
          var stored = lease(claim);
          long time = now();
          long until = Math.max(stored.until(), time + seconds * 1000L);
          db.update(
              "UPDATE erasure_recovery_jobs SET lease_until=?,updated_at=? WHERE request_id=?",
              until,
              time,
              claim.job().entry().request().requestId());
          return new Claim(stored.job(), claim.worker(), claim.fence(), until);
        });
  }

  void retry(Claim claim, RetryReason reason, int delaySeconds) {
    Objects.requireNonNull(claim);
    Objects.requireNonNull(reason);
    if (delaySeconds < 0 || delaySeconds > 86400)
      throw new IllegalArgumentException("Invalid recovery retry delay");
    transaction(
        () -> {
          lease(claim);
          long time = now();
          db.update(
              "UPDATE erasure_recovery_jobs SET"
                  + " state='RETRY_REQUIRED',lease_owner=NULL,lease_until=NULL,next_attempt_at=?,failure_code=?,updated_at=?"
                  + " WHERE request_id=?",
              time + delaySeconds * 1000L,
              reason.name(),
              time,
              claim.job().entry().request().requestId());
          return null;
        });
  }

  private Stored lease(Claim claim) {
    var stored = load(claim.job().entry().request().requestId(), true);
    if (stored == null
        || !stored.job().state().equals("CLAIMED")
        || !Objects.equals(stored.owner(), claim.worker())
        || stored.job().fence() != claim.fence()
        || stored.until() <= now()
        || !stored.job().ledgerId().equals(claim.job().ledgerId())
        || !stored.job().entry().equals(claim.job().entry()))
      throw failure("ERASURE_RECOVERY_LEASE_LOST");
    return stored;
  }

  private Stored load(String requestId, boolean lock) {
    var rows =
        db.query(
            "SELECT "
                + COLUMNS
                + " FROM erasure_recovery_jobs WHERE request_id=?"
                + (lock ? " FOR UPDATE" : ""),
            this::row,
            requestId);
    return rows.isEmpty() ? null : rows.get(0);
  }

  private Stored row(ResultSet r, int ignored) throws SQLException {
    try {
      var request = json.readValue(r.getString("request_json"), ErasureLedger.Request.class);
      if (!request.requestId().equals(r.getString("request_id"))
          || !request.tenantId().equals(r.getString("tenant_id"))
          || !request.subjectId().equals(r.getString("subject_id"))
          || !LedgerIntegrity.requestHash(request).equals(r.getString("request_hash")))
        throw corrupt();
      String ledgerId = r.getString("ledger_id");
      var entry =
          new ErasureLedger.Entry(
              r.getLong("sequence_number"),
              request,
              r.getLong("accepted_at"),
              r.getString("previous_hash"),
              r.getString("entry_hash"));
      validateEntry(ledgerId, entry);
      String state = r.getString("state"), owner = r.getString("lease_owner");
      Long until = (Long) r.getObject("lease_until");
      long fence = r.getLong("fence"), next = r.getLong("next_attempt_at");
      if (!Set.of("ACCEPTED", "CLAIMED", "RETRY_REQUIRED").contains(state) || fence < 0 || next < 0)
        throw corrupt();
      if (state.equals("CLAIMED")) {
        uuid(owner);
        if (until == null || until <= 0 || fence == 0) throw corrupt();
      } else if (owner != null || until != null) throw corrupt();
      return new Stored(new Job(ledgerId, entry, state, fence), owner, until, next);
    } catch (Exception invalid) {
      throw corrupt();
    }
  }

  private void validateEntry(String ledgerId, ErasureLedger.Entry entry) {
    try {
      checkpoint(ledgerId, entry.sequence(), entry.hash());
      checkpoint(ledgerId, Math.max(0, entry.sequence() - 1), entry.previousHash());
      if (entry.sequence() < 1
          || entry.acceptedAt() <= 0
          || !LedgerIntegrity.entryHash(
                  ledgerId,
                  entry.sequence(),
                  entry.acceptedAt(),
                  entry.previousHash(),
                  LedgerIntegrity.requestHash(entry.request()))
              .equals(entry.hash())) throw corrupt();
    } catch (RuntimeException invalid) {
      throw corrupt();
    }
  }

  private String encode(ErasureLedger.Request request) {
    try {
      String payload = json.writeValueAsString(request);
      if (payload.getBytes(StandardCharsets.UTF_8).length > 262144) throw corrupt();
      return payload;
    } catch (Exception invalid) {
      throw corrupt();
    }
  }

  private long now() {
    long time =
        db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class)
            .toInstant()
            .toEpochMilli();
    if (time <= 0 || time > Long.MAX_VALUE - 86400000L)
      throw failure("ERASURE_RECOVERY_CLOCK_INVALID");
    return time;
  }

  private static ErasureLedger.Checkpoint checkpoint(String id, long sequence, String hash) {
    try {
      return new ErasureLedger.Checkpoint(id, sequence, hash);
    } catch (RuntimeException invalid) {
      throw corrupt();
    }
  }

  private static void uuid(String value) {
    if (value == null
        || !value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
      throw new IllegalArgumentException("Invalid recovery identifier");
  }

  private static void leaseSeconds(int seconds) {
    if (seconds < 5 || seconds > 300)
      throw new IllegalArgumentException("Invalid recovery lease duration");
  }

  private <T> T transaction(Supplier<T> action) {
    try {
      return tx.execute(status -> action.get());
    } catch (DataAccessException | TransactionException unavailable) {
      throw failure("ERASURE_RECOVERY_UNAVAILABLE");
    }
  }

  private static ErasureLedger.Failure failure(String code) {
    return new ErasureLedger.Failure(code);
  }

  private static ErasureLedger.Failure corrupt() {
    return failure("ERASURE_RECOVERY_CORRUPT");
  }
}

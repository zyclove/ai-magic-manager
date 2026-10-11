package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.MapperFeature;
import com.fasterxml.jackson.databind.json.JsonMapper;
import java.time.Clock;
import java.util.*;
import java.util.function.Supplier;
import javax.sql.DataSource;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

/** Own transaction manager: accepting a journal record cannot roll back with business work. */
final class JdbcErasureLedger implements ErasureLedger {
  private static final Map<String, Set<String>> SCHEMA =
      Map.of(
          "erasure_ledger_head",
              Set.of("singleton_id", "ledger_id", "format_version", "last_sequence", "last_hash"),
          "erasure_ledger_entries",
              Set.of(
                  "sequence_number",
                  "request_id",
                  "request_hash",
                  "request_json",
                  "accepted_at",
                  "previous_hash",
                  "entry_hash"),
          "erasure_work_admissions", Set.of("admission_id", "worker_id", "started_at"),
          "erasure_admission_pause",
              Set.of("singleton_id", "request_id", "request_hash", "request_json", "created_at"));
  private static final String COLUMNS =
      "sequence_number,request_id,request_hash,CASE WHEN OCTET_LENGTH(request_json)<=262144 THEN"
          + " request_json ELSE NULL END AS request_json,accepted_at,previous_hash,entry_hash";

  private record Stored(
      long sequence,
      String requestId,
      String requestHash,
      String json,
      long acceptedAt,
      String previous,
      String hash) {}

  private final JdbcTemplate business, db;
  private final TransactionTemplate tx;
  private final String ledgerId;
  private final Clock clock;
  private final JsonMapper json =
      JsonMapper.builder()
          .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .disable(MapperFeature.ALLOW_COERCION_OF_SCALARS)
          .build();

  JdbcErasureLedger(DataSource business, DataSource ledger, String ledgerId, Clock clock) {
    new Checkpoint(ledgerId, 0, LedgerIntegrity.genesis(ledgerId));
    this.business = new JdbcTemplate(business);
    this.db = new JdbcTemplate(ledger);
    this.business.setQueryTimeout(5);
    this.db.setQueryTimeout(5);
    this.ledgerId = ledgerId;
    this.clock = clock;
    tx = new TransactionTemplate(new DataSourceTransactionManager(ledger));
    tx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    tx.setTimeout(5);
  }

  @Override
  public Checkpoint head() {
    return transaction(this::lockedHead);
  }

  @Override
  public WorkState workState() {
    return transaction(
        () -> {
          var head = lockedHead();
          var pause = pausedRequest();
          if (head.sequence() != 0) return WorkState.RECOVERY_REQUIRED;
          return pause == null ? WorkState.READY : WorkState.PAUSING;
        });
  }

  @Override
  public WorkPermit beginWork(String workerId) {
    new Checkpoint(workerId, 0, LedgerIntegrity.genesis(workerId));
    String admission = UUID.randomUUID().toString();
    transaction(
        () -> {
          var head = lockedHead();
          var pause = pausedRequest();
          if (head.sequence() != 0) throw failure("ERASURE_LEDGER_RECONCILIATION_REQUIRED");
          if (pause != null) throw failure("ERASURE_LEDGER_WORK_PAUSED");
          long now =
              db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", java.sql.Timestamp.class)
                  .toInstant()
                  .toEpochMilli();
          if (now <= 0) throw failure("ERASURE_LEDGER_CLOCK_INVALID");
          db.update(
              "INSERT INTO erasure_work_admissions(admission_id,worker_id,started_at)"
                  + " VALUES(?,?,?)",
              admission,
              workerId,
              now);
          return null;
        });
    return new WorkPermit() {
      private boolean closed;

      @Override
      public synchronized void close() {
        if (closed) return;
        transaction(
            () -> {
              lockedHead();
              if (db.update(
                      "DELETE FROM erasure_work_admissions WHERE admission_id=? AND worker_id=?",
                      admission,
                      workerId)
                  != 1) throw failure("ERASURE_LEDGER_ADMISSION_LOST");
              return null;
            });
        closed = true;
      }
    };
  }

  private Request pausedRequest() {
    var values =
        db.queryForList(
            "SELECT singleton_id,request_id,request_hash,CASE WHEN"
                + " OCTET_LENGTH(request_json)<=262144 THEN request_json ELSE NULL END AS"
                + " request_json,created_at FROM erasure_admission_pause");
    if (values.isEmpty()) return null;
    if (values.size() != 1) throw failure("ERASURE_LEDGER_CORRUPT");
    try {
      var row = values.get(0);
      var request = json.readValue((String) row.get("request_json"), Request.class);
      if (((Number) row.get("singleton_id")).intValue() != 1
          || ((Number) row.get("created_at")).longValue() <= 0
          || !request.requestId().equals(row.get("request_id"))
          || !LedgerIntegrity.requestHash(request).equals(row.get("request_hash")))
        throw failure("ERASURE_LEDGER_CORRUPT");
      return request;
    } catch (Exception invalid) {
      throw failure("ERASURE_LEDGER_CORRUPT");
    }
  }

  @Override
  public Entry append(Request request) {
    Objects.requireNonNull(request, "request");
    Entry accepted =
        transaction(
            () -> {
              var head = lockedHead();
              var pause = pausedRequest();
              if (pause != null && !pause.equals(request))
                throw failure("ERASURE_LEDGER_REQUEST_CONFLICT");
              var prior = rows(" WHERE request_id=?", request.requestId());
              String requestHash = LedgerIntegrity.requestHash(request);
              if (!prior.isEmpty()) {
                var entry = verify(prior.get(0));
                if (!LedgerIntegrity.requestHash(entry.request()).equals(requestHash))
                  throw failure("ERASURE_LEDGER_REQUEST_CONFLICT");
                return entry;
              }
              if (head.sequence() == Long.MAX_VALUE)
                throw failure("ERASURE_LEDGER_SEQUENCE_EXHAUSTED");
              long sequence = head.sequence() + 1, acceptedAt = clock.millis();
              if (acceptedAt <= 0) throw failure("ERASURE_LEDGER_CLOCK_INVALID");
              String hash =
                  LedgerIntegrity.entryHash(
                      ledgerId, sequence, acceptedAt, head.hash(), requestHash);
              final String payload;
              try {
                payload = json.writeValueAsString(request);
              } catch (Exception invalid) {
                throw failure("ERASURE_LEDGER_REQUEST_INVALID");
              }
              if (payload.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 262144)
                throw failure("ERASURE_LEDGER_REQUEST_INVALID");
              if (db.queryForObject("SELECT COUNT(*) FROM erasure_work_admissions", Long.class)
                  != 0) {
                if (pause == null)
                  db.update(
                      "INSERT INTO"
                          + " erasure_admission_pause(singleton_id,request_id,request_hash,request_json,created_at)"
                          + " VALUES(1,?,?,?,?)",
                      request.requestId(),
                      requestHash,
                      payload,
                      acceptedAt);
                return null;
              }
              db.update(
                  "INSERT INTO"
                      + " erasure_ledger_entries(sequence_number,request_id,request_hash,request_json,accepted_at,previous_hash,entry_hash)"
                      + " VALUES(?,?,?,?,?,?,?)",
                  sequence,
                  request.requestId(),
                  requestHash,
                  payload,
                  acceptedAt,
                  head.hash(),
                  hash);
              int changed =
                  db.update(
                      "UPDATE erasure_ledger_head SET last_sequence=?,last_hash=? WHERE"
                          + " singleton_id=1 AND ledger_id=? AND last_sequence=? AND last_hash=?",
                      sequence,
                      hash,
                      ledgerId,
                      head.sequence(),
                      head.hash());
              if (changed != 1) throw failure("ERASURE_LEDGER_CORRUPT");
              if (pause != null)
                db.update("DELETE FROM erasure_admission_pause WHERE singleton_id=1");
              return new Entry(sequence, request, acceptedAt, head.hash(), hash);
            });
    // The pause must COMMIT before reporting that acceptance is still pending.
    if (accepted == null) throw failure("ERASURE_LEDGER_WORK_ACTIVE");
    return accepted;
  }

  @Override
  public Page readAfter(Checkpoint checkpoint, int limit) {
    Objects.requireNonNull(checkpoint, "checkpoint");
    if (limit < 1 || limit > 100) throw new IllegalArgumentException("Invalid ledger page size");
    return transaction(
        () -> {
          var head = lockedHead();
          if (!ledgerId.equals(checkpoint.ledgerId()))
            throw failure("ERASURE_LEDGER_CHECKPOINT_INVALID");
          if (checkpoint.sequence() > head.sequence())
            throw failure("ERASURE_LEDGER_BEHIND_BUSINESS");
          String anchor;
          if (checkpoint.sequence() == 0) anchor = LedgerIntegrity.genesis(ledgerId);
          else {
            var previous = rows(" WHERE sequence_number=?", checkpoint.sequence());
            if (previous.size() != 1) throw failure("ERASURE_LEDGER_CORRUPT");
            anchor = verify(previous.get(0)).hash();
          }
          if (!anchor.equals(checkpoint.hash())) throw failure("ERASURE_LEDGER_CHECKPOINT_INVALID");
          var stored =
              rows(
                  " WHERE sequence_number>? AND sequence_number<=? ORDER BY sequence_number LIMIT"
                      + " ?",
                  checkpoint.sequence(),
                  head.sequence(),
                  limit);
          var entries = new ArrayList<Entry>();
          long sequence = checkpoint.sequence();
          String hash = checkpoint.hash();
          for (var row : stored) {
            var entry = verify(row);
            if (entry.sequence() != sequence + 1 || !entry.previousHash().equals(hash))
              throw failure("ERASURE_LEDGER_CORRUPT");
            entries.add(entry);
            sequence = entry.sequence();
            hash = entry.hash();
          }
          if (stored.size() < limit && sequence != head.sequence())
            throw failure("ERASURE_LEDGER_CORRUPT");
          if (sequence == head.sequence() && !hash.equals(head.hash()))
            throw failure("ERASURE_LEDGER_CORRUPT");
          return new Page(
              head, new Checkpoint(ledgerId, sequence, hash), entries, sequence == head.sequence());
        });
  }

  private <T> T transaction(Supplier<T> operation) {
    try {
      return tx.execute(
          status -> {
            // Compare actual visible schema, not URL text: aliases must not bypass database
            // separation.
            String businessCatalog = catalog(business), ledgerCatalog = catalog(db);
            if (businessCatalog == null
                || businessCatalog.isBlank()
                || ledgerCatalog == null
                || ledgerCatalog.isBlank()
                || businessCatalog.equalsIgnoreCase(ledgerCatalog)
                || businessContainsLedger()) throw failure("ERASURE_LEDGER_NOT_INDEPENDENT");
            if (!SCHEMA.equals(schema(db))) throw failure("ERASURE_LEDGER_SCHEMA_INVALID");
            requireTransactionalTables();
            return operation.get();
          });
    } catch (Failure failure) {
      throw failure;
    } catch (DataAccessException
        | org.springframework.transaction.TransactionException unavailable) {
      throw failure("ERASURE_LEDGER_UNAVAILABLE");
    }
  }

  private String catalog(JdbcTemplate source) {
    return source.execute((ConnectionCallback<String>) java.sql.Connection::getCatalog);
  }

  private void requireTransactionalTables() {
    String product =
        db.execute(
            (ConnectionCallback<String>)
                connection -> connection.getMetaData().getDatabaseProductName());
    if ("H2".equals(product)) return; // Test fixture; runtime configuration permits MySQL only.
    if (!"MySQL".equals(product)) throw failure("ERASURE_LEDGER_SCHEMA_INVALID");
    var engines =
        db.queryForList(
            "SELECT table_name,engine,table_type FROM information_schema.tables WHERE"
                + " table_schema=DATABASE()");
    if (engines.size() != SCHEMA.size()) throw failure("ERASURE_LEDGER_SCHEMA_INVALID");
    for (var table : engines) {
      if (!"InnoDB".equalsIgnoreCase((String) table.get("engine"))
          || !"BASE TABLE".equalsIgnoreCase((String) table.get("table_type")))
        throw failure("ERASURE_LEDGER_SCHEMA_INVALID");
    }
  }

  private boolean businessContainsLedger() {
    return Boolean.TRUE.equals(
        business.execute(
            (ConnectionCallback<Boolean>)
                connection -> {
                  try (var tables =
                      connection
                          .getMetaData()
                          .getTables(
                              connection.getCatalog(),
                              connection.getSchema(),
                              "%",
                              new String[] {"TABLE", "BASE TABLE", "VIEW"})) {
                    while (tables.next())
                      if ("erasure_ledger_head".equalsIgnoreCase(tables.getString("TABLE_NAME")))
                        return true;
                  }
                  return false;
                }));
  }

  private Map<String, Set<String>> schema(JdbcTemplate source) {
    return source.execute(
        (ConnectionCallback<Map<String, Set<String>>>)
            connection -> {
              var result = new TreeMap<String, Set<String>>();
              var metadata = connection.getMetaData();
              String catalog = connection.getCatalog(), namespace = connection.getSchema();
              try (var tables =
                  metadata.getTables(
                      catalog, namespace, "%", new String[] {"TABLE", "BASE TABLE", "VIEW"})) {
                while (tables.next()) {
                  String raw = tables.getString("TABLE_NAME"), table = raw.toLowerCase(Locale.ROOT);
                  var columns = new TreeSet<String>();
                  try (var fields = metadata.getColumns(catalog, namespace, raw, "%")) {
                    while (fields.next())
                      if (raw.equals(fields.getString("TABLE_NAME")))
                        columns.add(fields.getString("COLUMN_NAME").toLowerCase(Locale.ROOT));
                  }
                  result.put(table, columns);
                }
              }
              return result;
            });
  }

  private Checkpoint lockedHead() {
    var values =
        db.queryForList(
            "SELECT singleton_id,ledger_id,format_version,last_sequence,last_hash FROM"
                + " erasure_ledger_head FOR UPDATE");
    if (values.size() != 1) throw failure("ERASURE_LEDGER_CORRUPT");
    var row = values.get(0);
    if (!ledgerId.equals(row.get("ledger_id"))) throw failure("ERASURE_LEDGER_IDENTITY_MISMATCH");
    if (((Number) row.get("singleton_id")).intValue() != 1
        || ((Number) row.get("format_version")).intValue() != 1)
      throw failure("ERASURE_LEDGER_FORMAT_UNSUPPORTED");
    final Checkpoint head;
    try {
      head =
          new Checkpoint(
              ledgerId,
              ((Number) row.get("last_sequence")).longValue(),
              (String) row.get("last_hash"));
    } catch (RuntimeException invalid) {
      throw failure("ERASURE_LEDGER_CORRUPT");
    }
    var latest = rows(" ORDER BY sequence_number DESC LIMIT 1");
    if (head.sequence() == 0) {
      if (!latest.isEmpty() || !head.hash().equals(LedgerIntegrity.genesis(ledgerId)))
        throw failure("ERASURE_LEDGER_CORRUPT");
    } else {
      if (latest.size() != 1) throw failure("ERASURE_LEDGER_CORRUPT");
      var entry = verify(latest.get(0));
      if (entry.sequence() != head.sequence() || !entry.hash().equals(head.hash()))
        throw failure("ERASURE_LEDGER_CORRUPT");
    }
    return head;
  }

  private List<Stored> rows(String condition, Object... args) {
    return db.query(
        "SELECT " + COLUMNS + " FROM erasure_ledger_entries" + condition,
        (r, n) ->
            new Stored(
                r.getLong(1),
                r.getString(2),
                r.getString(3),
                r.getString(4),
                r.getLong(5),
                r.getString(6),
                r.getString(7)),
        args);
  }

  private Entry verify(Stored row) {
    try {
      Request request = json.readValue(row.json(), Request.class);
      if (request == null
          || row.sequence() <= 0
          || row.acceptedAt() <= 0
          || !request.requestId().equals(row.requestId())
          || row.previous() == null
          || !row.previous().matches("[0-9a-f]{64}")
          || !LedgerIntegrity.requestHash(request).equals(row.requestHash())
          || !LedgerIntegrity.entryHash(
                  ledgerId, row.sequence(), row.acceptedAt(), row.previous(), row.requestHash())
              .equals(row.hash())) throw failure("ERASURE_LEDGER_CORRUPT");
      return new Entry(row.sequence(), request, row.acceptedAt(), row.previous(), row.hash());
    } catch (Exception invalid) {
      throw failure("ERASURE_LEDGER_CORRUPT");
    }
  }

  private Failure failure(String code) {
    return new Failure(code);
  }
}

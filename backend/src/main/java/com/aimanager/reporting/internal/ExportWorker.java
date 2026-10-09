package com.aimanager.reporting.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.reporting.ExportMaintenance;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.time.Clock;
import java.util.*;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** Durable claim, fenced generation, and terminal cleanup use independent bounded transactions. */
@Service
class ExportWorker implements ExportMaintenance {
  private static final Logger LOG = LoggerFactory.getLogger(ExportWorker.class);
  private static final Set<String> DEFINITIVE =
      Set.of("EXPORT_ROW_LIMIT_EXCEEDED", "EXPORT_BYTE_LIMIT_EXCEEDED");
  private final ExportStore store;
  private final ExportCipher cipher;
  private final AuditService audit;
  private final ObjectMapper json;
  private final Clock clock;
  private final TransactionTemplate tx;
  private final int maxRows, maxBytes;

  ExportWorker(
      ExportStore store,
      ExportCipher cipher,
      AuditService audit,
      ObjectMapper json,
      Clock clock,
      PlatformTransactionManager transactions,
      @Value("${manager.exports.max-rows:10000}") int maxRows,
      @Value("${manager.exports.max-bytes:8388608}") int maxBytes) {
    if (maxRows < 1 || maxRows > 10000 || maxBytes < 1024 || maxBytes > 8 * 1024 * 1024)
      throw new IllegalArgumentException("Invalid audit export bounds");
    this.store = store;
    this.cipher = cipher;
    this.audit = audit;
    this.json = json;
    this.clock = clock;
    this.maxRows = maxRows;
    this.maxBytes = maxBytes;
    tx = new TransactionTemplate(transactions);
    tx.setTimeout(10);
  }

  record Key(String tenant, String id) {}

  record Locked(ExportStore.Row row, ExportStore.Member member) {}

  private Locked lock(Key key) {
    var hint = store.find(key.tenant(), key.id(), false);
    if (hint == null) return null;
    var member = store.member(key.tenant(), hint.creator(), true);
    store.head(key.tenant());
    var row = store.find(key.tenant(), key.id(), true);
    return row == null ? null : new Locked(row, member);
  }

  private void terminate(ExportStore.Row row, String state, String failure) {
    store.terminate(row, state, failure, clock.millis());
    audit.record(row.tenant(), "system:exports", "AUDIT_EXPORT_" + state, row.id());
  }

  private String claim(Key key) {
    return tx.execute(
        status -> {
          var locked = lock(key);
          if (locked == null) return null;
          var row = locked.row();
          long now = clock.millis();
          if (!Set.of("QUEUED", "RUNNING").contains(row.state())) return null;
          String effective = store.effective(row, locked.member(), now);
          if (!ExportStore.ACTIVE.contains(effective)) {
            terminate(row, effective, null);
            return null;
          }
          if ((row.state().equals("QUEUED") && row.nextAttemptAt() > now)
              || (row.state().equals("RUNNING")
                  && row.leaseUntil() != null
                  && row.leaseUntil() > now)) return null;
          if (row.attempts() >= 3) {
            terminate(row, "FAILED", "EXPORT_ATTEMPTS_EXHAUSTED");
            return null;
          }
          String token = UUID.randomUUID().toString();
          store.db.update(
              "UPDATE audit_exports SET"
                  + " state='RUNNING',attempts=attempts+1,claim_token=?,lease_until=?,updated_at=?,failure_code=NULL"
                  + " WHERE tenant_id=? AND id=?",
              token,
              now + 60000,
              now,
              row.tenant(),
              row.id());
          return token;
        });
  }

  private void produce(Key key, String token) {
    tx.executeWithoutResult(
        status -> {
          var locked = lock(key);
          if (locked == null) return;
          var row = locked.row();
          if (!row.state().equals("RUNNING") || !token.equals(row.claim())) return;
          String effective = store.effective(row, locked.member(), clock.millis());
          if (!ExportStore.ACTIVE.contains(effective)) {
            terminate(row, effective, null);
            return;
          }
          if (row.leaseUntil() == null || row.leaseUntil() <= clock.millis())
            throw DomainException.invalid("EXPORT_LEASE_EXPIRED");
          var events = audit.exportEvents(row.tenant(), row.selection(), maxRows);
          var payload = new LinkedHashMap<String, Object>();
          payload.put("schemaVersion", 1);
          payload.put("type", "AUDIT_JSON");
          payload.put("tenantId", row.tenant());
          payload.put("jobId", row.id());
          payload.put("selection", row.selection().attributes());
          payload.put("requestedTo", row.requestedTo());
          payload.put("generatedAt", clock.millis());
          payload.put("recordCount", events.size());
          payload.put("events", events);
          var output = new BoundedBytes(maxBytes);
          try {
            json.writeValue(output, payload);
          } catch (IOException failure) {
            Throwable cause = failure;
            while (cause != null) {
              if (cause instanceof LimitExceeded)
                throw DomainException.invalid("EXPORT_BYTE_LIMIT_EXCEEDED");
              cause = cause.getCause();
            }
            throw new IllegalStateException("Audit export serialization failed");
          }
          byte[] bytes = output.bytes();
          String encrypted =
              cipher.seal(
                  row.tenant(), row.id(), row.binding(events.size(), (long) bytes.length), bytes);
          // Locking membership read is repeated at publication, even though the row lock is held
          // throughout.
          var current = store.member(row.tenant(), row.creator(), true);
          effective = store.effective(row, current, clock.millis());
          if (!ExportStore.ACTIVE.contains(effective)) {
            terminate(row, effective, null);
            return;
          }
          if (row.leaseUntil() <= clock.millis())
            throw DomainException.invalid("EXPORT_LEASE_EXPIRED");
          int changed =
              store.db.update(
                  "UPDATE audit_exports SET"
                      + " state='READY',artifact=?,record_count=?,byte_count=?,updated_at=?,claim_token=NULL,lease_until=NULL,failure_code=NULL"
                      + " WHERE tenant_id=? AND id=? AND state='RUNNING' AND claim_token=?",
                  encrypted,
                  events.size(),
                  bytes.length,
                  clock.millis(),
                  row.tenant(),
                  row.id(),
                  token);
          if (changed != 1) throw new IllegalStateException("Export publication fence failed");
          audit.record(row.tenant(), "system:exports", "AUDIT_EXPORT_GENERATED", row.id());
        });
  }

  private void failed(Key key, String token, RuntimeException failure) {
    String reason =
        failure instanceof DomainException domain && DEFINITIVE.contains(domain.errorCode())
            ? domain.errorCode()
            : "EXPORT_TEMPORARY_FAILURE";
    tx.executeWithoutResult(
        status -> {
          var locked = lock(key);
          if (locked == null) return;
          var row = locked.row();
          if (!"RUNNING".equals(row.state()) || !token.equals(row.claim())) return;
          String effective = store.effective(row, locked.member(), clock.millis());
          if (!ExportStore.ACTIVE.contains(effective)) {
            terminate(row, effective, null);
            return;
          }
          if (DEFINITIVE.contains(reason) || row.attempts() >= 3) {
            terminate(
                row, "FAILED", DEFINITIVE.contains(reason) ? reason : "EXPORT_ATTEMPTS_EXHAUSTED");
            return;
          }
          long now = clock.millis();
          store.db.update(
              "UPDATE audit_exports SET"
                  + " state='QUEUED',claim_token=NULL,lease_until=NULL,artifact=NULL,failure_code=?,updated_at=?,next_attempt_at=?"
                  + " WHERE tenant_id=? AND id=?",
              reason,
              now,
              now + 30000L * row.attempts(),
              row.tenant(),
              row.id());
          audit.record(row.tenant(), "system:exports", "AUDIT_EXPORT_RETRY_SCHEDULED", row.id());
        });
  }

  @Override
  public int runBatch(int limit) {
    if (limit < 1 || limit > 25) throw new IllegalArgumentException("Invalid export batch size");
    if (!cipher.available()) return 0;
    long now = clock.millis();
    var candidates =
        store.db.query(
            "SELECT tenant_id,id FROM audit_exports WHERE (state='QUEUED' AND next_attempt_at<=?)"
                + " OR (state='RUNNING' AND (lease_until IS NULL OR lease_until<=?)) ORDER BY"
                + " created_at,id LIMIT ?",
            (r, n) -> new Key(r.getString(1), r.getString(2)),
            now,
            now,
            limit);
    int processed = 0;
    for (var key : candidates) {
      try {
        String token = claim(key);
        if (token == null) continue;
        processed++;
        try {
          produce(key, token);
        } catch (RuntimeException failure) {
          failed(key, token, failure);
        }
      } catch (RuntimeException failure) {
        LOG.warn("audit export work deferred exceptionType={}", failure.getClass().getSimpleName());
      }
    }
    return processed;
  }

  @Override
  public int purge(int limit) {
    if (limit < 1 || limit > 100)
      throw new IllegalArgumentException("Invalid export cleanup batch size");
    long now = clock.millis(), cutoff = now - 30L * 86400000;
    var candidates =
        store.db.query(
            "SELECT tenant_id,id FROM audit_exports e WHERE (state IN ('QUEUED','RUNNING','READY')"
                + " AND (expires_at<=? OR NOT EXISTS(SELECT 1 FROM tenant_members m WHERE"
                + " m.tenant_id=e.tenant_id AND m.actor_key=e.creator_key AND"
                + " m.version=e.member_version AND m.revoked_at IS NULL AND m.role IN"
                + " ('OWNER','GUARDIAN','ORG_ADMIN','AUDITOR')))) OR (state IN"
                + " ('FAILED','CANCELLED','EXPIRED','REVOKED') AND created_at<?) ORDER BY"
                + " expires_at,id LIMIT ?",
            (r, n) -> new Key(r.getString(1), r.getString(2)),
            now,
            cutoff,
            limit);
    int count = 0;
    for (var key : candidates) {
      Boolean changed =
          tx.execute(
              status -> {
                var locked = lock(key);
                if (locked == null) return false;
                var row = locked.row();
                String effective = store.effective(row, locked.member(), clock.millis());
                if (ExportStore.ACTIVE.contains(row.state())
                    && !ExportStore.ACTIVE.contains(effective)) {
                  terminate(row, effective, null);
                  return true;
                }
                if (!ExportStore.ACTIVE.contains(row.state())
                    && row.createdAt() < clock.millis() - 30L * 86400000) {
                  store.db.update(
                      "DELETE FROM audit_exports WHERE tenant_id=? AND id=?",
                      key.tenant(),
                      key.id());
                  audit.record(
                      key.tenant(), "system:exports", "AUDIT_EXPORT_METADATA_REMOVED", key.id());
                  return true;
                }
                return false;
              });
      if (Boolean.TRUE.equals(changed)) count++;
    }
    return count;
  }

  private static final class LimitExceeded extends IOException {}

  private static final class BoundedBytes extends OutputStream {
    private final int limit;
    private final ByteArrayOutputStream output = new ByteArrayOutputStream();

    BoundedBytes(int limit) {
      this.limit = limit;
    }

    @Override
    public void write(int value) throws IOException {
      if (output.size() >= limit) throw new LimitExceeded();
      output.write(value);
    }

    @Override
    public void write(byte[] bytes, int offset, int length) throws IOException {
      if (length > limit - output.size()) throw new LimitExceeded();
      output.write(bytes, offset, length);
    }

    byte[] bytes() {
      return output.toByteArray();
    }
  }
}

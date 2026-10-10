package com.aimanager.reporting.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.reporting.ReportJobMaintenance;
import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.util.*;
import org.slf4j.*;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@Service
class ReportJobWorker implements ReportJobMaintenance {
  private static final Logger LOG = LoggerFactory.getLogger(ReportJobWorker.class);
  private final ReportJobService jobs;
  private final ReportJobStore store;
  private final TransactionTemplate tx;
  private final ExportCipher cipher;
  private final Clock clock;
  private final UsageReportService reports;
  private final AuditService audit;

  ReportJobWorker(
      ReportJobService jobs,
      ReportJobStore store,
      ExportCipher cipher,
      Clock clock,
      UsageReportService reports,
      AuditService audit,
      PlatformTransactionManager transactions) {
    this.jobs = jobs;
    this.store = store;
    this.cipher = cipher;
    this.clock = clock;
    this.reports = reports;
    this.audit = audit;
    tx = new TransactionTemplate(transactions);
    tx.setTimeout(10);
  }

  record Key(String tenant, String id) {}

  private String claim(Key key) {
    return tx.execute(
        status -> {
          var locked = jobs.lock(key.tenant(), key.id());
          if (locked == null || !jobs.eligible(locked)) return null;
          var row = locked.row();
          long now = clock.millis();
          if (!Set.of("QUEUED", "RUNNING").contains(row.state())
              || (row.state().equals("QUEUED") && row.nextAttempt() > now)
              || (row.state().equals("RUNNING") && row.lease() != null && row.lease() > now))
            return null;
          if (row.attempts() >= 3) {
            jobs.terminate(row, "FAILED", "REPORT_ATTEMPTS_EXHAUSTED");
            return null;
          }
          String token = UUID.randomUUID().toString();
          store.db.update(
              "UPDATE usage_report_jobs SET"
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
          var locked = jobs.lock(key.tenant(), key.id());
          if (locked == null || !jobs.eligible(locked)) return;
          var row = locked.row();
          if (!row.state().equals("RUNNING") || !token.equals(row.claim())) return;
          var parts = store.parts(row);
          if (row.completed() < 0 || row.completed() >= parts.size() || row.total() != parts.size())
            throw new IllegalStateException("Invalid report progress");
          var part = parts.get(row.completed());
          // Intermediate ciphertext is never downloadable. Revalidate all prior
          // bindings before the final publication, with locks acquired in order.
          jobs.validateScope(
              row,
              locked.member().actor(),
              row.completed() + 1 == row.total() ? parts : List.of(part));
          if (part.generatedAt() != null || part.byteCount() != null)
            throw new IllegalStateException("Invalid report part progress");
          var selection = row.selection();
          var report =
              reports.query(
                  row.tenant(),
                  locked.member().actor(),
                  List.of(part.deviceId()),
                  selection.from(),
                  selection.to(),
                  selection.timeZone(),
                  selection.period(),
                  selection.scope());
          final byte[] bytes;
          try {
            bytes = store.json.writeValueAsBytes(report);
          } catch (Exception invalid) {
            throw new IllegalStateException("Report serialization failed");
          }
          if (bytes.length > 8 * 1024 * 1024 || row.bytes() + bytes.length > 128L * 1024 * 1024)
            throw DomainException.invalid("REPORT_JOB_BYTE_LIMIT_EXCEEDED");
          String encrypted =
              cipher.sealUsage(
                  row.tenant(),
                  row.id(),
                  ReportJobService.partBinding(row, part, bytes.length, report.generatedAt()),
                  bytes);
          long now = clock.millis();
          if (row.lease() == null || row.lease() <= now)
            throw DomainException.invalid("REPORT_JOB_LEASE_EXPIRED");
          if (row.expires() <= now) throw DomainException.invalid("REPORT_JOB_EXPIRED");
          String next = row.completed() + 1 == row.total() ? "READY" : "QUEUED";
          int changed =
              store.db.update(
                  "UPDATE usage_report_jobs SET"
                      + " state=?,completed_devices=completed_devices+1,byte_count=byte_count+?,attempts=0,claim_token=NULL,lease_until=NULL,updated_at=?,next_attempt_at=?"
                      + " WHERE tenant_id=? AND id=? AND state='RUNNING' AND claim_token=?",
                  next,
                  bytes.length,
                  now,
                  now,
                  row.tenant(),
                  row.id(),
                  token);
          if (changed != 1) throw new IllegalStateException("Report publication fence failed");
          store.db.update(
              "UPDATE usage_report_parts SET byte_count=?,generated_at=?,artifact=? WHERE"
                  + " tenant_id=? AND job_id=? AND ordinal=?",
              bytes.length,
              report.generatedAt(),
              encrypted,
              row.tenant(),
              row.id(),
              part.ordinal());
          if (next.equals("READY"))
            audit.record(row.tenant(), "system:reports", "USAGE_REPORT_JOB_GENERATED", row.id());
        });
  }

  private void failed(Key key, String token, RuntimeException failure) {
    tx.executeWithoutResult(
        status -> {
          var locked = jobs.lock(key.tenant(), key.id());
          if (locked == null || !jobs.eligible(locked)) return;
          var row = locked.row();
          if (!row.state().equals("RUNNING") || !token.equals(row.claim())) return;
          String code =
              failure instanceof DomainException d ? d.errorCode() : "REPORT_TEMPORARY_FAILURE";
          if (failure instanceof DomainException domain && ReportJobService.scopeFailure(domain)) {
            jobs.terminate(row, "REVOKED", "REPORT_SCOPE_CHANGED");
            return;
          }
          if (Set.of("USAGE_REPORT_TOO_LARGE", "REPORT_JOB_BYTE_LIMIT_EXCEEDED").contains(code)) {
            jobs.terminate(row, "FAILED", code);
            return;
          }
          if (row.attempts() >= 3) {
            jobs.terminate(row, "FAILED", "REPORT_ATTEMPTS_EXHAUSTED");
            return;
          }
          long now = clock.millis();
          store.db.update(
              "UPDATE usage_report_jobs SET"
                  + " state='QUEUED',claim_token=NULL,lease_until=NULL,failure_code='REPORT_TEMPORARY_FAILURE',updated_at=?,next_attempt_at=?"
                  + " WHERE tenant_id=? AND id=?",
              now,
              now + 30000L * row.attempts(),
              row.tenant(),
              row.id());
        });
  }

  @Override
  public int runBatch(int limit) {
    if (limit < 1 || limit > 25) throw new IllegalArgumentException("Invalid report batch size");
    if (!cipher.available()) return 0;
    long now = clock.millis();
    var keys =
        store.db.query(
            "SELECT tenant_id,id FROM usage_report_jobs WHERE (state='QUEUED' AND"
                + " next_attempt_at<=?) OR (state='RUNNING' AND (lease_until IS NULL OR"
                + " lease_until<=?)) ORDER BY created_at,id LIMIT ?",
            (r, n) -> new Key(r.getString(1), r.getString(2)),
            now,
            now,
            limit);
    int count = 0;
    for (var key : keys) {
      try {
        String token = claim(key);
        if (token == null) continue;
        count++;
        try {
          produce(key, token);
        } catch (RuntimeException failure) {
          failed(key, token, failure);
        }
      } catch (RuntimeException failure) {
        LOG.warn("report work deferred exceptionType={}", failure.getClass().getSimpleName());
      }
    }
    return count;
  }

  @Override
  public int purge(int limit) {
    if (limit < 1 || limit > 100)
      throw new IllegalArgumentException("Invalid report cleanup batch size");
    long now = clock.millis(), cutoff = now - 30L * 86400000;
    var keys =
        store.db.query(
            "SELECT tenant_id,id FROM usage_report_jobs j WHERE (state IN"
                + " ('QUEUED','RUNNING','READY') AND (expires_at<=? OR NOT EXISTS(SELECT 1 FROM"
                + " tenant_members m WHERE m.tenant_id=j.tenant_id AND m.actor_key=j.creator_key"
                + " AND m.version=j.member_version AND m.revoked_at IS NULL AND m.role IN"
                + " ('OWNER','GUARDIAN','ORG_ADMIN')))) OR (state IN"
                + " ('FAILED','CANCELLED','EXPIRED','REVOKED') AND created_at<?) ORDER BY"
                + " expires_at,id LIMIT ?",
            (r, n) -> new Key(r.getString(1), r.getString(2)),
            now,
            cutoff,
            limit);
    int count = 0;
    for (var key : keys) {
      Boolean changed =
          tx.execute(
              status -> {
                var locked = jobs.lock(key.tenant(), key.id());
                if (locked == null) return false;
                var row = locked.row();
                jobs.eligible(locked);
                if (!ReportJobStore.ACTIVE.contains(
                        store.effective(row, locked.member(), clock.millis()))
                    && row.created() < cutoff) {
                  store.db.update(
                      "DELETE FROM usage_report_parts WHERE tenant_id=? AND job_id=?",
                      key.tenant(),
                      key.id());
                  store.db.update(
                      "DELETE FROM usage_report_jobs WHERE tenant_id=? AND id=?",
                      key.tenant(),
                      key.id());
                }
                return true;
              });
      if (Boolean.TRUE.equals(changed)) count++;
    }
    return count;
  }
}

package com.aimanager.support.internal;

import com.aimanager.fleet.FleetDiagnosticSource;
import com.aimanager.shared.DomainException;
import com.aimanager.support.DiagnosticPackageMaintenance;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.slf4j.*;
import org.springframework.stereotype.Service;
import org.springframework.transaction.*;
import org.springframework.transaction.support.TransactionTemplate;

@Service
class DiagnosticPackageWorker implements DiagnosticPackageMaintenance {
  private static final Logger LOG = LoggerFactory.getLogger(DiagnosticPackageWorker.class);
  private final DiagnosticPackageStore store;
  private final DiagnosticPackageAccess scopes;
  private final DiagnosticPackageService jobs;
  private final DiagnosticPackageCipher cipher;
  private final DiagnosticPreviewService admin;
  private final SupportDiagnosticReader support;
  private final FleetDiagnosticSource fleet;
  private final ObjectMapper json;
  private final Clock clock;
  private final TransactionTemplate tx;

  DiagnosticPackageWorker(
      DiagnosticPackageStore store,
      DiagnosticPackageAccess scopes,
      DiagnosticPackageService jobs,
      DiagnosticPackageCipher cipher,
      DiagnosticPreviewService admin,
      SupportDiagnosticReader support,
      FleetDiagnosticSource fleet,
      ObjectMapper json,
      Clock clock,
      PlatformTransactionManager transactions) {
    this.store = store;
    this.scopes = scopes;
    this.jobs = jobs;
    this.cipher = cipher;
    this.admin = admin;
    this.support = support;
    this.fleet = fleet;
    this.json = json;
    this.clock = clock;
    tx = new TransactionTemplate(transactions);
    tx.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
    tx.setTimeout(10);
  }

  private DiagnosticPackageStore.Row lock(String id) {
    var hint = store.find(id, false);
    if (hint == null) return null;
    if (DiagnosticPackageStore.ACTIVE.contains(hint.state()) && hint.expires() > clock.millis())
      scopes.lock(hint.scope());
    else store.head(hint.scope().tenant());
    var row = store.find(id, true);
    if (row == null) return null;
    if (!row.scope().equals(hint.scope())) throw DomainException.denied();
    jobs.expire(row);
    return store.find(id, false);
  }

  private String claim(String id) {
    return tx.execute(
        status -> {
          var row = lock(id);
          if (row == null || !Set.of("QUEUED", "RUNNING").contains(row.state())) return null;
          long now = clock.millis();
          if (row.state().equals("QUEUED") && row.nextAttempt() > now
              || row.state().equals("RUNNING") && row.lease() != null && row.lease() > now)
            return null;
          if (row.attempts() >= 3) {
            jobs.terminate(row, "FAILED", "DIAGNOSTIC_PACKAGE_ATTEMPTS_EXHAUSTED");
            return null;
          }
          String token = UUID.randomUUID().toString();
          store.db.update(
              "UPDATE diagnostic_packages SET"
                  + " state='RUNNING',version=version+1,attempts=attempts+1,claim_token=?,lease_until=?,updated_at=?,failure_code=NULL"
                  + " WHERE id=?",
              token,
              now + 60000,
              now,
              id);
          return token;
        });
  }

  private void produce(String id, String token) {
    tx.executeWithoutResult(
        status -> {
          var row = lock(id);
          if (row == null || !row.state().equals("RUNNING") || !token.equals(row.claim())) return;
          if (row.lease() == null || row.lease() <= clock.millis())
            throw DomainException.invalid("DIAGNOSTIC_PACKAGE_LEASE_EXPIRED");
          var scope = row.scope();
          var grant = scopes.lock(scope);
          var source =
              fleet.snapshot(
                  scope.tenant(),
                  scope.authority(),
                  scope.device(),
                  SupportGrantTypes.has(scope.types(), SupportGrantTypes.CAPABILITIES));
          String previous = MDC.get("correlationId");
          MDC.put("correlationId", UUID.randomUUID().toString());
          final byte[] bytes;
          long generated = clock.millis();
          try {
            byte[] diagnostic =
                grant == null ? admin.read(scope.tenant(), source) : support.read(grant, source);
            var value =
                new PackageDocument(
                    1,
                    "DEVICE_DIAGNOSTIC",
                    id,
                    scope.mode(),
                    SupportGrantTypes.list(scope.types()),
                    generated,
                    row.expires(),
                    json.readTree(diagnostic));
            bytes = json.writeValueAsBytes(value);
          } catch (java.io.IOException failure) {
            throw DomainException.invalid("DIAGNOSTIC_SERIALIZATION_FAILED");
          } finally {
            if (previous == null) MDC.remove("correlationId");
            else MDC.put("correlationId", previous);
          }
          if (bytes.length > DiagnosticPackageCipher.MAX_BYTES)
            throw DomainException.invalid("DIAGNOSTIC_TOO_LARGE");
          String hash = DiagnosticPackageStore.hash(bytes),
              encrypted =
                  cipher.seal(
                      scope.tenant(),
                      id,
                      DiagnosticPackageStore.binding(row, generated, bytes.length, hash),
                      bytes);
          if (row.expires() <= clock.millis()) {
            jobs.terminate(row, "EXPIRED", null);
            return;
          }
          if (grant != null) scopes.active(grant);
          if (row.lease() <= clock.millis())
            throw DomainException.invalid("DIAGNOSTIC_PACKAGE_LEASE_EXPIRED");
          int changed =
              store.db.update(
                  "UPDATE diagnostic_packages SET"
                      + " state='READY',version=version+1,artifact=?,generated_at=?,byte_count=?,artifact_sha256=?,updated_at=?,next_validation_at=?,claim_token=NULL,lease_until=NULL,failure_code=NULL"
                      + " WHERE id=? AND state='RUNNING' AND claim_token=?",
                  encrypted,
                  generated,
                  bytes.length,
                  hash,
                  clock.millis(),
                  Math.min(row.expires(), clock.millis() + 60000),
                  id,
                  token);
          if (changed != 1)
            throw new IllegalStateException("Diagnostic package publication fence failed");
          jobs.audit.record(
              scope.tenant(), "system:diagnostics", "DIAGNOSTIC_PACKAGE_GENERATED", id);
        });
  }

  record PackageDocument(
      int schemaVersion,
      String type,
      String jobId,
      String accessMode,
      List<String> diagnosticTypes,
      long generatedAt,
      long expiresAt,
      com.fasterxml.jackson.databind.JsonNode diagnostic) {}

  private void failed(String id, String token, RuntimeException failure) {
    tx.executeWithoutResult(
        status -> {
          var hint = store.find(id, false);
          if (hint == null) return;
          store.head(hint.scope().tenant());
          var row = store.find(id, true);
          if (row == null || !row.state().equals("RUNNING") || !token.equals(row.claim())) return;
          if (row.expires() <= clock.millis()) {
            jobs.terminate(row, "EXPIRED", null);
            return;
          }
          if (failure instanceof DomainException domain
              && DiagnosticPackageService.scopeFailure(domain)) {
            jobs.invalidate(row);
            return;
          }
          String reason =
              failure instanceof DomainException domain
                      && Set.of(
                              "DIAGNOSTIC_TOO_LARGE",
                              "DIAGNOSTIC_SOURCE_INVALID",
                              "DIAGNOSTIC_SERIALIZATION_FAILED")
                          .contains(domain.errorCode())
                  ? domain.errorCode()
                  : "DIAGNOSTIC_PACKAGE_TEMPORARY_FAILURE";
          if (!reason.equals("DIAGNOSTIC_PACKAGE_TEMPORARY_FAILURE") || row.attempts() >= 3) {
            jobs.terminate(
                row,
                "FAILED",
                row.attempts() >= 3 ? "DIAGNOSTIC_PACKAGE_ATTEMPTS_EXHAUSTED" : reason);
            return;
          }
          store.db.update(
              "UPDATE diagnostic_packages SET"
                  + " state='QUEUED',version=version+1,claim_token=NULL,lease_until=NULL,artifact=NULL,generated_at=NULL,byte_count=NULL,artifact_sha256=NULL,failure_code=?,updated_at=?,next_attempt_at=?"
                  + " WHERE id=?",
              reason,
              clock.millis(),
              clock.millis() + 5000L * row.attempts(),
              id);
        });
  }

  private void invalidate(String id) {
    tx.executeWithoutResult(
        status -> {
          var hint = store.find(id, false);
          if (hint == null) return;
          store.head(hint.scope().tenant());
          var row = store.find(id, true);
          if (row != null) jobs.invalidate(row);
        });
  }

  @Override
  public int runBatch(int limit) {
    bound(limit);
    long now = clock.millis();
    var ids =
        store.db.queryForList(
            "SELECT id FROM diagnostic_packages WHERE (state='QUEUED' AND next_attempt_at<=?) OR"
                + " (state='RUNNING' AND (lease_until IS NULL OR lease_until<=?)) ORDER BY"
                + " next_attempt_at,id LIMIT ?",
            String.class,
            now,
            now,
            limit);
    int claimed = 0;
    for (String id : ids) {
      String token = null;
      try {
        token = claim(id);
        if (token != null) {
          claimed++;
          produce(id, token);
        }
      } catch (RuntimeException failure) {
        try {
          if (token != null) failed(id, token, failure);
          else if (failure instanceof DomainException domain
              && DiagnosticPackageService.scopeFailure(domain)) invalidate(id);
        } catch (RuntimeException cleanup) {
          LOG.warn("Diagnostic package transition deferred job={}", id);
        }
        LOG.warn("Diagnostic package attempt deferred job={}", id);
      }
    }
    return claimed;
  }

  @Override
  public int purge(int limit) {
    bound(limit);
    var ids =
        store.db.queryForList(
            "SELECT id FROM diagnostic_packages WHERE state IN ('QUEUED','RUNNING','READY') AND"
                + " (next_validation_at<=? OR expires_at<=?) ORDER BY next_validation_at,id LIMIT"
                + " ?",
            String.class,
            clock.millis(),
            clock.millis(),
            limit);
    int checked = 0;
    for (String id : ids) {
      try {
        tx.executeWithoutResult(
            status -> {
              var row = lock(id);
              if (row != null && DiagnosticPackageStore.ACTIVE.contains(row.state()))
                store.db.update(
                    "UPDATE diagnostic_packages SET next_validation_at=? WHERE id=?",
                    Math.min(row.expires(), clock.millis() + 60000),
                    id);
            });
        checked++;
      } catch (DomainException failure) {
        if (DiagnosticPackageService.scopeFailure(failure)) {
          try {
            invalidate(id);
            checked++;
          } catch (RuntimeException cleanup) {
            LOG.warn("Diagnostic package cleanup transition deferred job={}", id);
          }
        } else LOG.warn("Diagnostic package cleanup deferred job={}", id);
      } catch (RuntimeException failure) {
        LOG.warn("Diagnostic package cleanup deferred job={}", id);
      }
    }
    return checked;
  }

  private void bound(int limit) {
    if (limit < 1 || limit > 100)
      throw new IllegalArgumentException("Invalid diagnostic work bound");
  }
}

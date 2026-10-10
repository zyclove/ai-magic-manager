package com.aimanager.reporting.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.*;
import com.aimanager.observation.UsageReportSource;
import com.aimanager.shared.*;
import java.time.Clock;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionTemplate;

@Service
class ReportJobService {
  final ReportJobStore store;
  final UsageReportScope scopes;
  final UsageReportSource source;
  final UsageReportService reports;
  final ExportCipher cipher;
  final Clock clock;
  final AuditService audit;
  final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final TransactionTemplate tx;

  ReportJobService(
      ReportJobStore store,
      UsageReportScope scopes,
      UsageReportSource source,
      UsageReportService reports,
      ExportCipher cipher,
      Clock clock,
      AuditService audit,
      RecentAuthentication recent,
      IdempotencyService idempotency,
      PlatformTransactionManager transactions) {
    this.store = store;
    this.scopes = scopes;
    this.source = source;
    this.reports = reports;
    this.cipher = cipher;
    this.clock = clock;
    this.audit = audit;
    this.recent = recent;
    this.idempotency = idempotency;
    tx = new TransactionTemplate(transactions);
    tx.setTimeout(10);
  }

  record Ref(String id) {}

  @Transactional(timeout = 10)
  public ReportJobStore.Job create(String tenant, Jwt actor, ReportJobSelection input, String key) {
    var member = store.authorize(tenant, actor.getSubject(), true);
    recent.require(actor);
    cipher.requireAvailable();
    reports.validateQuery(input.from(), input.to(), input.timeZone(), input.period());
    if (key == null || key.isBlank()) throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
    store.head(tenant);
    var ref =
        idempotency.execute(
            tenant,
            actor.getSubject(),
            "USAGE_REPORT_JOB_CREATE",
            key,
            Map.of(
                "deviceIds",
                input.deviceIds(),
                "from",
                input.from(),
                "to",
                input.to(),
                "timeZone",
                input.timeZone(),
                "period",
                input.period(),
                "scope",
                input.scope()),
            Ref.class,
            () -> {
              long now = clock.millis();
              String creator = ActorKeys.key(actor.getSubject());
              long active =
                  store.db.queryForObject(
                      "SELECT COUNT(*) FROM usage_report_jobs WHERE tenant_id=? AND expires_at>?"
                          + " AND state IN ('QUEUED','RUNNING','READY')",
                      Long.class,
                      tenant,
                      now);
              long own =
                  store.db.queryForObject(
                      "SELECT COUNT(*) FROM usage_report_jobs WHERE tenant_id=? AND creator_key=?"
                          + " AND expires_at>? AND state IN ('QUEUED','RUNNING','READY')",
                      Long.class,
                      tenant,
                      creator,
                      now);
              long recentCount =
                  store.db.queryForObject(
                      "SELECT COUNT(*) FROM usage_report_jobs WHERE tenant_id=? AND creator_key=?"
                          + " AND created_at>?",
                      Long.class,
                      tenant,
                      creator,
                      now - 60000);
              if (active >= 20 || own >= 3 || recentCount > 0)
                throw new DomainException(
                    HttpStatus.TOO_MANY_REQUESTS, "REPORT_JOB_CAPACITY_REACHED");
              var selection =
                  new ReportJobSelection(
                      input.deviceIds(),
                      input.from(),
                      Math.min(input.to(), now),
                      input.timeZone(),
                      input.period(),
                      input.scope());
              var scope =
                  scopes.prepare(
                      tenant, actor.getSubject(), selection.deviceIds(), selection.scope());
              var snapshot = source.authorize(tenant, actor.getSubject(), selection.deviceIds());
              scopes.verify(scope, snapshot);
              final String encoded;
              try {
                encoded = store.json.writeValueAsString(selection);
              } catch (Exception invalid) {
                throw new IllegalStateException("Report selection serialization failed");
              }
              String id = UUID.randomUUID().toString();
              store.db.update(
                  "INSERT INTO"
                      + " usage_report_jobs(tenant_id,id,creator_key,member_version,state,selection_json,selection_hash,total_devices,created_at,updated_at,expires_at,next_attempt_at)"
                      + " VALUES(?,?,?,?,'QUEUED',?,?,?,?,?,?,?)",
                  tenant,
                  id,
                  creator,
                  member.version(),
                  encoded,
                  SecretMaterial.hash(encoded),
                  selection.deviceIds().size(),
                  now,
                  now,
                  now + 86400000,
                  now);
              int ordinal = 0;
              for (var data : snapshot.devices())
                store.db.update(
                    "INSERT INTO"
                        + " usage_report_parts(tenant_id,job_id,ordinal,device_id,registration_id,subject_id,authorization_version,usage_enabled)"
                        + " VALUES(?,?,?,?,?,?,?,?)",
                    tenant,
                    id,
                    ordinal++,
                    data.device().id(),
                    data.device().registrationId(),
                    data.device().subjectId(),
                    data.settings().version(),
                    data.settings().usageEnabled());
              audit.record(tenant, actor.getSubject(), "USAGE_REPORT_JOB_REQUESTED", id);
              return new Ref(id);
            });
    return store.view(
        store.owned(tenant, ref.id(), actor.getSubject(), true), member, clock.millis());
  }

  /** The caller owns the membership and job locks for the entire read/publication transaction. */
  void validateScope(ReportJobStore.Row row, String actor, List<ReportJobStore.Part> parts) {
    var ids = parts.stream().map(ReportJobStore.Part::deviceId).toList();
    var expected = scopes.prepare(row.tenant(), actor, ids, row.selection().scope());
    var current = source.authorize(row.tenant(), actor, ids);
    scopes.verify(expected, current);
    var indexed = new HashMap<String, ReportJobStore.Part>();
    for (var part : parts) indexed.put(part.deviceId(), part);
    if (current.devices().size() != parts.size()) throw changed();
    for (var data : current.devices()) {
      var part = indexed.get(data.device().id());
      if (part == null
          || !part.registrationId().equals(data.device().registrationId())
          || !part.subjectId().equals(data.device().subjectId())
          || part.authorizationVersion() != data.settings().version()
          || part.usageEnabled() != data.settings().usageEnabled()) throw changed();
    }
  }

  private DomainException changed() {
    return new DomainException(HttpStatus.CONFLICT, "REPORT_SCOPE_CHANGED");
  }

  void terminate(ReportJobStore.Row row, String state, String reason) {
    store.terminate(row, state, reason, clock.millis());
    audit.record(row.tenant(), "system:reports", "USAGE_REPORT_JOB_" + state, row.id());
  }

  record Locked(ReportJobStore.Row row, ReportJobStore.Member member) {}

  Locked lock(String tenant, String id) {
    var hint = store.find(tenant, id, false);
    if (hint == null) return null;
    var member = store.member(tenant, hint.creator(), true);
    store.head(tenant);
    var row = store.find(tenant, id, true);
    return row == null ? null : new Locked(row, member);
  }

  boolean eligible(Locked locked) {
    var row = locked.row();
    var state = store.effective(row, locked.member(), clock.millis());
    if (!ReportJobStore.ACTIVE.contains(state)) {
      if (!state.equals(row.state())) terminate(row, state, null);
      return false;
    }
    return true;
  }

  public ReportJobStore.Job get(String tenant, String id, Jwt actor) {
    try {
      return tx.execute(status -> getLocked(tenant, id, actor));
    } catch (DomainException failure) {
      if (!scopeFailure(failure)) throw failure;
      return tx.execute(
          status -> {
            var member = store.authorize(tenant, actor.getSubject(), true);
            store.head(tenant);
            var row = store.owned(tenant, id, actor.getSubject(), true);
            if (eligible(new Locked(row, member)))
              terminate(row, "REVOKED", "REPORT_SCOPE_CHANGED");
            return store.view(store.find(tenant, id, false), member, clock.millis());
          });
    }
  }

  private ReportJobStore.Job getLocked(String tenant, String id, Jwt actor) {
    var member = store.authorize(tenant, actor.getSubject(), true);
    store.head(tenant);
    var row = store.owned(tenant, id, actor.getSubject(), true);
    if (eligible(new Locked(row, member))) {
      validateScope(row, actor.getSubject(), store.parts(row));
    }
    return store.view(store.find(tenant, id, false), member, clock.millis());
  }

  static boolean scopeFailure(DomainException failure) {
    return Set.of("SCOPE_DENIED", "DEVICE_NOT_ACTIVE", "REPORT_SCOPE_CHANGED", "CLASS_ARCHIVED")
        .contains(failure.errorCode());
  }

  static String partBinding(
      ReportJobStore.Row row, ReportJobStore.Part part, long bytes, long generated) {
    return SecretMaterial.hash(
        row.binding()
            + "|"
            + part.ordinal()
            + "|"
            + part.deviceId()
            + "|"
            + part.registrationId()
            + "|"
            + part.subjectId()
            + "|"
            + part.authorizationVersion()
            + "|"
            + part.usageEnabled()
            + "|"
            + bytes
            + "|"
            + generated);
  }

  public byte[] content(String tenant, String id, int ordinal, Jwt actor) {
    recent.require(actor);
    try {
      return tx.execute(
          status -> {
            var member = store.authorize(tenant, actor.getSubject(), true);
            store.head(tenant);
            var row = store.owned(tenant, id, actor.getSubject(), true);
            if (!store.effective(row, member, clock.millis()).equals("READY"))
              throw new DomainException(HttpStatus.CONFLICT, "REPORT_JOB_NOT_READY");
            var parts = store.parts(row);
            if (ordinal < 0 || ordinal >= parts.size())
              throw DomainException.invalid("INVALID_REPORT_PART");
            validateScope(row, actor.getSubject(), parts);
            var part = parts.get(ordinal);
            if (part.byteCount() == null || part.generatedAt() == null)
              throw new DomainException(
                  HttpStatus.SERVICE_UNAVAILABLE, "REPORT_ARTIFACT_UNAVAILABLE");
            var encrypted =
                store.db.queryForObject(
                    "SELECT artifact FROM usage_report_parts WHERE tenant_id=? AND job_id=? AND"
                        + " ordinal=?",
                    String.class,
                    tenant,
                    id,
                    ordinal);
            var bytes =
                cipher.openUsage(
                    tenant,
                    id,
                    partBinding(row, part, part.byteCount(), part.generatedAt()),
                    encrypted);
            if (bytes.length != part.byteCount() || bytes.length > 8 * 1024 * 1024)
              throw new DomainException(
                  HttpStatus.SERVICE_UNAVAILABLE, "REPORT_ARTIFACT_UNAVAILABLE");
            if (clock.millis() >= row.expires())
              throw new DomainException(HttpStatus.CONFLICT, "REPORT_JOB_NOT_READY");
            audit.record(tenant, actor.getSubject(), "USAGE_REPORT_PART_READ", id);
            return bytes;
          });
    } catch (DomainException failure) {
      if (scopeFailure(failure)) get(tenant, id, actor);
      throw failure;
    }
  }

  @Transactional(timeout = 10)
  public ReportJobStore.Job cancel(String tenant, String id, Jwt actor) {
    var member = store.authorize(tenant, actor.getSubject(), true);
    store.head(tenant);
    var row = store.owned(tenant, id, actor.getSubject(), true);
    if (ReportJobStore.ACTIVE.contains(row.state())) {
      var state = store.effective(row, member, clock.millis());
      terminate(row, ReportJobStore.ACTIVE.contains(state) ? "CANCELLED" : state, null);
    }
    return store.view(store.find(tenant, id, false), member, clock.millis());
  }

  @Transactional(readOnly = true, timeout = 10)
  public ItemPage<ReportJobStore.Job> list(String tenant, Jwt actor, int limit, String cursor) {
    var member = store.authorize(tenant, actor.getSubject(), false);
    if (limit < 1 || limit > 50) throw DomainException.invalid("INVALID_PAGE_SIZE");
    String creator = ActorKeys.key(actor.getSubject());
    var sql =
        new StringBuilder("SELECT * FROM usage_report_jobs WHERE tenant_id=? AND creator_key=?");
    var values = new ArrayList<Object>(List.of(tenant, creator));
    if (cursor != null) {
      var prior = store.owned(tenant, cursor, actor.getSubject(), false);
      sql.append(" AND (created_at<? OR (created_at=? AND id<?))");
      values.add(prior.created());
      values.add(prior.created());
      values.add(prior.id());
    }
    sql.append(" ORDER BY created_at DESC,id DESC LIMIT ?");
    values.add(limit + 1);
    var page =
        ItemPage.from(
            store.db.query(sql.toString(), store::row, values.toArray()),
            limit,
            ReportJobStore.Row::id);
    return new ItemPage<>(
        page.items().stream().map(r -> store.view(r, member, clock.millis())).toList(),
        page.nextCursor());
  }
}

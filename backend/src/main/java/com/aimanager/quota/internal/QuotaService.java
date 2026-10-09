package com.aimanager.quota.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.deviceidentity.*;
import com.aimanager.fleet.*;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.quota.*;
import com.aimanager.shared.*;
import com.aimanager.signing.ConfigurationSigner;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.*;
import java.time.*;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * All balances, receipts and event records commit together. No device/network wait occurs inside a
 * transaction.
 */
@Service
class QuotaService {
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final SubjectAccess subjects;
  private final DeviceAccess devices;
  private final DeviceCredentials credentials;
  private final ApplicationCatalog catalog;
  private final QuotaExecutionSupport execution;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final AuditService audit;
  private final ConfigurationSigner signer;
  private final ObjectMapper mapper;
  private final Clock clock;
  private final QuotaPoolFactory poolFactory;
  private final QuotaPlanService plans;
  private final long leaseLifetimeMillis;
  private final long clockSkewSeconds;

  QuotaService(
      JdbcTemplate jdbc,
      TenantAccess access,
      SubjectAccess subjects,
      DeviceAccess devices,
      DeviceCredentials credentials,
      ApplicationCatalog catalog,
      QuotaExecutionSupport execution,
      RecentAuthentication recent,
      IdempotencyService idempotency,
      AuditService audit,
      ConfigurationSigner signer,
      ObjectMapper mapper,
      Clock clock,
      QuotaPoolFactory poolFactory,
      QuotaPlanService plans,
      @Value("${manager.quota.lease-lifetime-seconds:300}") long lifetime,
      @Value("${manager.quota.clock-skew-tolerance-seconds:2}") long skew) {
    if (lifetime < 30 || lifetime > 300 || skew < 0 || skew > 30)
      throw new IllegalArgumentException("Invalid quota timing configuration");
    this.jdbc = jdbc;
    this.access = access;
    this.subjects = subjects;
    this.devices = devices;
    this.credentials = credentials;
    this.catalog = catalog;
    this.execution = execution;
    this.recent = recent;
    this.idempotency = idempotency;
    this.audit = audit;
    this.signer = signer;
    this.mapper = mapper;
    this.clock = clock;
    this.poolFactory = poolFactory;
    this.plans = plans;
    this.leaseLifetimeMillis = lifetime * 1000;
    this.clockSkewSeconds = skew;
  }

  @Transactional(timeout = 10)
  public QuotaPool create(String tenant, Jwt actor, QuotaController.Create in, String key) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    requiredKey(key);
    subjects.lockActiveForScope(tenant, actor.getSubject(), in.subjectId());
    if ((in.scope() == QuotaPool.Scope.APPLICATION) != (in.applicationId() != null))
      throw DomainException.invalid("QUOTA_SCOPE_MISMATCH");
    if (in.applicationId() != null)
      catalog.requireDeclared(tenant, actor.getSubject(), in.applicationId());
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "quota.create",
        key,
        Map.of("input", in),
        QuotaPool.class,
        () -> {
          ZoneId zone;
          LocalDate date;
          try {
            zone = ZoneId.of(in.timeZone());
            date = LocalDate.parse(in.periodId());
          } catch (DateTimeException e) {
            throw DomainException.invalid("INVALID_QUOTA_PERIOD");
          }
          long end = date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli();
          if (end <= clock.millis()
              || date.isAfter(LocalDate.now(clock.withZone(zone)).plusDays(366)))
            throw conflict("QUOTA_PERIOD_UNAVAILABLE");
          poolFactory.calendar(tenant, in.subjectId(), zone);
          String id =
              poolFactory.create(
                  tenant,
                  in.subjectId(),
                  in.name(),
                  in.scope(),
                  in.applicationId(),
                  date,
                  zone,
                  in.limitSeconds(),
                  null,
                  null,
                  actor.getSubject());
          return pool(tenant, id, false);
        });
  }

  public ItemPage<QuotaPool> list(String tenant, String actor, int limit, String cursor) {
    var grant = access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR, CHILD);
    ItemPage.validate(limit, cursor);
    String restriction = grant.role() == CHILD ? " AND subject_id=?" : "";
    var args = new ArrayList<Object>(List.of(tenant, cursor == null ? "" : cursor));
    if (grant.role() == CHILD) args.add(grant.subjectId());
    args.add(limit + 1);
    return ItemPage.from(
        jdbc.query(
            "SELECT * FROM quota_pools WHERE tenant_id=? AND id>?"
                + restriction
                + " ORDER BY id LIMIT ?",
            this::mapPool,
            args.toArray()),
        limit,
        QuotaPool::id);
  }

  public QuotaPool get(String tenant, String actor, String id) {
    var grant = access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR, CHILD);
    var pool = pool(tenant, id, false);
    if (grant.role() == CHILD && !pool.subjectId().equals(grant.subjectId()))
      throw DomainException.denied();
    return pool;
  }

  @Transactional(timeout = 10)
  public QuotaPool adjust(
      String tenant, Jwt actor, String id, QuotaController.Adjustment in, String etag, String key) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    requiredKey(key);
    long version = ResourceVersions.require(etag);
    var before = pool(tenant, id, false);
    subjects.lockActiveForScope(tenant, actor.getSubject(), before.subjectId());
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "quota.adjust",
        key,
        Map.of("pool", id, "version", version, "input", in),
        QuotaPool.class,
        () -> {
          calendar(tenant, before.subjectId());
          var current = pool(tenant, id, true);
          ResourceVersions.check(version, current.version());
          if (current.periodEnd() <= clock.millis()) throw conflict("QUOTA_PERIOD_CLOSED");
          if (in.deltaSeconds() == 0
              || (in.reason() == QuotaController.Reason.EXTRA_TIME && in.deltaSeconds() < 0))
            throw DomainException.invalid("INVALID_QUOTA_ADJUSTMENT");
          long next = current.limitSeconds() + in.deltaSeconds();
          if (next > 86400 || next < current.usedSeconds() + current.reservedSeconds())
            throw conflict("QUOTA_BALANCE_CONFLICT");
          jdbc.update(
              "UPDATE quota_pools SET limit_seconds=?,version=version+1 WHERE tenant_id=? AND id=?",
              next,
              tenant,
              id);
          entry(tenant, id, null, "ADJUSTED", in.deltaSeconds(), 0, 0, null, in.reason().name());
          audit.record(tenant, actor.getSubject(), "QUOTA_ADJUSTED", id);
          event(
              tenant,
              id,
              "QUOTA_ADJUSTED",
              Map.of("poolId", id, "deltaSeconds", in.deltaSeconds()));
          return pool(tenant, id, false);
        });
  }

  public ItemPage<Entry> ledger(
      String tenant, String actor, String pool, int limit, String cursor) {
    get(tenant, actor, pool);
    ItemPage.validate(limit, cursor);
    return ItemPage.from(
        jdbc.query(
            "SELECT * FROM quota_ledger WHERE tenant_id=? AND pool_id=? AND id>? ORDER BY id LIMIT"
                + " ?",
            (r, n) ->
                new Entry(
                    r.getString("id"),
                    r.getString("lease_id"),
                    r.getString("kind"),
                    r.getLong("limit_delta"),
                    r.getLong("used_delta"),
                    r.getLong("reserved_delta"),
                    r.getObject("sequence_number") == null ? null : r.getLong("sequence_number"),
                    r.getString("reason"),
                    r.getLong("occurred_at")),
            tenant,
            pool,
            cursor == null ? "" : cursor,
            limit + 1),
        limit,
        Entry::id);
  }

  @Transactional(timeout = 10)
  public QuotaLease reserve(DeviceContext identity, QuotaController.Reserve in) {
    var device = device(identity, false);
    String tenant = identity.tenantId();
    calendar(tenant, device.subjectId());
    plans.materializeForDevice(tenant, device.subjectId(), in.applicationId());
    String hash = SecretMaterial.hash(json(in));
    var previous =
        jdbc.query(
            "SELECT * FROM quota_leases WHERE tenant_id=? AND registration_id=? AND request_id=?"
                + " FOR UPDATE",
            this::mapLease,
            tenant,
            identity.registrationId(),
            in.requestId());
    if (!previous.isEmpty()) {
      if (!previous.get(0).requestHash().equals(hash)) throw conflict("IDEMPOTENCY_KEY_CONFLICT");
      return view(
          previous.get(
              0)); // Even an expired replay returns the original deadline and grant, never a fresh
      // allocation.
    }
    catalog.requireKnownIdentity(tenant, in.applicationId());
    execution.requireVerified(device, in.applicationId());
    signer.requireConfigured();
    var pools =
        jdbc.query(
            "SELECT * FROM quota_pools WHERE tenant_id=? AND subject_id=? AND period_start<=? AND"
                + " period_end>? AND (scope_key='TOTAL' OR application_id=?) ORDER BY id FOR"
                + " UPDATE",
            this::mapPool,
            tenant,
            device.subjectId(),
            clock.millis(),
            clock.millis(),
            in.applicationId());
    if (pools.stream().noneMatch(p -> p.scope() == QuotaPool.Scope.TOTAL))
      throw conflict("QUOTA_TOTAL_REQUIRED");
    long granted = in.requestedSeconds(), deadline = clock.millis() + leaseLifetimeMillis;
    for (var p : pools) {
      granted = Math.min(granted, p.availableSeconds());
      deadline = Math.min(deadline, p.periodEnd());
    }
    granted = Math.min(granted, (deadline - clock.millis()) / 1000);
    if (granted < 1) throw conflict("QUOTA_EXHAUSTED");
    String id = UUID.randomUUID().toString();
    long now = clock.millis();
    var envelope = new LinkedHashMap<String, Object>();
    envelope.put("schemaVersion", 1);
    envelope.put("purpose", "QUOTA_LEASE");
    envelope.put("leaseId", id);
    envelope.put("tenantId", tenant);
    envelope.put("subjectId", device.subjectId());
    envelope.put("deviceId", device.id());
    envelope.put("registrationId", device.registrationId());
    envelope.put("applicationId", in.applicationId());
    envelope.put("bootId", in.bootId());
    envelope.put("sessionId", in.sessionId());
    envelope.put("startTickMillis", in.startTickMillis());
    envelope.put("reservedSeconds", granted);
    envelope.put("unit", "SECONDS");
    envelope.put("issuedAt", now);
    envelope.put("notAfter", deadline);
    envelope.put("sequence", 1);
    envelope.put(
        "pools",
        pools.stream()
            .map(
                p ->
                    Map.of(
                        "poolId",
                        p.id(),
                        "periodId",
                        p.periodId(),
                        "scope",
                        p.scope(),
                        "timeZone",
                        p.timeZone(),
                        "periodEnd",
                        p.periodEnd()))
            .toList());
    String signature = signer.signQuotaLease(json(envelope));
    jdbc.update(
        "INSERT INTO"
            + " quota_leases(tenant_id,id,subject_id,device_id,registration_id,application_id,request_id,request_hash,boot_id,session_id,start_tick_millis,reserved_seconds,last_tick_millis,issued_at,not_after,signed_lease)"
            + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        tenant,
        id,
        device.subjectId(),
        device.id(),
        device.registrationId(),
        in.applicationId(),
        in.requestId(),
        hash,
        in.bootId(),
        in.sessionId(),
        in.startTickMillis(),
        granted,
        in.startTickMillis(),
        now,
        deadline,
        signature);
    for (var p : pools) {
      jdbc.update(
          "UPDATE quota_pools SET reserved_seconds=reserved_seconds+?,version=version+1 WHERE"
              + " tenant_id=? AND id=?",
          granted,
          tenant,
          p.id());
      jdbc.update(
          "INSERT INTO quota_lease_pools(tenant_id,lease_id,pool_id) VALUES(?,?,?)",
          tenant,
          id,
          p.id());
      entry(tenant, p.id(), id, "RESERVED", 0, 0, granted, null, null);
    }
    event(tenant, id, "QUOTA_RESERVED", Map.of("leaseId", id, "reservedSeconds", granted));
    audit.record(tenant, "device:" + identity.registrationId(), "QUOTA_RESERVED", id);
    return view(leaseRow(identity, id, true));
  }

  @Transactional(timeout = 10)
  public QuotaLease lease(DeviceContext identity, String id) {
    device(identity, true);
    return view(leaseRow(identity, id, false));
  }

  @Transactional(timeout = 10)
  public QuotaLease settle(DeviceContext identity, String id, QuotaController.Settlement in) {
    var device = device(identity, true);
    calendar(identity.tenantId(), device.subjectId());
    var current = leaseRow(identity, id, true);
    String hash = SecretMaterial.hash(json(in));
    if (in.sequence() == current.view().lastSequence()) {
      if (!hash.equals(current.reportHash())) throw conflict("QUOTA_SEQUENCE_CONFLICT");
      return view(current);
    }
    if (in.sequence() < current.view().lastSequence()) throw conflict("QUOTA_SEQUENCE_CONFLICT");
    if (!current.view().state().equals("ACTIVE")) throw conflict("QUOTA_LEASE_CLOSED");
    if (!in.bootId().equals(current.view().bootId())) throw conflict("QUOTA_BOOT_CHANGED");
    long used = in.cumulativeUsedSeconds();
    if (used < current.view().usedSeconds()
        || used > current.view().reservedSeconds()
        || in.elapsedRealtimeMillis() < current.lastTick()
        || in.elapsedRealtimeMillis() < current.startTick()
        || used > (in.elapsedRealtimeMillis() - current.startTick()) / 1000 + clockSkewSeconds
        || used
            > Math.max(0, (clock.millis() - current.view().issuedAt()) / 1000) + clockSkewSeconds)
      throw conflict("QUOTA_COUNTER_INVALID");
    long delta = used - current.view().usedSeconds(),
        release = in.finished() ? current.view().reservedSeconds() - used : 0;
    var poolIds =
        jdbc.queryForList(
            "SELECT pool_id FROM quota_lease_pools WHERE tenant_id=? AND lease_id=? ORDER BY"
                + " pool_id",
            String.class,
            identity.tenantId(),
            id);
    for (String poolId : poolIds) {
      pool(identity.tenantId(), poolId, true);
      jdbc.update(
          "UPDATE quota_pools SET"
              + " used_seconds=used_seconds+?,reserved_seconds=reserved_seconds-?,version=version+1"
              + " WHERE tenant_id=? AND id=?",
          delta,
          delta + release,
          identity.tenantId(),
          poolId);
      entry(identity.tenantId(), poolId, id, "SETTLED", 0, delta, -delta, in.sequence(), null);
      if (release > 0)
        entry(
            identity.tenantId(),
            poolId,
            id,
            "RELEASED",
            0,
            0,
            -release,
            in.sequence(),
            "DEVICE_CONFIRMED_STOP");
    }
    jdbc.update(
        "UPDATE quota_leases SET"
            + " used_seconds=?,last_sequence=?,last_tick_millis=?,last_report_hash=?,state=? WHERE"
            + " tenant_id=? AND id=?",
        used,
        in.sequence(),
        in.elapsedRealtimeMillis(),
        hash,
        in.finished() ? "FINALIZED" : "ACTIVE",
        identity.tenantId(),
        id);
    event(
        identity.tenantId(),
        id,
        "QUOTA_SETTLED",
        Map.of(
            "leaseId",
            id,
            "sequence",
            in.sequence(),
            "cumulativeUsedSeconds",
            used,
            "finished",
            in.finished()));
    return view(leaseRow(identity, id, false));
  }

  private Device device(DeviceContext identity, boolean allowArchived) {
    // Same lifecycle order as policy exceptions: subject -> device -> credential scope.
    var observed = devices.observeActive(identity);
    boolean active = subjects.lockForDevice(identity.tenantId(), observed.subjectId());
    if (!active && !allowArchived) throw conflict("SUBJECT_ARCHIVED");
    var d = devices.lockActive(identity);
    if (!d.subjectId().equals(observed.subjectId())) throw conflict("ACCESS_TARGET_CHANGED");
    credentials.requireActive(identity);
    return d;
  }

  private String calendar(String tenant, String subject) {
    var rows =
        jdbc.queryForList(
            "SELECT time_zone FROM quota_calendars WHERE tenant_id=? AND subject_id=? FOR UPDATE",
            String.class,
            tenant,
            subject);
    if (rows.isEmpty()) throw conflict("QUOTA_TOTAL_REQUIRED");
    return rows.get(0);
  }

  private QuotaPool pool(String tenant, String id, boolean lock) {
    var rows =
        jdbc.query(
            "SELECT * FROM quota_pools WHERE tenant_id=? AND id=?" + (lock ? " FOR UPDATE" : ""),
            this::mapPool,
            tenant,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private QuotaPool mapPool(ResultSet r, int n) throws SQLException {
    long limit = r.getLong("limit_seconds"),
        used = r.getLong("used_seconds"),
        reserved = r.getLong("reserved_seconds");
    return new QuotaPool(
        r.getString("id"),
        r.getString("subject_id"),
        r.getString("name"),
        r.getString("scope_key").equals("TOTAL")
            ? QuotaPool.Scope.TOTAL
            : QuotaPool.Scope.APPLICATION,
        r.getString("application_id"),
        r.getString("period_id"),
        r.getString("time_zone"),
        r.getLong("period_start"),
        r.getLong("period_end"),
        limit,
        used,
        reserved,
        limit - used - reserved,
        "CONFIGURED",
        "LEDGER_ONLY",
        r.getLong("version"),
        r.getString("plan_id"),
        r.getObject("plan_version") == null ? null : r.getLong("plan_version"));
  }

  private StoredLease leaseRow(DeviceContext identity, String id, boolean lock) {
    var rows =
        jdbc.query(
            "SELECT * FROM quota_leases WHERE tenant_id=? AND id=? AND device_id=? AND"
                + " registration_id=?"
                + (lock ? " FOR UPDATE" : ""),
            this::mapLease,
            identity.tenantId(),
            id,
            identity.deviceId(),
            identity.registrationId());
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private StoredLease mapLease(ResultSet r, int n) throws SQLException {
    return new StoredLease(
        new QuotaLease(
            r.getString("id"),
            r.getString("device_id"),
            r.getString("registration_id"),
            r.getString("application_id"),
            r.getString("boot_id"),
            r.getString("session_id"),
            r.getLong("reserved_seconds"),
            r.getLong("used_seconds"),
            r.getLong("last_sequence"),
            r.getLong("issued_at"),
            r.getLong("not_after"),
            r.getString("state"),
            r.getString("signed_lease")),
        r.getString("request_hash"),
        r.getString("last_report_hash"),
        r.getLong("start_tick_millis"),
        r.getLong("last_tick_millis"));
  }

  private QuotaLease view(StoredLease stored) {
    var l = stored.view();
    String state =
        l.state().equals("ACTIVE") && clock.millis() >= l.notAfter()
            ? "AWAITING_RECONCILIATION"
            : l.state();
    return new QuotaLease(
        l.id(),
        l.deviceId(),
        l.registrationId(),
        l.applicationId(),
        l.bootId(),
        l.sessionId(),
        l.reservedSeconds(),
        l.usedSeconds(),
        l.lastSequence(),
        l.issuedAt(),
        l.notAfter(),
        state,
        l.signedLease());
  }

  private void entry(
      String tenant,
      String pool,
      String lease,
      String kind,
      long limit,
      long used,
      long reserved,
      Long sequence,
      String reason) {
    jdbc.update(
        "INSERT INTO"
            + " quota_ledger(tenant_id,id,pool_id,lease_id,kind,limit_delta,used_delta,reserved_delta,sequence_number,reason,occurred_at)"
            + " VALUES(?,?,?,?,?,?,?,?,?,?,?)",
        tenant,
        UUID.randomUUID().toString(),
        pool,
        lease,
        kind,
        limit,
        used,
        reserved,
        sequence,
        reason,
        clock.millis());
  }

  private void event(String tenant, String aggregate, String kind, Map<String, ?> data) {
    jdbc.update(
        "INSERT INTO quota_outbox(id,tenant_id,aggregate_id,event_type,event_json,occurred_at)"
            + " VALUES(?,?,?,?,?,?)",
        UUID.randomUUID().toString(),
        tenant,
        aggregate,
        kind,
        json(data),
        clock.millis());
  }

  private String json(Object value) {
    try {
      return mapper.writeValueAsString(value);
    } catch (JsonProcessingException e) {
      throw new IllegalStateException("Quota document serialization failed", e);
    }
  }

  private void requiredKey(String key) {
    if (key == null || key.isBlank()) throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
  }

  private DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  record Entry(
      String id,
      String leaseId,
      String kind,
      long limitDelta,
      long usedDelta,
      long reservedDelta,
      Long sequence,
      String reason,
      long occurredAt) {}

  private record StoredLease(
      QuotaLease view, String requestHash, String reportHash, long startTick, long lastTick) {}
}

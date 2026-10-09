package com.aimanager.quota.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.quota.*;
import com.aimanager.shared.*;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.*;
import java.time.*;
import java.util.*;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;

@Service
class QuotaPlanService {
  private final JdbcTemplate db;
  private final TenantAccess access;
  private final SubjectAccess subjects;
  private final ApplicationCatalog catalog;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final AuditService audit;
  private final QuotaPoolFactory pools;
  private final ObjectMapper mapper;
  private final Clock clock;

  public Map<String, String> calendarPreview(
      String tenant, String actor, String subject, String defaultTimeZone) {
    var grant = access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR, CHILD);
    if ((grant.role() == CHILD && !subject.equals(grant.subjectId()))
        || !subjects.active(tenant, subject)) throw DomainException.denied();
    var rows =
        db.queryForList(
            "SELECT time_zone FROM quota_calendars WHERE tenant_id=? AND subject_id=?",
            String.class,
            tenant,
            subject);
    ZoneId zone = zone(rows.isEmpty() ? defaultTimeZone : rows.get(0));
    return Map.of(
        "subjectId",
        subject,
        "timeZone",
        zone.getId(),
        "currentDate",
        LocalDate.now(clock.withZone(zone)).toString());
  }

  QuotaPlanService(
      JdbcTemplate db,
      TenantAccess access,
      SubjectAccess subjects,
      ApplicationCatalog catalog,
      RecentAuthentication recent,
      IdempotencyService idempotency,
      AuditService audit,
      QuotaPoolFactory pools,
      ObjectMapper mapper,
      Clock clock) {
    this.db = db;
    this.access = access;
    this.subjects = subjects;
    this.catalog = catalog;
    this.recent = recent;
    this.idempotency = idempotency;
    this.audit = audit;
    this.pools = pools;
    this.mapper = mapper;
    this.clock = clock;
  }

  @Transactional(timeout = 10)
  public QuotaPlan create(String tenant, Jwt actor, QuotaPlanController.Create in, String key) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    key(key);
    subjects.lockActiveForScope(tenant, actor.getSubject(), in.subjectId());
    if ((in.scope() == QuotaPool.Scope.APPLICATION) != (in.applicationId() != null))
      throw DomainException.invalid("QUOTA_SCOPE_MISMATCH");
    if (in.applicationId() != null)
      catalog.requireDeclared(tenant, actor.getSubject(), in.applicationId());
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "quota.plan.create",
        key,
        Map.of("input", in),
        QuotaPlan.class,
        () -> {
          ZoneId zone = zone(in.timeZone());
          LocalDate today = LocalDate.now(clock.withZone(zone)), from = date(in.effectiveFrom());
          if (!from.equals(today) && !from.equals(today.plusDays(1)))
            throw DomainException.invalid("QUOTA_PLAN_START_INVALID");
          var config =
              configuration(
                  in.name(), QuotaPlan.State.ACTIVE, in.weeklyLimits(), in.dateOverrides(), today);
          pools.calendar(tenant, in.subjectId(), zone);
          String id = UUID.randomUUID().toString();
          try {
            db.update(
                "INSERT INTO"
                    + " quota_plans(tenant_id,id,subject_id,scope_key,application_id,time_zone,next_materialize_at,created_at)"
                    + " VALUES(?,?,?,?,?,?,?,?)",
                tenant,
                id,
                in.subjectId(),
                in.scope() == QuotaPool.Scope.TOTAL ? "TOTAL" : "APP:" + in.applicationId(),
                in.applicationId(),
                zone.getId(),
                clock.millis(),
                clock.millis());
          } catch (DuplicateKeyException duplicate) {
            throw conflict("QUOTA_PLAN_EXISTS");
          }
          saveRevision(tenant, id, 0, from, config);
          audit.record(tenant, actor.getSubject(), "QUOTA_PLAN_CREATED", id);
          pools.event(tenant, id, "QUOTA_PLAN_CREATED", Map.of("planId", id, "version", 0));
          materializeLocked(tenant, read(tenant, id, true));
          return read(tenant, id, false);
        });
  }

  @Transactional(timeout = 10)
  public QuotaPlan update(
      String tenant, Jwt actor, String id, QuotaPlanController.Update in, String etag, String key) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    key(key);
    long version = ResourceVersions.require(etag);
    var visible = read(tenant, id, false);
    subjects.lockActiveForScope(tenant, actor.getSubject(), visible.subjectId());
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "quota.plan.update",
        key,
        Map.of("planId", id, "version", version, "input", in),
        QuotaPlan.class,
        () -> {
          ZoneId zone = zone(visible.timeZone());
          pools.calendar(tenant, visible.subjectId(), zone);
          var current = read(tenant, id, true);
          ResourceVersions.check(version, current.version());
          LocalDate today = LocalDate.now(clock.withZone(zone));
          var config =
              configuration(in.name(), in.state(), in.weeklyLimits(), in.dateOverrides(), today);
          long next = version + 1;
          LocalDate from = today.plusDays(1);
          saveRevision(tenant, id, next, from, config);
          db.update(
              "UPDATE quota_plans SET version=?,next_materialize_at=? WHERE tenant_id=? AND id=?",
              next,
              clock.millis(),
              tenant,
              id);
          audit.record(tenant, actor.getSubject(), "QUOTA_PLAN_UPDATED", id);
          pools.event(
              tenant,
              id,
              "QUOTA_PLAN_UPDATED",
              Map.of("planId", id, "version", next, "effectiveFrom", from.toString()));
          return read(tenant, id, false);
        });
  }

  public ItemPage<QuotaPlan> list(String tenant, String actor, int limit, String cursor) {
    var role = access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR, CHILD);
    ItemPage.validate(limit, cursor);
    var args = new ArrayList<Object>(List.of(tenant, cursor == null ? "" : cursor));
    String restriction = role.role() == CHILD ? " AND p.subject_id=?" : "";
    if (role.role() == CHILD) args.add(role.subjectId());
    args.add(limit + 1);
    return ItemPage.from(
        db.query(
            SELECT + " WHERE p.tenant_id=? AND p.id>?" + restriction + " ORDER BY p.id LIMIT ?",
            this::mapPlan,
            args.toArray()),
        limit,
        QuotaPlan::id);
  }

  public QuotaPlan get(String tenant, String actor, String id) {
    var role = access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR, CHILD);
    var plan = read(tenant, id, false);
    if (role.role() == CHILD && !plan.subjectId().equals(role.subjectId()))
      throw DomainException.denied();
    return plan;
  }

  public ItemPage<QuotaPlan.Revision> revisions(
      String tenant, String actor, String id, int limit, String cursor) {
    get(tenant, actor, id);
    if (limit < 1 || limit > 100) throw DomainException.invalid("INVALID_PAGE_SIZE");
    long before = Long.MAX_VALUE;
    if (cursor != null) {
      try {
        before = Long.parseLong(cursor);
        if (before < 0 || !Long.toString(before).equals(cursor)) throw new NumberFormatException();
      } catch (NumberFormatException bad) {
        throw DomainException.invalid("INVALID_CURSOR");
      }
    }
    var rows =
        db.query(
            "SELECT * FROM quota_plan_revisions WHERE tenant_id=? AND plan_id=? AND version<? ORDER"
                + " BY version DESC LIMIT ?",
            this::mapRevision,
            tenant,
            id,
            before,
            limit + 1);
    return ItemPage.from(rows, limit, r -> Long.toString(r.version()));
  }

  /**
   * Caller already owns subject/device/credential locks. Materialize both intersecting scopes
   * before reserving.
   */
  @Transactional(propagation = Propagation.MANDATORY)
  public void materializeForDevice(String tenant, String subject, String application) {
    var rows =
        db.queryForList(
            "SELECT id FROM quota_plans WHERE tenant_id=? AND subject_id=? AND (scope_key='TOTAL'"
                + " OR application_id=?) ORDER BY id FOR UPDATE",
            String.class,
            tenant,
            subject,
            application);
    for (String id : rows) {
      var plan = read(tenant, id, true);
      materializeLocked(tenant, plan);
    }
  }

  @Transactional(timeout = 10)
  public boolean materializeOne(String tenant, String id) {
    var observed = read(tenant, id, false);
    if (!subjects.lockForDevice(tenant, observed.subjectId())) {
      db.update(
          "UPDATE quota_plans SET next_materialize_at=? WHERE tenant_id=? AND id=?",
          Long.MAX_VALUE,
          tenant,
          id);
      return false;
    }
    pools.calendar(tenant, observed.subjectId(), zone(observed.timeZone()));
    var plan = read(tenant, id, true);
    Long due =
        db.queryForObject(
            "SELECT next_materialize_at FROM quota_plans WHERE tenant_id=? AND id=? FOR UPDATE",
            Long.class,
            tenant,
            id);
    if (due > clock.millis()) return false;
    materializeLocked(tenant, plan);
    return true;
  }

  private void materializeLocked(String tenant, QuotaPlan plan) {
    ZoneId zone = zone(plan.timeZone());
    LocalDate today = LocalDate.now(clock.withZone(zone));
    var revisions =
        db.query(
            "SELECT * FROM quota_plan_revisions WHERE tenant_id=? AND plan_id=? AND"
                + " effective_from<=? ORDER BY effective_from DESC,version DESC LIMIT 1 FOR UPDATE",
            this::mapRevision,
            tenant,
            plan.id(),
            today.toString());
    if (!revisions.isEmpty()) {
      var revision = revisions.get(0);
      var config = revision.configuration();
      if (config.state() == QuotaPlan.State.ACTIVE) {
        long amount =
            config
                .dateOverrides()
                .getOrDefault(today.toString(), config.weeklyLimits().get(today.getDayOfWeek()));
        pools.create(
            tenant,
            plan.subjectId(),
            config.name(),
            plan.scope(),
            plan.applicationId(),
            today,
            zone,
            amount,
            plan.id(),
            revision.version(),
            "system:quota-plan");
      }
    }
    long next = today.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli();
    db.update(
        "UPDATE quota_plans SET next_materialize_at=? WHERE tenant_id=? AND id=?",
        next,
        tenant,
        plan.id());
  }

  private QuotaPlan read(String tenant, String id, boolean lock) {
    var rows =
        db.query(
            SELECT + " WHERE p.tenant_id=? AND p.id=?" + (lock ? " FOR UPDATE" : ""),
            this::mapPlan,
            tenant,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private QuotaPlan mapPlan(ResultSet row, int index) throws SQLException {
    var config = decode(row.getString("configuration_json"));
    return new QuotaPlan(
        row.getString("id"),
        row.getString("subject_id"),
        row.getString("scope_key").equals("TOTAL")
            ? QuotaPool.Scope.TOTAL
            : QuotaPool.Scope.APPLICATION,
        row.getString("application_id"),
        row.getString("time_zone"),
        config.name(),
        config.state(),
        row.getString("effective_from"),
        config.weeklyLimits(),
        config.dateOverrides(),
        row.getLong("version"),
        row.getLong("created_at"));
  }

  private QuotaPlan.Revision mapRevision(ResultSet row, int index) throws SQLException {
    return new QuotaPlan.Revision(
        row.getLong("version"),
        row.getString("effective_from"),
        decode(row.getString("configuration_json")),
        row.getLong("created_at"));
  }

  private QuotaPlan.Configuration configuration(
      String name,
      QuotaPlan.State state,
      Map<DayOfWeek, Long> weekly,
      Map<String, Long> overrides,
      LocalDate today) {
    if (!weekly.keySet().equals(EnumSet.allOf(DayOfWeek.class)))
      throw DomainException.invalid("QUOTA_WEEK_INCOMPLETE");
    for (String text : overrides.keySet()) {
      LocalDate date = date(text);
      if (date.isAfter(today.plusDays(366)))
        throw DomainException.invalid("QUOTA_OVERRIDE_INVALID");
    }
    // Expired overrides may be carried forward when editing; they never materialize past budgets.
    return new QuotaPlan.Configuration(
        name.strip(), state, new EnumMap<>(weekly), new TreeMap<>(overrides));
  }

  private void saveRevision(
      String tenant, String id, long version, LocalDate from, QuotaPlan.Configuration config) {
    try {
      db.update(
          "INSERT INTO"
              + " quota_plan_revisions(tenant_id,plan_id,version,effective_from,configuration_json,created_at)"
              + " VALUES(?,?,?,?,?,?)",
          tenant,
          id,
          version,
          from.toString(),
          mapper.writeValueAsString(config),
          clock.millis());
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Quota plan serialization failed", failure);
    }
  }

  private QuotaPlan.Configuration decode(String value) {
    try {
      return mapper.readValue(value, QuotaPlan.Configuration.class);
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Stored quota plan invalid", failure);
    }
  }

  private static LocalDate date(String value) {
    try {
      var date = LocalDate.parse(value);
      if (!date.toString().equals(value) || value.length() != 10)
        throw new DateTimeException("Noncanonical date");
      return date;
    } catch (DateTimeException failure) {
      throw DomainException.invalid("INVALID_QUOTA_PERIOD");
    }
  }

  private static ZoneId zone(String value) {
    try {
      return ZoneId.of(value);
    } catch (DateTimeException failure) {
      throw DomainException.invalid("INVALID_TIME_ZONE");
    }
  }

  private static void key(String key) {
    if (key == null || key.isBlank()) throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private static final String SELECT =
      "SELECT p.*,r.configuration_json,r.effective_from FROM quota_plans p JOIN"
          + " quota_plan_revisions r ON r.tenant_id=p.tenant_id AND r.plan_id=p.id AND"
          + " r.version=p.version";
}

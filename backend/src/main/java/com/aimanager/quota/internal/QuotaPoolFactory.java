package com.aimanager.quota.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.quota.QuotaPool;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.*;

/**
 * Single creation path for manual and automatic daily pools. Callers already own the subject lock.
 */
@Component
class QuotaPoolFactory {
  private final JdbcTemplate db;
  private final AuditService audit;
  private final ObjectMapper mapper;
  private final Clock clock;

  QuotaPoolFactory(JdbcTemplate db, AuditService audit, ObjectMapper mapper, Clock clock) {
    this.db = db;
    this.audit = audit;
    this.mapper = mapper;
    this.clock = clock;
  }

  @Transactional(propagation = Propagation.MANDATORY)
  public void calendar(String tenant, String subject, ZoneId zone) {
    try {
      db.update(
          "INSERT INTO quota_calendars(tenant_id,subject_id,time_zone) VALUES(?,?,?)",
          tenant,
          subject,
          zone.getId());
    } catch (DuplicateKeyException existing) {
      /* Subject lifecycle lock serializes creation. */
    }
    String current =
        db.queryForObject(
            "SELECT time_zone FROM quota_calendars WHERE tenant_id=? AND subject_id=? FOR UPDATE",
            String.class,
            tenant,
            subject);
    if (!zone.getId().equals(current)) throw conflict("QUOTA_TIME_ZONE_LOCKED");
  }

  @Transactional(propagation = Propagation.MANDATORY)
  public String create(
      String tenant,
      String subject,
      String name,
      QuotaPool.Scope scope,
      String application,
      LocalDate date,
      ZoneId zone,
      long seconds,
      String plan,
      Long revision,
      String actor) {
    String scopeKey = scope == QuotaPool.Scope.TOTAL ? "TOTAL" : "APP:" + application;
    var existing =
        db.queryForList(
            "SELECT id FROM quota_pools WHERE tenant_id=? AND subject_id=? AND scope_key=? AND"
                + " period_id=? FOR UPDATE",
            String.class,
            tenant,
            subject,
            scopeKey,
            date.toString());
    if (!existing.isEmpty()) {
      if (plan != null)
        return existing.get(0); // A manual or previously generated snapshot is authoritative.
      throw conflict("QUOTA_POOL_EXISTS");
    }
    long start = date.atStartOfDay(zone).toInstant().toEpochMilli();
    long end = date.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli();
    if (end <= start) throw conflict("QUOTA_PERIOD_UNAVAILABLE");
    if (scope == QuotaPool.Scope.APPLICATION
        && Boolean.TRUE.equals(
            db.queryForObject(
                "SELECT COUNT(*)>0 FROM quota_leases WHERE tenant_id=? AND subject_id=? AND"
                    + " application_id=? AND issued_at>=? AND issued_at<?",
                Boolean.class,
                tenant,
                subject,
                application,
                start,
                end))) throw conflict("QUOTA_SCOPE_ALREADY_USED");
    String id = UUID.randomUUID().toString();
    try {
      db.update(
          "INSERT INTO"
              + " quota_pools(tenant_id,id,subject_id,name,scope_key,application_id,period_id,time_zone,period_start,period_end,limit_seconds,plan_id,plan_version)"
              + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
          tenant,
          id,
          subject,
          name.strip(),
          scopeKey,
          application,
          date.toString(),
          zone.getId(),
          start,
          end,
          seconds,
          plan,
          revision);
    } catch (DuplicateKeyException duplicate) {
      throw conflict("QUOTA_POOL_EXISTS");
    }
    db.update(
        "INSERT INTO"
            + " quota_ledger(tenant_id,id,pool_id,kind,limit_delta,used_delta,reserved_delta,reason,occurred_at)"
            + " VALUES(?,?,?,'CREATED',?,0,0,?,?)",
        tenant,
        UUID.randomUUID().toString(),
        id,
        seconds,
        plan == null ? null : "AUTOMATIC_PLAN",
        clock.millis());
    audit.record(tenant, actor, "QUOTA_POOL_CREATED", id);
    event(
        tenant,
        id,
        "QUOTA_POOL_CREATED",
        Map.of("poolId", id, "source", plan == null ? "MANUAL" : "PLAN"));
    return id;
  }

  void event(String tenant, String aggregate, String kind, Object data) {
    try {
      db.update(
          "INSERT INTO quota_outbox(id,tenant_id,aggregate_id,event_type,event_json,occurred_at)"
              + " VALUES(?,?,?,?,?,?)",
          UUID.randomUUID().toString(),
          tenant,
          aggregate,
          kind,
          mapper.writeValueAsString(data),
          clock.millis());
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Quota event serialization failed", failure);
    }
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }
}

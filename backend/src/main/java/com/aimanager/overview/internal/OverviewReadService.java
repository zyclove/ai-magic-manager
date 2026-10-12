package com.aimanager.overview.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.identity.ActorKeys;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.ArrayList;
import java.util.List;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/** Bounded cross-domain read model; never loads complete tenant collections for dashboard counts. */
@Service
class OverviewReadService {
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final Clock clock;
  private final long observationAgeMillis;

  OverviewReadService(
      JdbcTemplate jdbc,
      TenantAccess access,
      Clock clock,
      @Value("${manager.devices.observation-max-age-seconds:180}") long observationAge) {
    if (observationAge < 30 || observationAge > 86400)
      throw new IllegalArgumentException("Invalid observation age");
    this.jdbc = jdbc;
    this.access = access;
    this.clock = clock;
    this.observationAgeMillis = observationAge * 1000;
  }

  Summary read(String tenant, String actor) {
    var grant = access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, TEACHER, CHILD, AUDITOR);
    boolean inventory = grant.role() != AUDITOR;
    boolean policies = grant.role() != TEACHER && grant.role() != CHILD;
    long now = clock.millis();

    Long subjects = null;
    Long devices = null;
    Long needsConnectionCheck = null;
    if (inventory) {
      var subjectScope = access.subjectFilter(tenant, actor, grant, "s.id");
      subjects = count(
          "SELECT COUNT(*) FROM subjects s WHERE s.tenant_id=? AND s.archived_at IS NULL AND "
              + subjectScope.sql(),
          tenant,
          subjectScope.args());
      var deviceScope = access.subjectFilter(tenant, actor, grant, "d.subject_id");
      String deviceWhere =
          " FROM devices d WHERE d.tenant_id=? AND d.state='ACTIVE' AND " + deviceScope.sql();
      devices = count("SELECT COUNT(*)" + deviceWhere, tenant, deviceScope.args());
      var connectionArgs = new ArrayList<Object>(deviceScope.args());
      connectionArgs.add(now - observationAgeMillis);
      needsConnectionCheck = count(
          "SELECT COUNT(*)" + deviceWhere
              + " AND (d.last_heartbeat_at IS NULL OR d.last_heartbeat_at<?)",
          tenant,
          connectionArgs);
    }

    Long drafts = policies
        ? jdbc.queryForObject(
            "SELECT COUNT(*) FROM policy_drafts WHERE tenant_id=?", Long.class, tenant)
        : null;
    var requestScope = access.subjectFilter(tenant, actor, grant, "ar.subject_id");
    var requestArgs = new ArrayList<Object>(List.of(now));
    requestArgs.addAll(requestScope.args());
    boolean ownRequests = grant.role() == CHILD || grant.role() == TEACHER;
    if (ownRequests) requestArgs.add(ActorKeys.key(actor));
    Long pending = count(
        "SELECT COUNT(*) FROM access_requests ar WHERE ar.tenant_id=? AND ar.state='PENDING'"
            + " AND ar.request_expires_at>? AND " + requestScope.sql()
            + (ownRequests ? " AND ar.requester_kind='MEMBER' AND ar.requester_actor_key=?" : ""),
        tenant,
        requestArgs);
    Long openHelp = null;
    boolean teacherOrganization = grant.role() != TEACHER || "ORGANIZATION".equals(
        jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?", String.class, tenant));
    if (teacherOrganization && (grant.role() == OWNER || grant.role() == GUARDIAN
        || grant.role() == ORG_ADMIN || grant.role() == TEACHER)) {
      var helpScope = access.subjectFilter(tenant, actor, grant, "h.subject_id");
      openHelp = count(
          "SELECT COUNT(*) FROM child_help_requests h WHERE h.tenant_id=? AND h.state='OPEN'"
              + " AND " + helpScope.sql(),
          tenant, helpScope.args());
    }
    List<Activity> activity = policies
        ? jdbc.query(
            "SELECT id,action,resource_id,occurred_at FROM audit_events WHERE tenant_id=?"
                + " ORDER BY occurred_at DESC,id DESC LIMIT 5",
            (row, index) -> new Activity(
                row.getString("id"), row.getString("action"), row.getString("resource_id"),
                row.getLong("occurred_at")),
            tenant)
        : List.of();
    return new Summary(subjects, devices, needsConnectionCheck, drafts, pending, openHelp, activity);
  }

  private long count(String sql, String tenant, List<Object> rest) {
    var parameters = new ArrayList<Object>(rest.size() + 1);
    parameters.add(tenant);
    parameters.addAll(rest);
    return jdbc.queryForObject(sql, Long.class, parameters.toArray());
  }

  record Activity(String id, String action, String resourceId, long occurredAt) {}

  /** A null count means this role cannot read that domain, not that the count is zero. */
  record Summary(
      Long subjectCount,
      Long activeDeviceCount,
      Long connectionCheckCount,
      Long policyDraftCount,
      Long pendingRequestCount,
      Long openHelpRequestCount,
      List<Activity> recentActivity) {}
}

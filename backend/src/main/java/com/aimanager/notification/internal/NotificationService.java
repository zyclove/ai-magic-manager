package com.aimanager.notification.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.approval.AccessRequest;
import com.aimanager.approval.AccessRequestChanged;
import com.aimanager.identity.ActorKeys;
import com.aimanager.notification.NotificationMaintenance;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import java.nio.charset.StandardCharsets;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.event.EventListener;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Inbox facts are immutable; access is evaluated against current persisted membership and scope.
 */
@Service
class NotificationService implements NotificationMaintenance {
  private static final TenantAccess.Role[] ROLES = {OWNER, GUARDIAN, ORG_ADMIN, TEACHER, CHILD};
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final Clock clock;
  private final long retentionMillis;

  NotificationService(
      JdbcTemplate jdbc,
      TenantAccess access,
      Clock clock,
      @Value("${manager.notifications.retention-days:30}") long retentionDays) {
    if (retentionDays < 1 || retentionDays > 365)
      throw new IllegalArgumentException("Invalid notification retention");
    this.jdbc = jdbc;
    this.access = access;
    this.clock = clock;
    this.retentionMillis = retentionDays * 86400000;
  }

  @EventListener
  @Transactional(propagation = Propagation.MANDATORY)
  public void record(AccessRequestChanged event) {
    try {
      jdbc.update(
          "INSERT INTO"
              + " notification_events(tenant_id,id,request_id,subject_id,device_id,requester_actor_key,request_version,state,occurred_at)"
              + " VALUES(?,?,?,?,?,?,?,?,?)",
          event.tenantId(),
          UUID.randomUUID().toString(),
          event.requestId(),
          event.subjectId(),
          event.deviceId(),
          event.requesterKey(),
          event.requestVersion(),
          event.state().name(),
          event.occurredAt());
    } catch (DuplicateKeyException duplicate) {
      // Domain replays may repeat delivery, but cannot replace a previously recorded version.
      var existing =
          jdbc.query(
              "SELECT subject_id,device_id,requester_actor_key,state FROM notification_events WHERE"
                  + " tenant_id=? AND request_id=? AND request_version=? FOR UPDATE",
              (r, i) -> List.of(r.getString(1), r.getString(2), r.getString(3), r.getString(4)),
              event.tenantId(),
              event.requestId(),
              event.requestVersion());
      if (existing.size() != 1
          || !existing
              .get(0)
              .equals(
                  List.of(
                      event.subjectId(),
                      event.deviceId(),
                      event.requesterKey(),
                      event.state().name())))
        throw new IllegalStateException("Conflicting notification version");
    }
  }

  @Transactional(readOnly = true)
  public Page list(String tenant, String actor, int limit, String cursor, boolean unreadOnly) {
    var grant = access.requireRole(tenant, actor, ROLES);
    if (limit < 1 || limit > 50) throw DomainException.invalid("INVALID_PAGE_SIZE");
    var before = Cursor.parse(cursor);
    var scope = scope(tenant, actor, grant);
    var args = new ArrayList<Object>();
    args.add(ActorKeys.key(actor));
    args.addAll(scope.args());
    String filter = scope.sql();
    if (unreadOnly) filter += " AND r.read_at IS NULL";
    if (before != null) {
      filter += " AND (n.occurred_at<? OR (n.occurred_at=? AND n.id<?))";
      args.add(before.at());
      args.add(before.at());
      args.add(before.id());
    }
    args.add(limit + 1);
    var rows =
        jdbc.query(
            "SELECT n.*,r.read_at FROM notification_events n LEFT JOIN notification_reads r ON"
                + " r.tenant_id=n.tenant_id AND r.notification_id=n.id AND r.actor_key=? WHERE "
                + filter
                + " ORDER BY n.occurred_at DESC,n.id DESC LIMIT ?",
            (r, i) -> map(r),
            args.toArray());
    boolean more = rows.size() > limit;
    var page = List.copyOf(rows.subList(0, Math.min(rows.size(), limit)));
    var last = page.isEmpty() ? null : page.get(page.size() - 1);
    return new Page(page, more ? new Cursor(last.occurredAt(), last.id()).encode() : null);
  }

  @Transactional(readOnly = true)
  public UnreadCount unreadCount(String tenant, String actor) {
    var scope = scope(tenant, actor, access.requireRole(tenant, actor, ROLES));
    var args = new ArrayList<Object>(scope.args());
    args.add(ActorKeys.key(actor));
    long count =
        jdbc.queryForObject(
            "SELECT COUNT(*) FROM (SELECT n.id FROM notification_events n WHERE "
                + scope.sql()
                + " AND NOT EXISTS (SELECT 1 FROM notification_reads r WHERE"
                + " r.tenant_id=n.tenant_id AND r.notification_id=n.id AND r.actor_key=?) LIMIT"
                + " 1001) notice_count",
            Long.class,
            args.toArray());
    return new UnreadCount(Math.min(count, 1000), count > 1000);
  }

  @Transactional(timeout = 10)
  public ReadReceipt read(String tenant, String actor, String id) {
    return readBatch(tenant, actor, List.of(id)).items().get(0);
  }

  @Transactional(timeout = 10)
  public ReadBatch readBatch(String tenant, String actor, List<String> ids) {
    var grant = access.requireWriteRole(tenant, actor, ROLES);
    if (ids == null || ids.isEmpty() || ids.size() > 50 || new HashSet<>(ids).size() != ids.size())
      throw DomainException.invalid("INVALID_NOTIFICATION_SELECTION");
    ids.forEach(NotificationService::validateId);
    var ordered = ids.stream().sorted().toList();
    var scope = scope(tenant, actor, grant);
    // Lock all visible facts before any read state changes; one foreign ID cannot partly succeed.
    for (String id : ordered) {
      var args = new ArrayList<Object>(scope.args());
      args.add(id);
      var found =
          jdbc.queryForList(
              "SELECT n.id FROM notification_events n WHERE "
                  + scope.sql()
                  + " AND n.id=? FOR UPDATE",
              String.class,
              args.toArray());
      if (found.size() != 1) throw DomainException.denied();
    }
    String actorKey = ActorKeys.key(actor);
    var receipts = new ArrayList<ReadReceipt>();
    for (String id : ordered) {
      var existing =
          jdbc.queryForList(
              "SELECT read_at FROM notification_reads WHERE tenant_id=? AND notification_id=? AND"
                  + " actor_key=?",
              Long.class,
              tenant,
              id,
              actorKey);
      long at = existing.isEmpty() ? clock.millis() : existing.get(0);
      if (existing.isEmpty())
        jdbc.update(
            "INSERT INTO notification_reads(tenant_id,notification_id,actor_key,read_at)"
                + " VALUES(?,?,?,?)",
            tenant,
            id,
            actorKey,
            at);
      receipts.add(new ReadReceipt(id, at));
    }
    return new ReadBatch(List.copyOf(receipts));
  }

  private TenantAccess.ScopeFilter scope(String tenant, String actor, TenantAccess.Grant grant) {
    var subject = access.subjectFilter(tenant, actor, grant, "n.subject_id");
    String sql = "n.tenant_id=? AND n.occurred_at>=? AND " + subject.sql();
    var args = new ArrayList<Object>(List.of(tenant, clock.millis() - retentionMillis));
    args.addAll(subject.args());
    if (grant.role() == CHILD || grant.role() == TEACHER) {
      sql += " AND n.requester_actor_key=?";
      args.add(ActorKeys.key(actor));
    }
    return new TenantAccess.ScopeFilter(sql, args);
  }

  @Override
  @Transactional(timeout = 10)
  public int purgeExpired(int limit) {
    if (limit < 1 || limit > 500)
      throw new IllegalArgumentException("Invalid notification purge batch");
    long cutoff = clock.millis() - retentionMillis;
    var records =
        jdbc
            .query(
                "SELECT tenant_id,id FROM notification_events WHERE occurred_at<? ORDER BY"
                    + " occurred_at,tenant_id,id LIMIT ?",
                (r, i) -> new Expired(r.getString(1), r.getString(2)),
                cutoff,
                limit)
            .stream()
            .sorted(Comparator.comparing(Expired::tenant).thenComparing(Expired::id))
            .toList();
    int count = 0;
    for (var record : records)
      count +=
          jdbc.update(
              "DELETE FROM notification_events WHERE tenant_id=? AND id=? AND occurred_at<?",
              record.tenant(),
              record.id(),
              cutoff);
    return count;
  }

  private static Notice map(ResultSet row) throws SQLException {
    var read = (Number) row.getObject("read_at");
    return new Notice(
        row.getString("id"),
        row.getString("request_id"),
        row.getString("subject_id"),
        row.getString("device_id"),
        row.getLong("request_version"),
        AccessRequest.State.valueOf(row.getString("state")),
        row.getLong("occurred_at"),
        read == null ? null : read.longValue());
  }

  private static void validateId(String id) {
    try {
      if (id == null || !UUID.fromString(id).toString().equals(id))
        throw new IllegalArgumentException();
    } catch (IllegalArgumentException invalid) {
      throw DomainException.invalid("INVALID_NOTIFICATION_SELECTION");
    }
  }

  record Notice(
      String id,
      String requestId,
      String subjectId,
      String deviceId,
      long requestVersion,
      AccessRequest.State state,
      long occurredAt,
      Long readAt) {}

  record Page(List<Notice> items, String nextCursor) {}

  record UnreadCount(long count, boolean capped) {}

  record ReadReceipt(String id, long readAt) {}

  record ReadBatch(List<ReadReceipt> items) {}

  private record Expired(String tenant, String id) {}

  private record Cursor(long at, String id) {
    String encode() {
      return Base64.getUrlEncoder()
          .withoutPadding()
          .encodeToString((at + ":" + id).getBytes(StandardCharsets.US_ASCII));
    }

    static Cursor parse(String value) {
      if (value == null) return null;
      try {
        if (!value.matches("[A-Za-z0-9_-]{1,100}")) throw new IllegalArgumentException();
        String decoded =
            new String(Base64.getUrlDecoder().decode(value), StandardCharsets.US_ASCII);
        if (!decoded.matches("(?:0|[1-9][0-9]{0,15}):[0-9a-f-]{36}"))
          throw new IllegalArgumentException();
        var parts = decoded.split(":", 2);
        long at = Long.parseLong(parts[0]);
        if (at > 9007199254740991L || !UUID.fromString(parts[1]).toString().equals(parts[1]))
          throw new IllegalArgumentException();
        var result = new Cursor(at, parts[1]);
        if (!result.encode().equals(value)) throw new IllegalArgumentException();
        return result;
      } catch (IllegalArgumentException failure) {
        throw DomainException.invalid("INVALID_CURSOR");
      }
    }
  }
}

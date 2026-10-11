package com.aimanager.fleet.internal;

import static com.aimanager.tenant.TenantAccess.Role.ORG_ADMIN;
import static com.aimanager.tenant.TenantAccess.Role.OWNER;

import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.TenantAccess;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Institution device-group facts. Group membership is never interpreted as a delivered or applied
 * device policy. Every mutation serializes with current membership revocation and the group row.
 */
@Service
class DeviceGroupService {
  private static final int MAX_MEMBERS = 5000;
  private final JdbcTemplate db;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final AuditService audit;
  private final Clock clock;

  DeviceGroupService(
      JdbcTemplate db,
      TenantAccess access,
      RecentAuthentication recent,
      IdempotencyService idempotency,
      AuditService audit,
      Clock clock) {
    this.db = db;
    this.access = access;
    this.recent = recent;
    this.idempotency = idempotency;
    this.audit = audit;
    this.clock = clock;
  }

  private void organization(String tenant) {
    String kind = db.queryForObject("SELECT kind FROM tenants WHERE id=?", String.class, tenant);
    if (!"ORGANIZATION".equals(kind)) throw DomainException.invalid("ORGANIZATION_REQUIRED");
  }

  private void canRead(String tenant, String actor) {
    access.requireRole(tenant, actor, OWNER, ORG_ADMIN);
    organization(tenant);
  }

  private void canWrite(String tenant, Jwt actor) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, ORG_ADMIN);
    organization(tenant);
    recent.require(actor);
  }

  private String name(String input) {
    if (input == null) throw DomainException.invalid("INVALID_DEVICE_GROUP_NAME");
    String value = input.strip();
    if (value.isEmpty()
        || value.length() > 100
        || value.codePoints().anyMatch(c -> Character.isISOControl(c) || Character.getType(c) == Character.FORMAT)) {
      throw DomainException.invalid("INVALID_DEVICE_GROUP_NAME");
    }
    return value;
  }

  private String nameKey(String value) {
    try {
      return HexFormat.of()
          .formatHex(MessageDigest.getInstance("SHA-256")
              .digest(value.toLowerCase(Locale.ROOT).getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException impossible) {
      throw new IllegalStateException("SHA-256 unavailable", impossible);
    }
  }

  @Transactional(timeout = 10)
  Group create(String tenant, Jwt actor, String inputName, String key) {
    canWrite(tenant, actor);
    String normalized = name(inputName);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "device.group.create",
        key,
        Map.of("name", normalized),
        Group.class,
        () -> {
          String id = UUID.randomUUID().toString();
          long now = clock.millis();
          try {
            db.update(
                "INSERT INTO device_groups(tenant_id,id,name,name_key,created_at,updated_at)"
                    + " VALUES(?,?,?,?,?,?)",
                tenant,
                id,
                normalized,
                nameKey(normalized),
                now,
                now);
          } catch (DuplicateKeyException duplicate) {
            throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_NAME_EXISTS");
          }
          audit.record(tenant, actor.getSubject(), "DEVICE_GROUP_CREATED", id);
          return read(tenant, id, false);
        });
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<Group> list(String tenant, String actor, int limit, String cursor, boolean archived) {
    canRead(tenant, actor);
    ItemPage.validate(limit, cursor);
    List<String> ids = db.queryForList(
        "SELECT id FROM device_groups WHERE tenant_id=? AND id>?"
            + (archived ? "" : " AND archived_at IS NULL")
            + " ORDER BY id LIMIT ?",
        String.class,
        tenant,
        cursor == null ? "" : cursor,
        limit + 1);
    var page = ItemPage.from(ids, limit, id -> id);
    return new ItemPage<>(
        page.items().stream().map(id -> read(tenant, id, false)).toList(), page.nextCursor());
  }

  @Transactional(readOnly = true, timeout = 10)
  Group get(String tenant, String actor, String id) {
    canRead(tenant, actor);
    return read(tenant, id, false);
  }

  @Transactional(timeout = 10)
  Group rename(String tenant, Jwt actor, String id, String inputName, String etag, String key) {
    canWrite(tenant, actor);
    String normalized = name(inputName);
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "device.group.rename",
        key,
        Map.of("id", id, "name", normalized, "version", expected),
        Group.class,
        () -> {
          Group current = read(tenant, id, true);
          ResourceVersions.check(expected, current.version());
          active(current);
          if (current.name().equals(normalized)) return current;
          try {
            db.update(
                "UPDATE device_groups SET name=?,name_key=?,version=version+1,updated_at=?"
                    + " WHERE tenant_id=? AND id=?",
                normalized,
                nameKey(normalized),
                clock.millis(),
                tenant,
                id);
          } catch (DuplicateKeyException duplicate) {
            throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_NAME_EXISTS");
          }
          audit.record(tenant, actor.getSubject(), "DEVICE_GROUP_RENAMED", id);
          return read(tenant, id, true);
        });
  }

  @Transactional(timeout = 10)
  Group archive(String tenant, Jwt actor, String id, String etag, String key) {
    canWrite(tenant, actor);
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "device.group.archive",
        key,
        Map.of("id", id, "version", expected),
        Group.class,
        () -> {
          Group current = read(tenant, id, true);
          ResourceVersions.check(expected, current.version());
          if (current.state().equals("ARCHIVED")) return current;
          long now = clock.millis();
          db.update(
              "UPDATE device_groups SET archived_at=?,version=version+1,updated_at=?"
                  + " WHERE tenant_id=? AND id=?",
              now,
              now,
              tenant,
              id);
          audit.record(tenant, actor.getSubject(), "DEVICE_GROUP_ARCHIVED", id);
          return read(tenant, id, true);
        });
  }

  @Transactional(timeout = 10)
  Group member(
      String tenant,
      Jwt actor,
      String groupId,
      String deviceId,
      String registrationId,
      boolean add,
      String etag,
      String key) {
    canWrite(tenant, actor);
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        add ? "device.group.member.add" : "device.group.member.remove",
        key,
        Map.of("group", groupId, "device", deviceId, "registration", registrationId,
            "version", expected),
        Group.class,
        () -> {
          Group current = read(tenant, groupId, true);
          ResourceVersions.check(expected, current.version());
          active(current);
          var existing = db.queryForList(
              "SELECT registration_id FROM device_group_members WHERE tenant_id=?"
                  + " AND group_id=? AND device_id=?",
              String.class,
              tenant,
              groupId,
              deviceId);
          if (add) {
            var device = db.queryForList(
                "SELECT d.registration_id,d.state,s.archived_at FROM devices d JOIN subjects s"
                    + " ON s.tenant_id=d.tenant_id AND s.id=d.subject_id"
                    + " WHERE d.tenant_id=? AND d.id=? FOR UPDATE",
                tenant,
                deviceId);
            if (device.isEmpty() || !registrationId.equals(device.get(0).get("registration_id"))
                || !"ACTIVE".equals(device.get(0).get("state"))
                || device.get(0).get("archived_at") != null) {
              throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_DEVICE_UNAVAILABLE");
            }
            if (!existing.isEmpty()) {
              if (registrationId.equals(existing.get(0))) return current;
              throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_STALE_MEMBERSHIP");
            }
            if (current.deviceCount() >= MAX_MEMBERS) {
              throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_CAPACITY_REACHED");
            }
            db.update(
                "INSERT INTO device_group_members(tenant_id,group_id,device_id,registration_id,added_at)"
                    + " VALUES(?,?,?,?,?)",
                tenant,
                groupId,
                deviceId,
                registrationId,
                clock.millis());
          } else {
            if (existing.isEmpty()) return current;
            if (!registrationId.equals(existing.get(0))) {
              throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_STALE_MEMBERSHIP");
            }
            db.update(
                "DELETE FROM device_group_members WHERE tenant_id=? AND group_id=? AND device_id=?",
                tenant,
                groupId,
                deviceId);
          }
          db.update(
              "UPDATE device_groups SET version=version+1,updated_at=? WHERE tenant_id=? AND id=?",
              clock.millis(),
              tenant,
              groupId);
          audit.record(tenant, actor.getSubject(),
              add ? "DEVICE_GROUP_MEMBER_ADDED" : "DEVICE_GROUP_MEMBER_REMOVED",
              groupId + "/" + deviceId);
          return read(tenant, groupId, true);
        });
  }

  /** Atomically adds an explicit, bounded device selection to one institution group. */
  @Transactional(timeout = 15)
  Group addMembers(
      String tenant,
      Jwt actor,
      String groupId,
      List<DeviceTarget> targets,
      String etag,
      String key) {
    canWrite(tenant, actor);
    long expected = ResourceVersions.require(etag);
    if (key == null) throw DomainException.invalid("IDEMPOTENCY_KEY_REQUIRED");
    if (targets == null || targets.isEmpty() || targets.size() > 50
        || targets.stream().anyMatch(t -> t == null || t.deviceId() == null
            || t.registrationId() == null)
        || new HashSet<>(targets.stream().map(DeviceTarget::deviceId).toList()).size()
            != targets.size()) {
      throw DomainException.invalid("INVALID_DEVICE_GROUP_BATCH");
    }
    var ordered = targets.stream().sorted(java.util.Comparator.comparing(DeviceTarget::deviceId)).toList();
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "device.group.members.add",
        key,
        Map.of("group", groupId, "targets", ordered, "version", expected),
        Group.class,
        () -> {
          Group current = read(tenant, groupId, true);
          ResourceVersions.check(expected, current.version());
          active(current);
          var additions = new java.util.ArrayList<DeviceTarget>();
          for (var target : ordered) {
            var device = db.queryForList(
                "SELECT d.registration_id,d.state,s.archived_at FROM devices d JOIN subjects s"
                    + " ON s.tenant_id=d.tenant_id AND s.id=d.subject_id"
                    + " WHERE d.tenant_id=? AND d.id=? FOR UPDATE",
                tenant,
                target.deviceId());
            if (device.isEmpty()
                || !target.registrationId().equals(device.get(0).get("registration_id"))
                || !"ACTIVE".equals(device.get(0).get("state"))
                || device.get(0).get("archived_at") != null) {
              throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_DEVICE_UNAVAILABLE");
            }
            var existing = db.queryForList(
                "SELECT registration_id FROM device_group_members WHERE tenant_id=?"
                    + " AND group_id=? AND device_id=?",
                String.class,
                tenant,
                groupId,
                target.deviceId());
            if (!existing.isEmpty()) {
              if (!target.registrationId().equals(existing.get(0))) {
                throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_STALE_MEMBERSHIP");
              }
            } else {
              additions.add(target);
            }
          }
          if (current.deviceCount() + additions.size() > MAX_MEMBERS) {
            throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_CAPACITY_REACHED");
          }
          if (additions.isEmpty()) return current;
          long now = clock.millis();
          for (var target : additions) {
            db.update(
                "INSERT INTO device_group_members(tenant_id,group_id,device_id,registration_id,added_at)"
                    + " VALUES(?,?,?,?,?)",
                tenant,
                groupId,
                target.deviceId(),
                target.registrationId(),
                now);
            audit.record(tenant, actor.getSubject(), "DEVICE_GROUP_MEMBER_ADDED",
                groupId + "/" + target.deviceId());
          }
          db.update(
              "UPDATE device_groups SET version=version+1,updated_at=? WHERE tenant_id=? AND id=?",
              now,
              tenant,
              groupId);
          return read(tenant, groupId, true);
        });
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<Member> members(String tenant, String actor, String id, int limit, String cursor) {
    canRead(tenant, actor);
    read(tenant, id, false);
    ItemPage.validate(limit, cursor);
    return ItemPage.from(
        db.query(
            "SELECT m.device_id,m.registration_id,m.added_at,d.display_name,d.platform,d.state,"
                + " d.registration_id current_registration_id,s.archived_at subject_archived_at"
                + " FROM device_group_members m JOIN devices d ON d.tenant_id=m.tenant_id"
                + " AND d.id=m.device_id JOIN subjects s ON s.tenant_id=d.tenant_id"
                + " AND s.id=d.subject_id WHERE m.tenant_id=? AND m.group_id=? AND m.device_id>?"
                + " ORDER BY m.device_id LIMIT ?",
            (r, n) -> new Member(
                r.getString("device_id"),
                r.getString("registration_id"),
                r.getString("display_name"),
                r.getString("platform"),
                r.getString("state"),
                r.getObject("subject_archived_at") != null ? "PROFILE_ARCHIVED"
                    : !r.getString("registration_id").equals(r.getString("current_registration_id"))
                        ? "STALE_REGISTRATION"
                        : !"ACTIVE".equals(r.getString("state")) ? "DEVICE_INACTIVE" : "CURRENT",
                r.getLong("added_at")),
            tenant,
            id,
            cursor == null ? "" : cursor,
            limit + 1),
        limit,
        Member::deviceId);
  }

  private Group read(String tenant, String id, boolean lock) {
    var rows = db.query(
        "SELECT g.*,(SELECT COUNT(*) FROM device_group_members m WHERE m.tenant_id=g.tenant_id"
            + " AND m.group_id=g.id) member_count FROM device_groups g"
            + " WHERE g.tenant_id=? AND g.id=?" + (lock ? " FOR UPDATE" : ""),
        (r, n) -> new Group(
            r.getString("id"),
            r.getString("name"),
            r.getObject("archived_at") == null ? "ACTIVE" : "ARCHIVED",
            r.getLong("version"),
            r.getInt("member_count"),
            r.getLong("created_at"),
            r.getLong("updated_at")),
        tenant,
        id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private void active(Group group) {
    if (!group.state().equals("ACTIVE")) {
      throw new DomainException(HttpStatus.CONFLICT, "DEVICE_GROUP_ARCHIVED");
    }
  }

  record Group(String id, String name, String state, long version, int deviceCount,
      long createdAt, long updatedAt) {}

  record Member(String deviceId, String registrationId, String displayName,
      String platform, String state, String membershipStatus, long addedAt) {}

  record DeviceTarget(String deviceId, String registrationId) {}
}

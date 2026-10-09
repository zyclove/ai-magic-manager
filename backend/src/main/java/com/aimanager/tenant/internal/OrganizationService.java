package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.*;
import com.aimanager.tenant.OrganizationScopeChanged;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.*;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class OrganizationService {
  private final JdbcTemplate db;
  private final TenantAccess access;
  private final MembershipMutex mutex;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final AuditService audit;
  private final Clock clock;
  private final ApplicationEventPublisher events;

  OrganizationService(
      JdbcTemplate db,
      TenantAccess access,
      MembershipMutex mutex,
      RecentAuthentication recent,
      IdempotencyService idempotency,
      AuditService audit,
      Clock clock,
      ApplicationEventPublisher events) {
    this.db = db;
    this.access = access;
    this.mutex = mutex;
    this.recent = recent;
    this.idempotency = idempotency;
    this.audit = audit;
    this.clock = clock;
    this.events = events;
  }

  private void organization(String tenant) {
    if (!"ORGANIZATION"
        .equals(db.queryForObject("SELECT kind FROM tenants WHERE id=?", String.class, tenant)))
      throw DomainException.invalid("ORGANIZATION_REQUIRED");
  }

  private TenantAccess.Grant visible(String tenant, String actor, String id) {
    var grant = access.requireRole(tenant, actor, OWNER, ORG_ADMIN, TEACHER);
    organization(tenant);
    if (grant.role() == TEACHER
        && db.queryForObject(
                "SELECT COUNT(*) FROM tenant_member_class_scopes s JOIN tenant_members m ON"
                    + " m.tenant_id=s.tenant_id AND m.actor_key=s.actor_key AND"
                    + " m.version=s.member_version JOIN organization_classes c ON"
                    + " c.tenant_id=s.tenant_id AND c.id=s.class_id WHERE s.tenant_id=? AND"
                    + " s.actor_key=? AND s.class_id=? AND m.role='TEACHER' AND m.revoked_at IS"
                    + " NULL AND c.archived_at IS NULL",
                Integer.class,
                tenant,
                ActorKeys.key(actor),
                id)
            == 0) throw DomainException.denied();
    return grant;
  }

  private List<String> prepare(String tenant, Jwt actor, List<String> classes) {
    mutex.lock(tenant);
    var teachers = new TreeSet<String>();
    for (String id : classes)
      teachers.addAll(
          db.queryForList(
              "SELECT m.actor_id FROM tenant_member_class_scopes s JOIN tenant_members m ON"
                  + " m.tenant_id=s.tenant_id AND m.actor_key=s.actor_key AND"
                  + " m.version=s.member_version WHERE s.tenant_id=? AND s.class_id=? AND"
                  + " m.role='TEACHER' AND m.revoked_at IS NULL",
              String.class,
              tenant,
              id));
    var actors = new ArrayList<>(teachers);
    actors.add(actor.getSubject());
    mutex.actors(tenant, actors);
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, ORG_ADMIN);
    organization(tenant);
    recent.require(actor);
    return List.copyOf(teachers);
  }

  @Transactional(timeout = 10)
  public Classroom create(String tenant, Jwt actor, String name, String key) {
    prepare(tenant, actor, List.of());
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "class.create",
        key,
        Map.of("name", name),
        Classroom.class,
        () -> {
          String id = UUID.randomUUID().toString();
          long now = clock.millis();
          db.update(
              "INSERT INTO organization_classes(tenant_id,id,name,created_at,updated_at)"
                  + " VALUES(?,?,?,?,?)",
              tenant,
              id,
              name.strip(),
              now,
              now);
          audit.record(tenant, actor.getSubject(), "CLASS_CREATED", id);
          return read(tenant, id, false);
        });
  }

  public ItemPage<Classroom> list(
      String tenant, String actor, int limit, String cursor, boolean archived) {
    var grant = access.requireRole(tenant, actor, OWNER, ORG_ADMIN, TEACHER);
    organization(tenant);
    ItemPage.validate(limit, cursor);
    if (archived && grant.role() == TEACHER) throw DomainException.denied();
    var args = new ArrayList<Object>(List.of(tenant, cursor == null ? "" : cursor));
    String scope = "";
    if (grant.role() == TEACHER) {
      scope =
          " AND EXISTS (SELECT 1 FROM tenant_member_class_scopes s JOIN tenant_members m ON"
              + " m.tenant_id=s.tenant_id AND m.actor_key=s.actor_key AND"
              + " m.version=s.member_version WHERE s.tenant_id=c.tenant_id AND s.class_id=c.id AND"
              + " s.actor_key=? AND m.revoked_at IS NULL AND m.role='TEACHER')";
      args.add(ActorKeys.key(actor));
    }
    args.add(limit + 1);
    var ids =
        db.queryForList(
            "SELECT c.id FROM organization_classes c WHERE c.tenant_id=? AND c.id>?"
                + (archived ? "" : " AND c.archived_at IS NULL")
                + scope
                + " ORDER BY c.id LIMIT ?",
            String.class,
            args.toArray());
    var page = ItemPage.from(ids, limit, id -> id);
    return new ItemPage<>(
        page.items().stream().map(id -> read(tenant, id, false)).toList(), page.nextCursor());
  }

  public Classroom get(String tenant, String actor, String id) {
    visible(tenant, actor, id);
    return read(tenant, id, false);
  }

  private Classroom read(String tenant, String id, boolean lock) {
    var rows =
        db.query(
            "SELECT c.*,(SELECT COUNT(*) FROM organization_class_students s WHERE"
                + " s.tenant_id=c.tenant_id AND s.class_id=c.id) student_count FROM"
                + " organization_classes c WHERE c.tenant_id=? AND c.id=?"
                + (lock ? " FOR UPDATE" : ""),
            (r, n) ->
                new Classroom(
                    r.getString("id"),
                    r.getString("name"),
                    r.getObject("archived_at") == null ? "ACTIVE" : "ARCHIVED",
                    r.getLong("version"),
                    r.getInt("student_count"),
                    r.getLong("created_at"),
                    r.getLong("updated_at")),
            tenant,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private void active(Classroom c) {
    if (!c.state().equals("ACTIVE"))
      throw new DomainException(HttpStatus.CONFLICT, "CLASS_ARCHIVED");
  }

  private void bump(String tenant, String id) {
    db.update(
        "UPDATE organization_classes SET version=version+1,updated_at=? WHERE tenant_id=? AND id=?",
        clock.millis(),
        tenant,
        id);
  }

  private void subject(String tenant, String id, boolean active) {
    if (db.queryForList(
            "SELECT id FROM subjects WHERE tenant_id=? AND id=?"
                + (active ? " AND archived_at IS NULL" : "")
                + " FOR UPDATE",
            tenant,
            id)
        .isEmpty()) throw DomainException.denied();
  }

  private boolean enrolled(String tenant, String id, String subject) {
    return db.queryForObject(
            "SELECT COUNT(*) FROM organization_class_students WHERE tenant_id=? AND class_id=? AND"
                + " subject_id=?",
            Integer.class,
            tenant,
            id,
            subject)
        > 0;
  }

  private void changed(String tenant, List<String> actors, List<String> subjects) {
    if (!actors.isEmpty() && !subjects.isEmpty())
      events.publishEvent(
          new OrganizationScopeChanged(
              tenant, actors.stream().map(ActorKeys::key).toList(), subjects, clock.millis()));
  }

  @Transactional(timeout = 10)
  public Classroom rename(
      String tenant, Jwt actor, String id, String name, String etag, String key) {
    prepare(tenant, actor, List.of(id));
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "class.rename",
        key,
        Map.of("id", id, "name", name, "version", expected),
        Classroom.class,
        () -> {
          var current = read(tenant, id, true);
          ResourceVersions.check(expected, current.version());
          active(current);
          if (current.name().equals(name.strip())) return current;
          db.update(
              "UPDATE organization_classes SET name=?,version=version+1,updated_at=? WHERE"
                  + " tenant_id=? AND id=?",
              name.strip(),
              clock.millis(),
              tenant,
              id);
          audit.record(tenant, actor.getSubject(), "CLASS_UPDATED", id);
          return read(tenant, id, true);
        });
  }

  @Transactional(timeout = 10)
  public Classroom student(
      String tenant, Jwt actor, String id, String student, boolean add, String etag, String key) {
    var teachers = prepare(tenant, actor, List.of(id));
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        add ? "class.student.add" : "class.student.remove",
        key,
        Map.of("id", id, "subject", student, "version", expected),
        Classroom.class,
        () -> {
          var current = read(tenant, id, true);
          ResourceVersions.check(expected, current.version());
          active(current);
          subject(tenant, student, add);
          boolean enrolled = enrolled(tenant, id, student);
          if (enrolled == add) return current;
          if (add) {
            if (current.studentCount() >= 500)
              throw new DomainException(HttpStatus.CONFLICT, "CLASS_CAPACITY_REACHED");
            db.update(
                "INSERT INTO organization_class_students(tenant_id,class_id,subject_id,added_at)"
                    + " VALUES(?,?,?,?)",
                tenant,
                id,
                student,
                clock.millis());
          } else
            db.update(
                "DELETE FROM organization_class_students WHERE tenant_id=? AND class_id=? AND"
                    + " subject_id=?",
                tenant,
                id,
                student);
          bump(tenant, id);
          if (!add) changed(tenant, teachers, List.of(student));
          audit.record(
              tenant,
              actor.getSubject(),
              add ? "CLASS_STUDENT_ADDED" : "CLASS_STUDENT_REMOVED",
              id);
          return read(tenant, id, true);
        });
  }

  public ItemPage<Student> students(
      String tenant, String actor, String id, int limit, String cursor) {
    var grant = visible(tenant, actor, id);
    read(tenant, id, false);
    ItemPage.validate(limit, cursor);
    return ItemPage.from(
        db.query(
            "SELECT s.id,s.nickname,s.age_band,s.archived_at,r.added_at FROM"
                + " organization_class_students r JOIN subjects s ON s.tenant_id=r.tenant_id AND"
                + " s.id=r.subject_id WHERE r.tenant_id=? AND r.class_id=? AND s.id>?"
                + (grant.role() == TEACHER ? " AND s.archived_at IS NULL" : "")
                + " ORDER BY s.id LIMIT ?",
            (r, n) ->
                new Student(
                    r.getString("id"),
                    r.getString("nickname"),
                    r.getString("age_band"),
                    r.getObject("archived_at") != null,
                    r.getLong("added_at")),
            tenant,
            id,
            cursor == null ? "" : cursor,
            limit + 1),
        limit,
        Student::id);
  }

  @Transactional(timeout = 10)
  public Classroom archive(String tenant, Jwt actor, String id, String etag, String key) {
    var teachers = prepare(tenant, actor, List.of(id));
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "class.archive",
        key,
        Map.of("id", id, "version", expected),
        Classroom.class,
        () -> {
          var current = read(tenant, id, true);
          ResourceVersions.check(expected, current.version());
          if (current.state().equals("ARCHIVED")) return current;
          db.update(
              "UPDATE organization_classes SET archived_at=?,version=version+1,updated_at=? WHERE"
                  + " tenant_id=? AND id=?",
              clock.millis(),
              clock.millis(),
              tenant,
              id);
          changed(
              tenant,
              teachers,
              db.queryForList(
                  "SELECT subject_id FROM organization_class_students WHERE tenant_id=? AND"
                      + " class_id=? ORDER BY subject_id",
                  String.class,
                  tenant,
                  id));
          audit.record(tenant, actor.getSubject(), "CLASS_ARCHIVED", id);
          return read(tenant, id, true);
        });
  }

  @Transactional(timeout = 10)
  public Transfer transfer(
      String tenant,
      Jwt actor,
      String source,
      String student,
      String target,
      long targetVersion,
      String etag,
      String key) {
    if (source.equals(target)) throw DomainException.invalid("CLASS_TRANSFER_SAME_TARGET");
    var teachers = prepare(tenant, actor, List.of(source, target));
    long expected = ResourceVersions.require(etag);
    return idempotency.execute(
        tenant,
        actor.getSubject(),
        "class.student.transfer",
        key,
        Map.of(
            "source",
            source,
            "target",
            target,
            "subject",
            student,
            "sourceVersion",
            expected,
            "targetVersion",
            targetVersion),
        Transfer.class,
        () -> {
          var locked = new HashMap<String, Classroom>();
          for (String id : new TreeSet<>(List.of(source, target)))
            locked.put(id, read(tenant, id, true));
          var from = locked.get(source);
          var to = locked.get(target);
          ResourceVersions.check(expected, from.version());
          ResourceVersions.check(targetVersion, to.version());
          active(from);
          active(to);
          subject(tenant, student, true);
          if (!enrolled(tenant, source, student))
            throw new DomainException(HttpStatus.CONFLICT, "CLASS_STUDENT_NOT_ENROLLED");
          if (!enrolled(tenant, target, student)) {
            if (to.studentCount() >= 500)
              throw new DomainException(HttpStatus.CONFLICT, "CLASS_CAPACITY_REACHED");
            db.update(
                "INSERT INTO organization_class_students(tenant_id,class_id,subject_id,added_at)"
                    + " VALUES(?,?,?,?)",
                tenant,
                target,
                student,
                clock.millis());
            bump(tenant, target);
          }
          db.update(
              "DELETE FROM organization_class_students WHERE tenant_id=? AND class_id=? AND"
                  + " subject_id=?",
              tenant,
              source,
              student);
          bump(tenant, source);
          changed(tenant, teachers, List.of(student));
          audit.record(tenant, actor.getSubject(), "CLASS_STUDENT_TRANSFERRED", source);
          return new Transfer(read(tenant, source, true), read(tenant, target, true));
        });
  }

  record Classroom(
      String id,
      String name,
      String state,
      long version,
      int studentCount,
      long createdAt,
      long updatedAt) {}

  record Student(String id, String nickname, String ageBand, boolean archived, long addedAt) {}

  record Transfer(Classroom source, Classroom target) {}
}

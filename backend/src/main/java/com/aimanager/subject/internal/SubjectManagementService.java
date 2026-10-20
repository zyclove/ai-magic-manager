package com.aimanager.subject.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.IdempotencyLookupOutcome;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.subject.Subject;
import com.aimanager.tenant.TenantAccess;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** 成人档案管理适配层：复用领域变更，统一提供原操作查询，不自动重放。 */
@Service
class SubjectManagementService {
  private static final long MAX_VERSION = 9007199254740991L;
  private final SubjectService subjects;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final IdempotencyService journal;
  private final JdbcTemplate db;

  SubjectManagementService(SubjectService subjects, TenantAccess access,
      RecentAuthentication recent, IdempotencyService journal, JdbcTemplate db) {
    this.subjects = subjects;
    this.access = access;
    this.recent = recent;
    this.journal = journal;
    this.db = db;
  }

  enum Operation { CREATE, UPDATE, ARCHIVE }
  record Change(Operation operation, String subjectId, Long version,
      String nickname, Subject.AgeBand ageBand) {}
  record Snapshot(String id, String nickname, Subject.AgeBand ageBand, long version, String state) {}
  record Result(Operation operation, Snapshot committed, Snapshot current) {}

  /** 归档档案仅向当前成人管理员展示；不会恢复访问、设备凭据或已删除数据。 */
  @Transactional(timeout = 10)
  public ItemPage<Snapshot> list(String tenant, String actor, int limit, String cursor, boolean archived) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    ItemPage.validate(limit, cursor);
    return ItemPage.from(db.query("SELECT id,nickname,age_band,version,archived_at FROM subjects"
        + " WHERE tenant_id=? AND id>?" + (archived ? "" : " AND archived_at IS NULL")
        + " ORDER BY id LIMIT ?", (r, n) -> new Snapshot(r.getString("id"), r.getString("nickname"),
            Subject.AgeBand.valueOf(r.getString("age_band")), r.getLong("version"),
            r.getObject("archived_at") == null ? "ACTIVE" : "ARCHIVED"),
        tenant, cursor == null ? "" : cursor, limit + 1), limit, Snapshot::id);
  }

  @Transactional(timeout = 10)
  public Snapshot get(String tenant, String actor, String id) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    canonical(id);
    return read(tenant, id);
  }

  @Transactional(timeout = 10)
  public Snapshot change(String tenant, Jwt actor, Change input, String key) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    canonical(key);
    var attributes = attributes(input);
    return journal.execute(tenant, actor.getSubject(), "subject.manage", key, attributes,
        Snapshot.class, () -> {
          String id = input.subjectId();
          switch (input.operation()) {
            case CREATE -> id = subjects.create(tenant, actor.getSubject(), input.nickname(), input.ageBand(), null).id();
            case UPDATE -> subjects.update(tenant, actor.getSubject(), id, input.nickname(), input.ageBand(), ResourceVersions.tag(input.version()));
            case ARCHIVE -> subjects.archive(tenant, actor, id, ResourceVersions.tag(input.version()));
          }
          return read(tenant, id);
        }, committed -> ResponseOwnership.subjects(tenant, List.of(committed.id())));
  }

  /** 查询过期的原结果也不会延长幂等键；ERASED 由共享日志拒绝为 410。 */
  @Transactional(timeout = 10)
  public IdempotencyLookupOutcome<Result> query(String tenant, String actor, String key, Change input) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    canonical(key);
    return journal.findCommitted(tenant, actor, "subject.manage", key, attributes(input), Snapshot.class)
        .requirePresent(() -> new DomainException(HttpStatus.NOT_FOUND, "SUBJECT_RESULT_UNAVAILABLE"))
      .map(committed -> {
      return new Result(input.operation(), committed, read(tenant, committed.id()));
      });
  }

  private Snapshot read(String tenant, String id) {
    var rows = db.query("SELECT id,nickname,age_band,version,archived_at FROM subjects"
        + " WHERE tenant_id=? AND id=? FOR UPDATE", (r, n) -> new Snapshot(r.getString("id"),
            r.getString("nickname"), Subject.AgeBand.valueOf(r.getString("age_band")),
            r.getLong("version"), r.getObject("archived_at") == null ? "ACTIVE" : "ARCHIVED"), tenant, id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private Map<String, Object> attributes(Change input) {
    if (input == null || input.operation() == null) throw DomainException.invalid("INVALID_SUBJECT_CHANGE");
    var result = new LinkedHashMap<String, Object>();
    result.put("operation", input.operation());
    if (input.operation() == Operation.CREATE) {
      if (input.subjectId() != null || input.version() != null) throw DomainException.invalid("INVALID_SUBJECT_CHANGE");
    } else {
      canonical(input.subjectId());
      if (input.version() == null || input.version() < 0 || input.version() >= MAX_VERSION)
        throw DomainException.invalid("INVALID_SUBJECT_CHANGE");
      result.put("subjectId", input.subjectId());
      result.put("version", input.version());
    }
    if (input.operation() == Operation.ARCHIVE) {
      if (input.nickname() != null || input.ageBand() != null) throw DomainException.invalid("INVALID_SUBJECT_CHANGE");
    } else {
      if (input.nickname() == null || input.nickname().isBlank() || input.nickname().length() > 60
          || !input.nickname().equals(input.nickname().strip()) || input.ageBand() == null
          || input.nickname().codePoints().anyMatch(c -> Character.isISOControl(c) || Character.getType(c) == Character.FORMAT))
        throw DomainException.invalid("INVALID_SUBJECT_CHANGE");
      result.put("nickname", input.nickname());
      result.put("ageBand", input.ageBand());
    }
    return result;
  }

  private void canonical(String value) {
    try {
      if (value != null && UUID.fromString(value).toString().equals(value)) return;
    } catch (IllegalArgumentException ignored) { /* 统一返回输入错误，避免 SQL 排序规则产生别名。 */ }
    throw DomainException.invalid("INVALID_SUBJECT_CHANGE");
  }
}

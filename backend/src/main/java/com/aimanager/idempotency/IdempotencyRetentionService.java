package com.aimanager.idempotency;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

/** 完整响应的有界到期维护；不删除父键、不重新分类主体归属、不代替主体擦除。 */
@Service
public class IdempotencyRetentionService {
  private static final int MAX_BATCH_SIZE = 500;
  private static final String MATCH =
      "scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?";
  private static final Comparator<Candidate> LOCK_ORDER = Comparator
      .comparing(Candidate::scope).thenComparing(Candidate::actor)
      .thenComparing(Candidate::operation).thenComparing(Candidate::key);

  private final JdbcTemplate jdbc;
  private final IdempotencyService journal;
  private final IdempotencyRetentionSettings settings;
  private final IdempotencyResultTime resultTime;

  public IdempotencyRetentionService(JdbcTemplate jdbc, IdempotencyService journal,
      IdempotencyRetentionSettings settings, IdempotencyResultTime resultTime) {
    this.jdbc = jdbc;
    this.journal = journal;
    this.settings = settings;
    this.resultTime = resultTime;
  }

  /** 仅包含聚合计数，不携带身份、原键、请求或响应副本。 */
  public record BatchResult(int inspected, int redacted, boolean enabled) {}

  private record Candidate(String id, String scope, String actor, String operation, String key) {
    Object[] arguments() {
      return new Object[] {scope, actor, operation, key};
    }
  }

  /**
   * 由已有 WorkPermit 覆盖的同步维护入口调用；每批只有一个短事务。
   *
   * <p>先有界发现再按相同复合键顺序锁父行，随后由通用服务按固定顺序锁归属。
   * 不使用 Redis 锁，不在锁内重新创建或触发原业务。
   */
  @Transactional(timeout = 10, isolation = Isolation.READ_COMMITTED)
  public BatchResult redactDue(int limit) {
    if (limit < 1 || limit > MAX_BATCH_SIZE) {
      throw new IllegalArgumentException("Invalid idempotency maintenance batch");
    }
    if (!settings.maintenance().enabled()) {
      return new BatchResult(0, 0, false);
    }
    long discoveryTime = resultTime.now();
    var discovered = jdbc.query(
        "SELECT id,scope_id,actor_key,operation_key,key_hash FROM idempotency_requests"
            + " WHERE result_storage_state='RETAINED' AND response_state<>'ERASED'"
            + " AND result_committed_at IS NOT NULL"
            + " AND (result_expires_at<=? OR result_expired_at IS NOT NULL)"
            + " ORDER BY result_expires_at,id LIMIT ?",
        (row, index) -> new Candidate(row.getString(1), row.getString(2), row.getString(3),
            row.getString(4), row.getString(5)), discoveryTime, limit);
    var ordered = new ArrayList<>(discovered);
    ordered.sort(LOCK_ORDER);
    int inspected = 0;
    int redacted = 0;
    for (var candidate : ordered) {
      validate(candidate);
      var rows = jdbc.queryForList(
          "SELECT id,actor_id,operation,request_hash,response_state,"
              + "CASE WHEN response_body IS NULL THEN 1 ELSE 0 END AS body_absent,"
              + IdempotencyResultLifecycle.COLUMNS
              + " FROM idempotency_requests WHERE " + MATCH + " FOR UPDATE",
          candidate.arguments());
      if (rows.size() != 1 || !candidate.id().equals(rows.get(0).get("id"))) {
        throw new IllegalStateException("Maintenance journal reference changed");
      }
      Map<String, Object> row = rows.get(0);
      var lifecycle = IdempotencyResultLifecycle.fromRow(row);
      String classification = String.valueOf(row.get("response_state"));
      boolean bodyAbsent = ((Number) row.get("body_absent")).intValue() == 1;
      lifecycle.requireConsistent(classification, bodyAbsent);
      if (lifecycle.awaitingResult() || !hex(row.get("request_hash"))) {
        throw new IllegalStateException("Maintenance journal result is invalid");
      }
      journal.validateCommittedOwnership(candidate.scope(), candidate.actor(),
          candidate.operation(), candidate.key(), row, lifecycle);
      inspected++;
      if ("ERASED".equals(classification)
          || lifecycle.storageState() == IdempotencyResultStorageState.REDACTED) {
        continue;
      }
      long now = resultTime.now(lifecycle);
      if (!lifecycle.expired(now)) {
        continue;
      }
      int changed = jdbc.update(
          "UPDATE idempotency_requests SET response_body=NULL,actor_id='',operation='',"
              + "result_expired_at=result_expires_at,result_storage_state='REDACTED',"
              + "result_redacted_at=?,result_last_observed_at=? WHERE " + MATCH
              + " AND id=? AND result_storage_state='RETAINED' AND response_state<>'ERASED'"
              + " AND result_committed_at=? AND result_expires_at=? AND result_policy_revision=?",
          now, now, candidate.scope(), candidate.actor(), candidate.operation(), candidate.key(),
          candidate.id(), lifecycle.committedAt(), lifecycle.expiresAt(), lifecycle.policyRevision());
      if (changed != 1) {
        throw new IllegalStateException("Maintenance result could not be committed");
      }
      redacted++;
    }
    return new BatchResult(inspected, redacted, true);
  }

  private static void validate(Candidate candidate) {
    if (!uuid(candidate.id()) || candidate.scope() == null || candidate.scope().isBlank()
        || candidate.scope().length() > 100 || !hex(candidate.actor())
        || !hex(candidate.operation()) || !hex(candidate.key())) {
      throw new IllegalStateException("Maintenance journal key is invalid");
    }
  }

  private static boolean hex(Object value) {
    return value instanceof String digest && digest.matches("[0-9a-f]{64}");
  }

  private static boolean uuid(String value) {
    try {
      return value != null && UUID.fromString(value).toString().equals(value);
    } catch (IllegalArgumentException invalid) {
      return false;
    }
  }
}

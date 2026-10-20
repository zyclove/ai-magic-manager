package com.aimanager.idempotency;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.util.HexFormat;
import java.util.Map;
import java.util.function.Supplier;
import java.util.function.Function;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Database uniqueness serializes retries across replicas; mutation, response and audit share one
 * transaction.
 */
@Service
public class IdempotencyService {
  private static final long REPLAY_SECONDS = 86_400L;
  private static final String ZERO_HASH = "0".repeat(64);
  private static final String READ_COLUMNS =
      "actor_id,operation,request_hash,response_body,response_state,expires_at,"
          + IdempotencyResultLifecycle.COLUMNS;
  private final JdbcTemplate jdbc;
  private final ObjectMapper mapper;
  private final Clock clock;
  private final IdempotencyRetentionSettings retention;
  private final IdempotencyResultTime resultTime;

  /** 显式程序化构造沿用首版 90 天策略，运行环境通过配置绑定构造器注入。 */
  public IdempotencyService(JdbcTemplate jdbc, ObjectMapper mapper, Clock clock) {
    this(jdbc, mapper, clock, IdempotencyRetentionSettings.defaults(),
        new IdempotencyResultTime(jdbc, clock, IdempotencyRetentionSettings.defaults()));
  }

  @Autowired
  public IdempotencyService(JdbcTemplate jdbc, ObjectMapper mapper, Clock clock,
      IdempotencyRetentionSettings retention, IdempotencyResultTime resultTime) {
    this.jdbc = jdbc;
    this.mapper = mapper;
    this.clock = clock;
    this.retention = java.util.Objects.requireNonNull(retention, "Retention policy is required");
    this.resultTime = java.util.Objects.requireNonNull(resultTime, "Result time is required");
  }

  /**
   * Authorize BEFORE calling, including cached responses. Never journal credentials or invite
   * secrets.
   */
  @Transactional(timeout = 10)
  public <T> T execute(
      String scopeId, String actorId, String operation, String key,
      Map<String, ?> requestAttributes, Class<T> responseType, Supplier<T> mutation) {
    return execute(scopeId, actorId, operation, key, requestAttributes, responseType,
        mutation, ignored -> ResponseOwnership.unclassified());
  }

  /** Ownership comes from the same locked business mutation, never from a later resource lookup. */
  @Transactional(timeout = 10)
  public <T> T execute(
      String scopeId, String actorId, String operation, String key,
      Map<String, ?> requestAttributes, Class<T> responseType,
      Supplier<T> mutation, Function<T, ResponseOwnership> ownership) {
    if (key == null) return mutation.get();
    validateKey(key);
    if (ownership == null) throw new IllegalArgumentException("Response ownership required");
    String keyHash = hash(key.getBytes(StandardCharsets.UTF_8));
    String actorKey = ActorKeys.key(actorId);
    String operationKey = hash(operation.getBytes(StandardCharsets.UTF_8));
    try {
      jdbc.update(
          "INSERT INTO idempotency_requests(id,scope_id,actor_id,actor_key,operation,operation_key,"
              + "key_hash,request_hash,expires_at) VALUES(?,?,?,?,?,?,?,?,?)",
          java.util.UUID.randomUUID().toString(), scopeId, actorId, actorKey, operation,
          operationKey, keyHash, ZERO_HASH,
          clock.instant().plusSeconds(REPLAY_SECONDS).toEpochMilli());
    } catch (DuplicateKeyException duplicate) {
      var previous = jdbc.queryForMap(
          "SELECT " + READ_COLUMNS + " FROM"
              + " idempotency_requests WHERE scope_id=? AND actor_key=? AND operation_key=?"
              + " AND key_hash=? FOR UPDATE", scopeId, actorKey, operationKey, keyHash);
      // Erased keys are permanent refusal markers, including after expiry or a changed body.
      requireNotErased(previous);
      if (!fingerprint(requestAttributes).equals(previous.get("request_hash")))
        throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_CONFLICT");
      var lifecycle = IdempotencyResultLifecycle.fromRow(previous);
      lifecycle.requireConsistent(String.valueOf(previous.get("response_state")),
          previous.get("response_body") == null);
      long now = clock.millis();
      if (lifecycle.expiredAt() != null
          || lifecycle.storageState() == IdempotencyResultStorageState.REDACTED
          || ((Number) previous.get("expires_at")).longValue() <= now)
        throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_EXPIRED");
      if (previous.get("response_body") == null)
        throw new DomainException(HttpStatus.CONFLICT, "REQUEST_IN_PROGRESS");
      validateCommittedOwnership(scopeId, actorKey, operationKey, keyHash, previous, lifecycle);
      long observed = resultTime.now(lifecycle);
      if (lifecycle.expired(observed))
        throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_EXPIRED");
      recordObservation(scopeId, actorKey, operationKey, keyHash, lifecycle, observed);
      return decode(previous.get("response_body").toString(), responseType);
    }
    // Defer fingerprinting until after duplicate-state inspection so even malformed new
    // request attributes cannot turn an erased key into a recovery or mutation attempt.
    String requestHash = fingerprint(requestAttributes);
    T response = mutation.get();
    ResponseOwnership owners = ownership.apply(response);
    if (owners == null) throw new IllegalArgumentException("Response ownership required");
    if (owners.kind() == ResponseOwnership.Kind.SCOPED && !scopeId.equals(owners.tenantId()))
      throw new IllegalArgumentException("Cached response ownership is outside its tenant");
    for (String subject : owners.subjectIds()) {
      if (jdbc.update(
          "INSERT INTO idempotency_subject_owners(id,scope_id,actor_key,operation_key,key_hash,"
              + "tenant_id,subject_key) VALUES(?,?,?,?,?,?,?)", java.util.UUID.randomUUID().toString(), scopeId, actorKey, operationKey,
          keyHash, owners.tenantId(), ResponseOwnership.subjectKey(owners.tenantId(), subject)) != 1)
        throw new IllegalStateException("Cached response ownership could not be committed");
    }
    final String body;
    try {
      body = mapper.writeValueAsString(response);
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Journal response serialization failed");
    }
    // 成功业务结果已生成并完成序列化，才记录提交业务时间；不复用首次请求/预览时间。
    long resultCommittedAt = resultTime.now();
    long resultExpiresAt = IdempotencyResultLifecycle.expirationAt(resultCommittedAt);
    if (jdbc.update(
        "UPDATE idempotency_requests SET response_body=?,response_state=?,request_hash=?,"
            + "result_committed_at=?,result_expires_at=?,result_policy_revision=?,result_last_observed_at=?"
            + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?"
            + " AND response_state='UNCLASSIFIED' AND response_body IS NULL"
            + " AND result_storage_state='RETAINED' AND result_committed_at IS NULL"
            + " AND result_expires_at IS NULL AND result_policy_revision IS NULL"
            + " AND result_last_observed_at IS NULL"
            + " AND result_expired_at IS NULL AND result_redacted_at IS NULL",
        body, owners.kind().name(), requestHash, resultCommittedAt, resultExpiresAt,
        retention.policyVersion(), resultCommittedAt, scopeId, actorKey, operationKey, keyHash) != 1)
      throw new IllegalStateException("Journal response could not be committed");
    return response;
  }

  /**
   * 在当前授权事务内查询原结果。24 小时重放期限不妨碍 90 天窗口内的恢复。
   *
   * <p>到期时仅提交不可逆标记并返回类型化结果，由最外层事务之外的 HTTP 适配层转为 410。
   * 缺失不能证明从未提交；本方法不创建原业务、不续期、不清空或释放防重键。
   */
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public <T> IdempotencyLookupOutcome<T> findCommitted(
      String scopeId,
      String actorId,
      String operation,
      String key,
      Map<String, ?> requestAttributes,
      Class<T> responseType) {
    validateKey(key);
    String actorKey = ActorKeys.key(actorId);
    String operationKey = hash(operation.getBytes(StandardCharsets.UTF_8));
    String keyHash = hash(key.getBytes(StandardCharsets.UTF_8));
    var rows = jdbc.queryForList(
        "SELECT " + READ_COLUMNS + " FROM idempotency_requests"
            + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=? FOR UPDATE",
        scopeId, actorKey, operationKey, keyHash);
    if (rows.isEmpty()) return IdempotencyLookupOutcome.missing();
    var row = rows.get(0);
    requireNotErased(row);
    if (!fingerprint(requestAttributes).equals(row.get("request_hash")))
      throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_CONFLICT");
    var lifecycle = IdempotencyResultLifecycle.fromRow(row);
    lifecycle.requireConsistent(String.valueOf(row.get("response_state")),
        row.get("response_body") == null);
    if (lifecycle.awaitingResult())
      throw new DomainException(HttpStatus.CONFLICT, "REQUEST_IN_PROGRESS");
    validateCommittedOwnership(scopeId, actorKey, operationKey, keyHash, row, lifecycle);
    if (lifecycle.expiredAt() != null
        || lifecycle.storageState() == IdempotencyResultStorageState.REDACTED) {
      return IdempotencyLookupOutcome.expired();
    }
    long now = resultTime.now(lifecycle);
    if (lifecycle.expired(now)) {
      if (lifecycle.expiredAt() == null) {
        if (jdbc.update(
            "UPDATE idempotency_requests SET result_expired_at=result_expires_at,result_last_observed_at=?"
                + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?"
                + " AND result_expired_at IS NULL AND response_state<>'ERASED'",
            now, scopeId, actorKey, operationKey, keyHash) != 1) {
          throw new IllegalStateException("Journal expiry could not be committed");
        }
      }
      // 不能在此抛 DomainException；否则调用者事务会回滚刚写入的到期事实。
      return IdempotencyLookupOutcome.expired();
    }
    recordObservation(scopeId, actorKey, operationKey, keyHash, lifecycle, now);
    T reference = decode(row.get("response_body").toString(), responseType);
    if (reference == null) throw new IllegalStateException("Committed resource reference is missing");
    return IdempotencyLookupOutcome.found(reference);
  }

  private void requireNotErased(Map<String, Object> row) {
    String state = String.valueOf(row.get("response_state"));
    if (state.equals("ERASED"))
      throw new DomainException(HttpStatus.GONE, "IDEMPOTENCY_RESPONSE_ERASED");
    if (!java.util.Set.of("UNCLASSIFIED", "NON_SUBJECT", "SCOPED").contains(state))
      throw new IllegalStateException("Journal response classification is invalid");
  }

  void validateCommittedOwnership(String scope, String actorKey, String operationKey,
      String keyHash, Map<String, Object> row, IdempotencyResultLifecycle lifecycle) {
    if (lifecycle.storageState() == IdempotencyResultStorageState.REDACTED) {
      if (!"".equals(row.get("actor_id")) || !"".equals(row.get("operation"))) {
        throw new IllegalStateException("Redacted journal identity is invalid");
      }
    } else if (!(row.get("actor_id") instanceof String actor)
        || !(row.get("operation") instanceof String operation)
        || actor.isBlank() || operation.isBlank() || !ActorKeys.key(actor).equals(actorKey)
        || !hash(operation.getBytes(StandardCharsets.UTF_8)).equals(operationKey)) {
      throw new IllegalStateException("Journal identity is invalid");
    }
    var owners = jdbc.queryForList(
        "SELECT tenant_id,subject_key FROM idempotency_subject_owners WHERE scope_id=?"
            + " AND actor_key=? AND operation_key=? AND key_hash=? ORDER BY tenant_id,subject_key"
            + " LIMIT ? FOR UPDATE", scope, actorKey, operationKey, keyHash,
        ResponseOwnership.MAX_SUBJECTS + 1);
    if (java.util.Set.of("SCOPED", "ERASED").contains(String.valueOf(row.get("response_state")))) {
      if (owners.isEmpty() || owners.size() > ResponseOwnership.MAX_SUBJECTS)
        throw new IllegalStateException("Journal response ownership is invalid");
      for (var owner : owners) {
        if (!scope.equals(owner.get("tenant_id")) || !canonicalUuid(scope)
            || !(owner.get("subject_key") instanceof String digest)
            || !digest.matches("[0-9a-f]{64}"))
          throw new IllegalStateException("Journal response ownership is invalid");
      }
    } else if (!owners.isEmpty()) {
      throw new IllegalStateException("Journal response ownership is invalid");
    }
  }

  /** 父行已锁定；可信观察与业务读取共用事务，不能绕过外层回滚或推进固定期限。 */
  private void recordObservation(String scope, String actor, String operation, String key,
      IdempotencyResultLifecycle lifecycle, long observed) {
    if (observed == lifecycle.lastObservedAt()) return;
    if (jdbc.update(
        "UPDATE idempotency_requests SET result_last_observed_at=?"
            + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?"
            + " AND result_last_observed_at=? AND response_state<>'ERASED'",
        observed, scope, actor, operation, key, lifecycle.lastObservedAt()) != 1) {
      throw new IllegalStateException("Journal time observation could not be committed");
    }
  }

  private boolean canonicalUuid(String value) {
    try { return java.util.UUID.fromString(value).toString().equals(value); }
    catch (IllegalArgumentException malformed) { return false; }
  }

  private <T> T decode(String body, Class<T> responseType) {
    try { return mapper.readValue(body, responseType); }
    catch (JsonProcessingException failure) {
      // Jackson exceptions may echo private response content; do not attach their cause.
      throw new IllegalStateException("Journal response could not be read");
    }
  }

  private void validateKey(String key) {
    if (key == null || key.isBlank() || key.length() > 128)
      throw DomainException.invalid("INVALID_IDEMPOTENCY_KEY");
  }

  private String fingerprint(Map<String, ?> attributes) {
    try {
      return hash(
          mapper
              .writer()
              .with(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS)
              .writeValueAsBytes(attributes));
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Request fingerprint serialization failed");
    }
  }

  private String hash(byte[] bytes) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    } catch (NoSuchAlgorithmException failure) {
      throw new IllegalStateException("SHA-256 unavailable", failure);
    }
  }
}

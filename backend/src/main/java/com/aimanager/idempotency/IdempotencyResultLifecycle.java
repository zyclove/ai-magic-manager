package com.aimanager.idempotency;

import java.time.Duration;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

/**
 * 已提交结果的不可变期限与持久终态校验，供查询、物理维护和主体擦除共用。
 *
 * <p>字段缺失、状态混淆或损坏不得回退为无限期恢复，也不能释放原请求的防重键。
 */
public record IdempotencyResultLifecycle(
    IdempotencyResultStorageState storageState,
    Long committedAt,
    Long expiresAt,
    Long policyRevision,
    Long lastObservedAt,
    Long expiredAt,
    Long redactedAt) {
  public static final String COLUMNS =
      "result_storage_state,result_committed_at,result_expires_at,result_policy_revision,"
          + "result_last_observed_at,result_expired_at,result_redacted_at";
  private static final long RETENTION_MILLIS =
      Duration.ofDays(IdempotencyRetentionSettings.RESULT_RETENTION_DAYS).toMillis();
  private static final Set<String> CLASSIFICATIONS =
      Set.of("UNCLASSIFIED", "NON_SUBJECT", "SCOPED", "ERASED");

  public IdempotencyResultLifecycle {
    Objects.requireNonNull(storageState, "Result storage state is required");
    boolean awaiting = committedAt == null && expiresAt == null && policyRevision == null
        && lastObservedAt == null
        && expiredAt == null && redactedAt == null;
    if (awaiting) {
      if (storageState != IdempotencyResultStorageState.RETAINED) {
        throw invalid();
      }
    } else {
      if (committedAt == null || committedAt < 0 || expiresAt == null
          || policyRevision == null || policyRevision < 1
          || lastObservedAt == null || lastObservedAt < committedAt) {
        throw invalid();
      }
      if (expiresAt.longValue() != expirationAt(committedAt)
          || (expiredAt != null && expiredAt.longValue() != expiresAt.longValue())) {
        throw invalid();
      }
      if (storageState == IdempotencyResultStorageState.RETAINED && redactedAt != null) {
        throw invalid();
      }
      if (storageState == IdempotencyResultStorageState.REDACTED
          && (redactedAt == null || redactedAt < 0)) {
        throw invalid();
      }
    }
  }

  /** JDBC 行必须包含明确的物理状态；不接受缺列或未知枚举。 */
  public static IdempotencyResultLifecycle fromRow(Map<String, Object> row) {
    if (!(row.get("result_storage_state") instanceof String raw)) {
      throw invalid();
    }
    final IdempotencyResultStorageState storage;
    try {
      storage = IdempotencyResultStorageState.valueOf(raw);
    } catch (IllegalArgumentException unknown) {
      throw invalid();
    }
    return new IdempotencyResultLifecycle(storage, number(row, "result_committed_at"),
        number(row, "result_expires_at"), number(row, "result_policy_revision"),
        number(row, "result_last_observed_at"),
        number(row, "result_expired_at"), number(row, "result_redacted_at"));
  }

  /** 只读取固定的生命周期列，供不加载完整个人响应的维护扫描使用。 */
  public static IdempotencyResultLifecycle fromResultSet(ResultSet row) throws SQLException {
    Map<String, Object> values = new HashMap<>();
    for (String name : COLUMNS.split(",")) {
      values.put(name, row.getObject(name));
    }
    return fromRow(values);
  }

  /** 只允许同事务内尚未产生成功结果的初始占位缺少提交元数据。 */
  public boolean awaitingResult() {
    return committedAt == null;
  }

  /** 持久到期/清理事实不因墙钟回拨恢复；未标记结果仍须使用可信服务端时间。 */
  public boolean expired(long now) {
    return !awaitingResult()
        && (expiredAt != null || storageState == IdempotencyResultStorageState.REDACTED
            || now >= expiresAt);
  }

  /** 同时核对载荷是否存在与主体归属，不将物理清理当作主体擦除。 */
  public void requireConsistent(String classification, boolean bodyAbsent) {
    if (!CLASSIFICATIONS.contains(classification)) {
      throw invalid();
    }
    if (awaitingResult()) {
      if (!"UNCLASSIFIED".equals(classification) || !bodyAbsent) {
        throw invalid();
      }
      return;
    }
    if (storageState == IdempotencyResultStorageState.RETAINED) {
      if (bodyAbsent || "ERASED".equals(classification)) {
        throw invalid();
      }
    } else if (!bodyAbsent || (!"ERASED".equals(classification) && expiredAt == null)) {
      throw invalid();
    }
  }

  /** 90 天从成功结果提交时间起算，溢出或不支持的时间均拒绝。 */
  public static long expirationAt(long committedAt) {
    if (committedAt < 0) {
      throw invalid();
    }
    try {
      return Math.addExact(committedAt, RETENTION_MILLIS);
    } catch (ArithmeticException overflow) {
      throw invalid();
    }
  }

  private static Long number(Map<String, Object> row, String name) {
    if (!row.containsKey(name)) {
      throw invalid();
    }
    Object value = row.get(name);
    if (value == null) {
      return null;
    }
    if (value instanceof Long number) {
      return number;
    }
    if (value instanceof Integer number) {
      return number.longValue();
    }
    throw invalid();
  }

  private static IllegalStateException invalid() {
    return new IllegalStateException("Journal result lifecycle is invalid");
  }
}

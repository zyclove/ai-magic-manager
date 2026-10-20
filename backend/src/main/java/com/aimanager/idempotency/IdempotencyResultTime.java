package com.aimanager.idempotency;

import com.aimanager.shared.DomainException;
import java.sql.Timestamp;
import java.time.Clock;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 结果期限的时间依据：在当前写事务连接上读取主库时间，并与节点 UTC 时间交叉校验。
 *
 * <p>不访问只读副本、不回退到单机墙钟。数据库与节点须由运维独立校时；两者同时错误
 * 无法仅靠应用代码证明真实 UTC。最后可信观察时间由调用者随结果事务持久化。
 */
@Component
public class IdempotencyResultTime {
  private final JdbcTemplate jdbc;
  private final Clock clock;
  private final long maximumSkewMillis;

  public IdempotencyResultTime(JdbcTemplate jdbc, Clock clock,
      IdempotencyRetentionSettings settings) {
    this.jdbc = jdbc;
    this.clock = clock;
    this.maximumSkewMillis = settings.maxClockSkewSeconds() * 1_000L;
  }

  /** 新结果与维护发现使用同一写库依据；不允许在无事务连接的旁路读取。 */
  public long now() {
    if (!TransactionSynchronizationManager.isActualTransactionActive()) {
      throw new IllegalStateException("Result time requires an active transaction");
    }
    long before = clock.millis();
    final Timestamp databaseTime;
    try {
      databaseTime = jdbc.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class);
    } catch (DataAccessException unavailable) {
      // 不将 SQL、连接信息或私密响应附加到公开异常。
      throw untrusted();
    }
    long after = clock.millis();
    if (databaseTime == null || before < 0 || after < before) {
      throw untrusted();
    }
    long observed = databaseTime.getTime();
    if (observed < 0
        || (observed < before && before - observed > maximumSkewMillis)
        || (observed > after && observed - after > maximumSkewMillis)) {
      throw untrusted();
    }
    return observed;
  }

  /** 跨节点或重启后仍拒绝早于此记录最后可信观察的时间；不以创建时间代替回拨检测。 */
  public long now(IdempotencyResultLifecycle lifecycle) {
    if (lifecycle.awaitingResult()) {
      throw new IllegalStateException("Committed result time is required");
    }
    long observed = now();
    if (observed < lifecycle.lastObservedAt()) {
      throw untrusted();
    }
    return observed;
  }

  private static DomainException untrusted() {
    return new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "IDEMPOTENCY_CLOCK_UNTRUSTED");
  }
}

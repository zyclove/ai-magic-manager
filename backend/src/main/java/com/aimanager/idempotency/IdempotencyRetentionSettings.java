package com.aimanager.idempotency;

import java.time.Duration;
import org.springframework.boot.context.properties.ConfigurationProperties;

/** 服务端幂等结果策略；初始保留期固定为已确认的 90 天，不能由请求传入或重试续期。 */
@ConfigurationProperties(prefix = "manager.idempotency")
public record IdempotencyRetentionSettings(
    Long resultRetentionDays, Long policyVersion, Long maxClockSkewSeconds, Maintenance maintenance) {
  public static final long RESULT_RETENTION_DAYS = 90L;
  public static final long DEFAULT_POLICY_VERSION = 1L;

  public IdempotencyRetentionSettings {
    resultRetentionDays = resultRetentionDays == null ? RESULT_RETENTION_DAYS : resultRetentionDays;
    policyVersion = policyVersion == null ? DEFAULT_POLICY_VERSION : policyVersion;
    maxClockSkewSeconds = maxClockSkewSeconds == null ? 5L : maxClockSkewSeconds;
    maintenance = maintenance == null ? Maintenance.defaults() : maintenance;
    if (resultRetentionDays != RESULT_RETENTION_DAYS || policyVersion < DEFAULT_POLICY_VERSION
        || maxClockSkewSeconds < 1 || maxClockSkewSeconds > 300) {
      throw new IllegalArgumentException("Unsupported idempotency retention policy");
    }
  }

  /** 用于明确按首版策略构造服务，不包含环境凭据或客户端可控参数。 */
  public static IdempotencyRetentionSettings defaults() {
    return new IdempotencyRetentionSettings(null, null, null, null);
  }

  /** 从成功结果提交的业务时间计算固定时长，不采用本地日历或最后访问时间。 */
  public Duration resultRetention() {
    return Duration.ofDays(resultRetentionDays);
  }

  /** 物理维护独立配置；开关关闭不能延后恢复读取的逻辑截止。 */
  public record Maintenance(Boolean enabled, Integer batchSize, Integer intervalSeconds) {
    private static final int DEFAULT_BATCH_SIZE = 100;
    private static final int MAX_BATCH_SIZE = 500;
    private static final int DEFAULT_INTERVAL_SECONDS = 300;
    private static final int MAX_INTERVAL_SECONDS = 86_400;

    public Maintenance {
      enabled = enabled == null ? false : enabled;
      batchSize = batchSize == null ? DEFAULT_BATCH_SIZE : batchSize;
      intervalSeconds = intervalSeconds == null ? DEFAULT_INTERVAL_SECONDS : intervalSeconds;
      if (batchSize < 1 || batchSize > MAX_BATCH_SIZE
          || intervalSeconds < 1 || intervalSeconds > MAX_INTERVAL_SECONDS) {
        throw new IllegalArgumentException("Invalid idempotency maintenance bounds");
      }
    }

    public static Maintenance defaults() {
      return new Maintenance(null, null, null);
    }
  }
}

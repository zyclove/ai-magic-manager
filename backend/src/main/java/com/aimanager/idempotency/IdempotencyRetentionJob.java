package com.aimanager.idempotency;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import java.util.concurrent.TimeUnit;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

/**
 * 默认关闭的同步维护入口。既有 ErasureWorkAdvisor 为 Scheduled 调用提供 WorkPermit，
 * 外层准入覆盖独立事务服务直至返回；不自行启动线程、Future 或第二套恢复作业。
 */
@Component
@ConditionalOnProperty(prefix = "manager.idempotency.maintenance", name = "enabled", havingValue = "true")
class IdempotencyRetentionJob {
  private static final Logger LOG = LoggerFactory.getLogger(IdempotencyRetentionJob.class);
  private final IdempotencyRetentionService retention;
  private final IdempotencyRetentionSettings settings;
  private final Counter inspected;
  private final Counter redacted;
  private final Counter failures;

  IdempotencyRetentionJob(IdempotencyRetentionService retention,
      IdempotencyRetentionSettings settings, MeterRegistry metrics) {
    this.retention = retention;
    this.settings = settings;
    this.inspected = metrics.counter("manager.idempotency.retention.inspected");
    this.redacted = metrics.counter("manager.idempotency.retention.redacted");
    this.failures = metrics.counter("manager.idempotency.retention.failures");
  }

  /** 仅记录批次计数及失败类型，避免调度器将 SQL 异常正文或个人响应写入日志。 */
  @Scheduled(
      fixedDelayString = "${manager.idempotency.maintenance.interval-seconds:300}",
      initialDelayString = "${manager.idempotency.maintenance.interval-seconds:300}",
      timeUnit = TimeUnit.SECONDS)
  public void redact() {
    try {
      var result = retention.redactDue(settings.maintenance().batchSize());
      inspected.increment(result.inspected());
      redacted.increment(result.redacted());
      if (result.redacted() > 0) {
        LOG.info("idempotency result retention inspectedCount={} redactedCount={}",
            result.inspected(), result.redacted());
      }
    } catch (RuntimeException failure) {
      failures.increment();
      LOG.error("idempotency result retention failed exceptionType={}",
          failure.getClass().getName());
    }
  }
}

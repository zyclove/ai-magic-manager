package com.aimanager.support;

import com.aimanager.idempotency.IdempotencyResultTime;
import com.aimanager.idempotency.IdempotencyRetentionSettings;
import java.time.Clock;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Adapts existing domain journeys whose database and node time are simulated by one fixture clock.
 * This test-only configuration does not exercise the production database-clock cross-check.
 * The inherited lifecycle overload still rejects time before the persisted last observation.
 */
@TestConfiguration(proxyBeanMethods = false)
public class ControlledIdempotencyTimeConfiguration {
  @Bean
  @Primary
  IdempotencyResultTime controlledIdempotencyResultTime(
      JdbcTemplate jdbc, Clock clock, IdempotencyRetentionSettings settings) {
    return synchronizedTime(jdbc, clock, settings);
  }

  /** Explicit dependency for existing hand-constructed journal fixtures. */
  public static IdempotencyResultTime synchronizedTime(
      JdbcTemplate jdbc, Clock clock, IdempotencyRetentionSettings settings) {
    return new IdempotencyResultTime(jdbc, clock, settings) {
      @Override
      public long now() {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) {
          throw new IllegalStateException("Controlled result time requires an active transaction");
        }
        long observed = clock.millis();
        if (observed < 0) {
          throw new IllegalStateException("Controlled result time is invalid");
        }
        return observed;
      }
    };
  }
}

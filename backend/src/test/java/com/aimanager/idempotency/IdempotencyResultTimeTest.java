package com.aimanager.idempotency;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.Duration;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

/** Exercises the production database/node cross-check, without the domain fixture time adapter. */
class IdempotencyResultTimeTest {
  private JdbcTemplate jdbc;
  private TransactionTemplate transaction;

  @BeforeEach
  void isolatedDatabase() {
    var source=new DriverManagerDataSource(
        "jdbc:h2:mem:result-time-"+UUID.randomUUID()+";DB_CLOSE_DELAY=-1", "sa", "");
    jdbc=new JdbcTemplate(source);
    transaction=new TransactionTemplate(new DataSourceTransactionManager(source));
    transaction.setTimeout(10);
  }

  @Test
  void synchronizedDatabaseAndNodeProvideTimeInsideTheCurrentTransaction() {
    long before=System.currentTimeMillis();
    long observed=transaction.execute(status->time(Clock.systemUTC()).now());
    assertThat(observed).isBetween(before-5000,System.currentTimeMillis()+5000);
  }

  @ParameterizedTest
  @ValueSource(longs={-1,1})
  void nodeAndDatabaseDisagreementInEitherDirectionFailsClosed(long days) {
    var resultTime=time(Clock.offset(Clock.systemUTC(),Duration.ofDays(days)));
    assertUntrusted(()->transaction.execute(status->resultTime.now()));
  }

  @Test
  void readingTimeOutsideTheResultTransactionIsRejected() {
    assertThatThrownBy(()->time(Clock.systemUTC()).now())
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Result time requires an active transaction");
  }

  @Test
  void aPersistedLaterObservationCannotBeReplacedByAnEarlierDatabaseTime() {
    long now=System.currentTimeMillis(),committed=now-1000;
    var lifecycle=new IdempotencyResultLifecycle(IdempotencyResultStorageState.RETAINED,
        committed,committed+Duration.ofDays(90).toMillis(),1L,now+60000,null,null);
    assertUntrusted(()->transaction.execute(status->time(Clock.systemUTC()).now(lifecycle)));
  }

  @Test
  void anUnavailableDatabaseCannotFallBackToNodeTimeOrExposeConnectionDetails() {
    var unavailable=new JdbcTemplate(new DriverManagerDataSource(
        "jdbc:h2:mem:missing-result-time-"+UUID.randomUUID()+";IFEXISTS=TRUE", "sa", ""));
    var resultTime=new IdempotencyResultTime(unavailable,Clock.systemUTC(),IdempotencyRetentionSettings.defaults());
    assertUntrusted(()->transaction.execute(status->resultTime.now()));
  }

  private IdempotencyResultTime time(Clock clock) {
    return new IdempotencyResultTime(jdbc,clock,IdempotencyRetentionSettings.defaults());
  }

  private void assertUntrusted(org.assertj.core.api.ThrowableAssert.ThrowingCallable action) {
    assertThatThrownBy(action).isInstanceOfSatisfying(DomainException.class,failure->{
      assertThat(failure.status()).isEqualTo(HttpStatus.SERVICE_UNAVAILABLE);
      assertThat(failure.errorCode()).isEqualTo("IDEMPOTENCY_CLOCK_UNTRUSTED");
      assertThat(failure.getMessage()).isEqualTo("IDEMPOTENCY_CLOCK_UNTRUSTED");
      assertThat(failure.getCause()).isNull();
    });
  }
}

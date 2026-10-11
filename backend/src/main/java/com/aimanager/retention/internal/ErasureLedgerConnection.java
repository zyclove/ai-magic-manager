package com.aimanager.retention.internal;

import com.aimanager.retention.ErasureLedger;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import jakarta.annotation.PreDestroy;
import java.time.Clock;
import javax.sql.DataSource;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Holds a separate pool without replacing Boot's primary business DataSource bean. */
@Component
class ErasureLedgerConnection implements ErasureLedger, AutoCloseable {
  private final HikariDataSource pool;
  private final JdbcErasureLedger delegate;

  ErasureLedgerConnection(
      DataSource business,
      Clock clock,
      @Value("${manager.erasure-ledger.url:${ERASURE_LEDGER_URL:}}") String url,
      @Value("${manager.erasure-ledger.username:${ERASURE_LEDGER_USERNAME:}}") String username,
      @Value("${manager.erasure-ledger.password:${ERASURE_LEDGER_PASSWORD:}}") String password,
      @Value("${manager.erasure-ledger.id:${ERASURE_LEDGER_ID:}}") String id) {
    if (url.isBlank()) {
      pool = null;
      delegate = null;
      return;
    }
    if (!url.startsWith("jdbc:mysql:") || username.isBlank() || password.isBlank())
      throw new IllegalArgumentException("Invalid independent ledger configuration");
    new Checkpoint(id, 0, LedgerIntegrity.genesis(id));
    var configuration = new HikariConfig();
    configuration.setJdbcUrl(url);
    configuration.setUsername(username);
    configuration.setPassword(password);
    configuration.setMaximumPoolSize(2);
    configuration.setMinimumIdle(0);
    configuration.setConnectionTimeout(5000);
    configuration.setValidationTimeout(3000);
    configuration.setInitializationFailTimeout(-1);
    configuration.setPoolName("erasure-ledger");
    configuration.addDataSourceProperty("connectTimeout", "5000");
    configuration.addDataSourceProperty("socketTimeout", "10000");
    pool = new HikariDataSource(configuration);
    delegate = new JdbcErasureLedger(business, pool, id, clock);
  }

  private JdbcErasureLedger required() {
    if (delegate == null) throw new Failure("ERASURE_LEDGER_NOT_CONFIGURED");
    return delegate;
  }

  @Override
  public Checkpoint head() {
    return required().head();
  }

  @Override
  public Entry append(Request request) {
    return required().append(request);
  }

  @Override
  public Page readAfter(Checkpoint checkpoint, int limit) {
    return required().readAfter(checkpoint, limit);
  }

  @Override
  @PreDestroy
  public void close() {
    if (pool != null) pool.close();
  }
}

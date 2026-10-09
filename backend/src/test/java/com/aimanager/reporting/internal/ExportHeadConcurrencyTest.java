package com.aimanager.reporting.internal;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.identity.ActorKeys;
import java.util.*;
import java.util.concurrent.*;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.support.TransactionTemplate;

class ExportHeadConcurrencyTest {
  @Test
  void distinctCreatorsQueuedBehindExistingHeadDoNotUpgradeSharedLocks() throws Exception {
    var source =
        new DriverManagerDataSource(
            System.getenv()
                .getOrDefault(
                    "EXPORT_HEAD_TEST_DATABASE_URL",
                    "jdbc:h2:mem:export-head-"
                        + UUID.randomUUID()
                        + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            System.getenv().getOrDefault("EXPORT_HEAD_TEST_DATABASE_USERNAME", "sa"),
            System.getenv().getOrDefault("EXPORT_HEAD_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    Flyway.configure()
        .dataSource(source)
        .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
        .load()
        .migrate();
    var db = new JdbcTemplate(source);
    var store = new ExportStore(db);
    var tx = new TransactionTemplate(new DataSourceTransactionManager(source));
    tx.setTimeout(10);
    for (int round = 0; round < 3; round++) {
      String tenant = UUID.randomUUID().toString();
      db.update(
          "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Head"
              + " contention','FAMILY','UTC',1)",
          tenant);
      db.update("INSERT INTO audit_export_heads(tenant_id) VALUES(?)", tenant);
      var actors = new ArrayList<String>();
      for (int n = 0; n < 4; n++) {
        String actor = "creator-" + UUID.randomUUID();
        actors.add(actor);
        db.update(
            "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role)"
                + " VALUES(?,?,?,'GUARDIAN')",
            tenant,
            actor,
            ActorKeys.key(actor));
      }
      var executor = Executors.newFixedThreadPool(4);
      var futures = new ArrayList<Future<?>>();
      var waiting = new CountDownLatch(4);
      try (var holder = source.getConnection()) {
        holder.setAutoCommit(false);
        try (var lock =
            holder.prepareStatement(
                "SELECT tenant_id FROM audit_export_heads WHERE tenant_id=? FOR UPDATE")) {
          lock.setString(1, tenant);
          try (var rows = lock.executeQuery()) {
            assertThat(rows.next()).isTrue();
          }
        }
        for (String actor : actors)
          futures.add(
              executor.submit(
                  () ->
                      tx.executeWithoutResult(
                          status -> {
                            assertThat(store.authorize(tenant, actor, true).allowed()).isTrue();
                            waiting.countDown();
                            store.head(tenant);
                          })));
        assertThat(waiting.await(5, TimeUnit.SECONDS)).isTrue();
        // Let each independent creator queue behind the exclusive head holder.
        Thread.sleep(300);
        holder.commit();
        for (var future : futures) future.get(12, TimeUnit.SECONDS);
      } finally {
        executor.shutdownNow();
        executor.awaitTermination(5, TimeUnit.SECONDS);
      }
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM audit_export_heads WHERE tenant_id=?",
                  Integer.class,
                  tenant))
          .isEqualTo(1);
    }
  }
}

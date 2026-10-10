package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

/** An existing V29 customer database remains intact when V30 creates the operator catalog. */
class CommercialCatalogMigrationTest {
  @Test
  void nonemptyV29UpgradePreservesCommercialEntitlementsAndRepeatsSafely() {
    var env = System.getenv();
    var source =
        new DriverManagerDataSource(
            env.getOrDefault(
                "CATALOG_MIGRATION_TEST_DATABASE_URL",
                "jdbc:h2:mem:commercial-catalog-upgrade-"
                    + UUID.randomUUID()
                    + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            env.getOrDefault("CATALOG_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            env.getOrDefault("CATALOG_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    var previous =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("29")
            .load();
    assertThat(previous.migrate().migrationsExecuted).isEqualTo(29);
    var db = new JdbcTemplate(source);
    String tenantId = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at)"
            + " VALUES(?,'Existing household','FAMILY','UTC',1)",
        tenantId);
    db.update("INSERT INTO commercial_accounts(tenant_id,version) VALUES(?,9)", tenantId);
    var tenantBefore = db.queryForList("SELECT * FROM tenants WHERE id=?", tenantId);
    var accountBefore =
        db.queryForList("SELECT * FROM commercial_accounts WHERE tenant_id=?", tenantId);

    var upgraded =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("30")
            .load();
    assertThat(upgraded.migrate().migrationsExecuted).isEqualTo(1);
    assertThat(upgraded.info().applied()).hasSize(30);
    assertThat(db.queryForList("SELECT * FROM tenants WHERE id=?", tenantId))
        .isEqualTo(tenantBefore);
    assertThat(db.queryForList("SELECT * FROM commercial_accounts WHERE tenant_id=?", tenantId))
        .isEqualTo(accountBefore);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM commercial_catalog_offers", Integer.class))
        .isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM commercial_catalog_events", Integer.class))
        .isZero();
    assertThat(upgraded.migrate().migrationsExecuted).isZero();
  }
}

package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.identity.ActorKeys;
import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class AuditExportMigrationTest {
  @Test
  void nonemptyV21UpgradePreservesMembersAndAuditAndIsRepeatable() {
    var source =
        new DriverManagerDataSource(
            System.getenv()
                .getOrDefault(
                    "EXPORT_MIGRATION_TEST_DATABASE_URL",
                    "jdbc:h2:mem:export-upgrade-"
                        + UUID.randomUUID()
                        + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            System.getenv().getOrDefault("EXPORT_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            System.getenv().getOrDefault("EXPORT_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    var old =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("21")
            .load();
    old.migrate();
    assertThat(old.info().applied()).hasSize(21);
    var db = new JdbcTemplate(source);
    String tenant = UUID.randomUUID().toString(), event = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Migration"
            + " fixture','FAMILY','Asia/Shanghai',90)",
        tenant);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role)"
            + " VALUES(?,'export-owner',?,'OWNER')",
        tenant,
        ActorKeys.key("export-owner"));
    db.update(
        "INSERT INTO"
            + " audit_events(tenant_id,id,actor_id,action,resource_id,correlation_id,occurred_at)"
            + " VALUES(?,?,'export-owner','TENANT_CREATED',?,?,90)",
        tenant,
        event,
        tenant,
        event);
    var members = db.queryForList("SELECT * FROM tenant_members ORDER BY actor_key");
    var events = db.queryForList("SELECT * FROM audit_events ORDER BY id");
    var upgraded =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("22")
            .load();
    assertThat(upgraded.migrate().migrationsExecuted).isEqualTo(1);
    assertThat(upgraded.info().applied()).hasSize(22);
    assertThat(db.queryForList("SELECT * FROM tenant_members ORDER BY actor_key"))
        .isEqualTo(members);
    assertThat(db.queryForList("SELECT * FROM audit_events ORDER BY id")).isEqualTo(events);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_exports", Long.class)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_export_heads", Long.class)).isZero();
    assertThat(upgraded.migrate().migrationsExecuted).isZero();
  }
}

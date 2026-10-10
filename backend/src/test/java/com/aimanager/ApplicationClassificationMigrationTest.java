package com.aimanager;

import static org.assertj.core.api.Assertions.*;

import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class ApplicationClassificationMigrationTest {
  @Test
  void nonemptyV23ApplicationIdentitiesRemainUnchangedAfterV24() {
    var env = System.getenv();
    var source =
        new DriverManagerDataSource(
            env.getOrDefault(
                "CLASSIFICATION_MIGRATION_TEST_DATABASE_URL",
                "jdbc:h2:mem:classification-upgrade-"
                    + UUID.randomUUID()
                    + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            env.getOrDefault("CLASSIFICATION_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            env.getOrDefault("CLASSIFICATION_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    var old =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("23")
            .load();
    old.migrate();
    assertThat(old.info().applied()).hasSize(23);
    var db = new JdbcTemplate(source);
    String tenant = UUID.randomUUID().toString(), id = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Category"
            + " upgrade','FAMILY','UTC',1)",
        tenant);
    String definition =
        "{\"id\":\""
            + id
            + "\",\"displayName\":\"Reader\",\"platform\":\"ANDROID\",\"profile\":\"PRIMARY\",\"packageName\":\"org.example.reader\",\"signingDigests\":[],\"evidenceStatus\":\"ADMIN_DECLARED\"}";
    db.update(
        "INSERT INTO application_definitions(tenant_id,id,identity_hash,definition_json)"
            + " VALUES(?,?,?,?)",
        tenant,
        id,
        "a".repeat(64),
        definition);
    var upgraded =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("24")
            .load();
    upgraded.migrate();
    assertThat(upgraded.info().applied()).hasSize(24);
    assertThat(
            db.queryForObject(
                "SELECT definition_json FROM application_definitions WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                id))
        .isEqualTo(definition);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM application_classifications WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isZero();
  }
}

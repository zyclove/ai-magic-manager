package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.identity.ActorKeys;
import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class SupportPairingMigrationTest {
  @Test
  void nonemptyV25UpgradePreservesIdentityAndEncryptedReportAndRepeatsSafely() {
    var env = System.getenv();
    var source =
        new DriverManagerDataSource(
            env.getOrDefault(
                "SUPPORT_MIGRATION_TEST_DATABASE_URL",
                "jdbc:h2:mem:support-upgrade-"
                    + UUID.randomUUID()
                    + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            env.getOrDefault("SUPPORT_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            env.getOrDefault("SUPPORT_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    var old =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("25")
            .load();
    old.migrate();
    assertThat(old.info().applied()).hasSize(25);
    var db = new JdbcTemplate(source);
    String tenant = UUID.randomUUID().toString(),
        actor = "support-migration-owner",
        key = ActorKeys.key(actor),
        job = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Support"
            + " migration','FAMILY','UTC',1)",
        tenant);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,version)"
            + " VALUES(?,?,?,'OWNER',7)",
        tenant,
        actor,
        key);
    db.update(
        "INSERT INTO"
            + " actor_profiles(actor_key,actor_id,display_name,verified_email,claims_issued_at,observed_at)"
            + " VALUES(?,?,'Existing owner','owner@example.test',1,2)",
        key,
        actor);
    db.update("INSERT INTO usage_report_job_heads(tenant_id) VALUES(?)", tenant);
    db.update(
        "INSERT INTO"
            + " usage_report_jobs(tenant_id,id,creator_key,member_version,state,selection_json,selection_hash,total_devices,completed_devices,created_at,updated_at,expires_at,next_attempt_at)"
            + " VALUES(?,?,?,7,'READY','{}',?,1,1,1,2,999999,1)",
        tenant,
        job,
        key,
        "a".repeat(64));
    db.update(
        "INSERT INTO"
            + " usage_report_parts(tenant_id,job_id,ordinal,device_id,registration_id,subject_id,authorization_version,usage_enabled,artifact)"
            + " VALUES(?,?,0,?,?,?,1,true,?)",
        tenant,
        job,
        UUID.randomUUID().toString(),
        UUID.randomUUID().toString(),
        UUID.randomUUID().toString(),
        "unchanged.encrypted.report.fixture");
    var members = db.queryForList("SELECT * FROM tenant_members ORDER BY actor_key");
    var profiles = db.queryForList("SELECT * FROM actor_profiles ORDER BY actor_key");
    var jobs = db.queryForList("SELECT * FROM usage_report_jobs ORDER BY id");
    var parts = db.queryForList("SELECT * FROM usage_report_parts ORDER BY ordinal");
    var upgraded =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("26")
            .load();
    assertThat(upgraded.migrate().migrationsExecuted).isEqualTo(1);
    assertThat(upgraded.info().applied()).hasSize(26);
    assertThat(db.queryForList("SELECT * FROM tenant_members ORDER BY actor_key"))
        .isEqualTo(members);
    assertThat(db.queryForList("SELECT * FROM actor_profiles ORDER BY actor_key"))
        .isEqualTo(profiles);
    assertThat(db.queryForList("SELECT * FROM usage_report_jobs ORDER BY id")).isEqualTo(jobs);
    assertThat(db.queryForList("SELECT * FROM usage_report_parts ORDER BY ordinal"))
        .isEqualTo(parts);
    for (String table :
        java.util.List.of(
            "support_pairing_creation_locks",
            "support_pairing_heads",
            "support_pairing_requests",
            "support_pairing_events"))
      assertThat(db.queryForObject("SELECT COUNT(*) FROM " + table, Integer.class)).isZero();
    assertThat(upgraded.migrate().migrationsExecuted).isZero();
  }
}

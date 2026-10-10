package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class UsageReportJobMigrationTest {
  @Test
  void nonemptyV24DataAndEncryptedAuditArtifactsRemainUnchanged() {
    var env = System.getenv();
    var source =
        new DriverManagerDataSource(
            env.getOrDefault(
                "REPORT_JOB_MIGRATION_TEST_DATABASE_URL",
                "jdbc:h2:mem:report-job-upgrade-"
                    + UUID.randomUUID()
                    + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            env.getOrDefault("REPORT_JOB_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            env.getOrDefault("REPORT_JOB_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    var old =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("24")
            .load();
    old.migrate();
    assertThat(old.info().applied()).hasSize(24);
    var db = new JdbcTemplate(source);
    String tenant = UUID.randomUUID().toString(), id = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Report"
            + " upgrade','FAMILY','UTC',1)",
        tenant);
    String actor = "migration-owner", key = com.aimanager.identity.ActorKeys.key(actor);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'OWNER')",
        tenant,
        actor,
        key);
    db.update(
        "INSERT INTO"
            + " application_classifications(tenant_id,identity_hash,platform,profile,package_name,category,version,updated_at)"
            + " VALUES(?,?,'ANDROID','PRIMARY','org.example.reader','EDUCATION',7,1)",
        tenant,
        "a".repeat(64));
    String artifact = "unchanged.encrypted.audit.fixture";
    db.update(
        "INSERT INTO"
            + " audit_exports(tenant_id,id,creator_key,member_version,state,range_from,range_to,requested_to,created_at,updated_at,expires_at,next_attempt_at,artifact)"
            + " VALUES(?,?,?,0,'READY',1,2,2,1,1,100000,1,?)",
        tenant,
        id,
        key,
        artifact);
    var upgraded =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("25")
            .load();
    upgraded.migrate();
    assertThat(upgraded.info().applied()).hasSize(25);
    assertThat(
            db.queryForObject(
                "SELECT artifact FROM audit_exports WHERE tenant_id=? AND id=?",
                String.class,
                tenant,
                id))
        .isEqualTo(artifact);
    assertThat(
            db.queryForObject(
                "SELECT version FROM application_classifications WHERE tenant_id=?",
                Long.class,
                tenant))
        .isEqualTo(7);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM usage_report_jobs", Integer.class)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM usage_report_parts", Integer.class))
        .isZero();
  }
}

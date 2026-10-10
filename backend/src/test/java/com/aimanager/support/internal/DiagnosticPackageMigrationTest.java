package com.aimanager.support.internal;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.identity.ActorKeys;
import java.util.UUID;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

class DiagnosticPackageMigrationTest {
  @Test
  void nonemptyV28UpgradePreservesSupportCommercialAndEncryptedReportAndRepeatsSafely() {
    var env = System.getenv();
    var source =
        new DriverManagerDataSource(
            env.getOrDefault(
                "SUPPORT_MIGRATION_TEST_DATABASE_URL",
                "jdbc:h2:mem:diagnostic-package-upgrade-"
                    + UUID.randomUUID()
                    + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            env.getOrDefault("SUPPORT_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            env.getOrDefault("SUPPORT_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    var old =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("28")
            .load();
    old.migrate();
    assertThat(old.info().applied()).hasSize(28);
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
    String pairing = UUID.randomUUID().toString();
    db.update("INSERT INTO support_pairing_creation_locks(actor_key) VALUES(?)", key);
    db.update(
        "INSERT INTO"
            + " support_pairing_heads(actor_key,create_window,create_count,resolve_window,resolve_count)"
            + " VALUES(?,1,2,3,4)",
        key);
    db.update(
        "INSERT INTO"
            + " support_pairing_requests(id,recipient_actor_id,recipient_key,display_name,verified_email,code_hash,state,version,created_at,expires_at,updated_at)"
            + " VALUES(?,?,?,'Existing"
            + " recipient','recipient@example.test',?,'PENDING',4,10,9999999999999,20)",
        pairing,
        actor,
        key,
        "b".repeat(64));
    db.update(
        "INSERT INTO support_pairing_events(id,request_id,actor_key,action,occurred_at)"
            + " VALUES(?,?,?,'CREATED',10)",
        UUID.randomUUID().toString(),
        pairing,
        key);
    String subject = UUID.randomUUID().toString(),
        device = UUID.randomUUID().toString(),
        registration = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'Migration"
            + " child','AGE_7_12',1)",
        tenant,
        subject);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'Migration device','ANDROID','14','ACTIVE','fixture','fixture',1)",
        tenant,
        device,
        subject,
        registration);
    db.update("INSERT INTO support_grant_heads(tenant_id) VALUES(?)", tenant);
    db.update("UPDATE support_pairing_requests SET state='CONSUMED' WHERE id=?", pairing);
    db.update(
        "INSERT INTO"
            + " support_grants(id,tenant_id,device_id,subject_id,registration_id,creator_actor_id,creator_key,creator_member_version,recipient_actor_id,recipient_key,pairing_id,type_mask,state,created_at,expires_at,updated_at)"
            + " VALUES(?,?,?,?,?,?,?,7,?,?,?,1,'ACTIVE',10,9999999999999,20)",
        UUID.randomUUID().toString(),
        tenant,
        device,
        subject,
        registration,
        actor,
        key,
        actor,
        key,
        pairing);
    db.update("INSERT INTO commercial_accounts(tenant_id,version) VALUES(?,3)", tenant);
    db.update(
        "INSERT INTO"
            + " commercial_sources(tenant_id,source_system,source_key,source_revision,product_key,capacity_kind,device_capacity,features_json,active_from,expires_at,state,payload_hash,evidence_hash,verified_by,verified_at)"
            + " VALUES(?,'MANUAL',?,2,'family-fixture','BASE',5,'[]',1,9999999999999,'ACTIVE',?,?,'fixture-verifier',2)",
        tenant,
        "c".repeat(64),
        "d".repeat(64),
        "e".repeat(64));
    db.update(
        "INSERT INTO"
            + " commercial_source_events(tenant_id,source_system,source_key,source_revision,id,product_key,capacity_kind,device_capacity,features_json,active_from,expires_at,state,payload_hash,evidence_hash,verified_by,verified_at)"
            + " SELECT"
            + " tenant_id,source_system,source_key,source_revision,?,product_key,capacity_kind,device_capacity,features_json,active_from,expires_at,state,payload_hash,evidence_hash,verified_by,verified_at"
            + " FROM commercial_sources WHERE tenant_id=?",
        UUID.randomUUID().toString(),
        tenant);
    var pairingTables =
        java.util.List.of(
            "support_pairing_creation_locks",
            "support_pairing_heads",
            "support_pairing_requests",
            "support_pairing_events",
            "support_grant_heads",
            "support_grants",
            "subjects",
            "devices",
            "commercial_accounts",
            "commercial_sources",
            "commercial_source_events");
    var pairingBefore =
        new java.util.LinkedHashMap<String, java.util.List<java.util.Map<String, Object>>>();
    for (String table : pairingTables)
      pairingBefore.put(table, db.queryForList("SELECT * FROM " + table));
    var members = db.queryForList("SELECT * FROM tenant_members ORDER BY actor_key");
    var profiles = db.queryForList("SELECT * FROM actor_profiles ORDER BY actor_key");
    var jobs = db.queryForList("SELECT * FROM usage_report_jobs ORDER BY id");
    var parts = db.queryForList("SELECT * FROM usage_report_parts ORDER BY ordinal");
    var upgraded =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("29")
            .load();
    assertThat(upgraded.migrate().migrationsExecuted).isEqualTo(1);
    assertThat(upgraded.info().applied()).hasSize(29);
    assertThat(db.queryForList("SELECT * FROM tenant_members ORDER BY actor_key"))
        .isEqualTo(members);
    assertThat(db.queryForList("SELECT * FROM actor_profiles ORDER BY actor_key"))
        .isEqualTo(profiles);
    assertThat(db.queryForList("SELECT * FROM usage_report_jobs ORDER BY id")).isEqualTo(jobs);
    assertThat(db.queryForList("SELECT * FROM usage_report_parts ORDER BY ordinal"))
        .isEqualTo(parts);
    for (String table : pairingTables)
      assertThat(db.queryForList("SELECT * FROM " + table)).isEqualTo(pairingBefore.get(table));
    for (String table : java.util.List.of("diagnostic_package_heads", "diagnostic_packages"))
      assertThat(db.queryForObject("SELECT COUNT(*) FROM " + table, Integer.class)).isZero();
    assertThat(upgraded.migrate().migrationsExecuted).isZero();
  }
}

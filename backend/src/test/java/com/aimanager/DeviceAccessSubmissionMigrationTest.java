package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.approval.AccessRequest;
import com.aimanager.identity.ActorKeys;
import java.util.*;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

/** Nonempty member requests survive V22 -> V23 with explicit legacy authority. */
class DeviceAccessSubmissionMigrationTest {
  @Test
  void memberRequestsNotificationsDecisionsAndRetriesKeepTheirOriginalFacts() {
    var source =
        new DriverManagerDataSource(
            System.getenv()
                .getOrDefault(
                    "ACCESS_SUBMISSION_MIGRATION_TEST_DATABASE_URL",
                    "jdbc:h2:mem:device-submission-upgrade-"
                        + UUID.randomUUID()
                        + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            System.getenv()
                .getOrDefault("ACCESS_SUBMISSION_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            System.getenv().getOrDefault("ACCESS_SUBMISSION_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    var config =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor);
    var old = config.target("22").load();
    old.migrate();
    assertThat(old.info().applied()).hasSize(22);
    var db = new JdbcTemplate(source);
    String tenant = UUID.randomUUID().toString(), entity = UUID.randomUUID().toString();
    String actor = ActorKeys.key("migration-owner");
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Migration"
            + " fixture','FAMILY','Asia/Shanghai',90)",
        tenant);
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'Fixture','AGE_7_12',90)",
        tenant,
        entity);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role)"
            + " VALUES(?,'migration-owner',?,'OWNER')",
        tenant,
        actor);
    db.update(
        "INSERT INTO application_definitions(tenant_id,id,identity_hash,definition_json)"
            + " VALUES(?,?,?,'{}')",
        tenant,
        entity,
        "a".repeat(64));
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'Fixture','POLICY','[]',90,90)",
        tenant,
        entity);
    db.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
            + " VALUES(?,?,?,0,?,'{}',90,200)",
        tenant,
        entity,
        entity,
        "b".repeat(64));
    db.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at)"
            + " VALUES(?,?,?,0,1,?,?,'ENFORCE','{}',90)",
        tenant,
        entity,
        entity,
        entity,
        "b".repeat(64));
    for (var state : AccessRequest.State.values()) {
      String id = UUID.randomUUID().toString();
      db.update(
          "INSERT INTO"
              + " access_requests(tenant_id,id,subject_id,device_id,registration_id,policy_id,base_version_id,base_sequence,application_id,rule_ids_json,requester_actor_id,requester_actor_key,requested_window_seconds,child_reason,state,request_expires_at,version,created_at,updated_at)"
              + " VALUES(?,?,?,?,?,?,?,1,?,'[]','migration-owner',?,600,'private fixture"
              + " reason',?,999,?,90,?)",
          tenant,
          id,
          entity,
          entity,
          entity,
          entity,
          entity,
          entity,
          actor,
          state.name(),
          4 + state.ordinal(),
          100 + state.ordinal());
    }
    db.update(
        "INSERT INTO"
            + " notification_events(tenant_id,id,request_id,subject_id,device_id,requester_actor_key,request_version,state,occurred_at)"
            + " SELECT"
            + " tenant_id,id,id,subject_id,device_id,requester_actor_key,version,state,updated_at"
            + " FROM access_requests");
    String request =
        db.queryForObject("SELECT id FROM access_requests WHERE state='DENIED'", String.class);
    db.update(
        "INSERT INTO"
            + " access_request_decisions(tenant_id,request_id,decision,actor_id,reason_code,decided_at)"
            + " VALUES(?,?,'DENY','migration-owner','FIXTURE',95)",
        tenant,
        request);
    db.update(
        "INSERT INTO"
            + " idempotency_requests(scope_id,actor_id,actor_key,operation,key_hash,request_hash,response_body,expires_at)"
            + " VALUES(?,'migration-owner',?,'access.request',?,?,'{}',999)",
        tenant,
        actor,
        "c".repeat(64),
        "d".repeat(64));
    db.update(
        "INSERT INTO notification_reads(tenant_id,notification_id,actor_key,read_at)"
            + " VALUES(?,?,?,96)",
        tenant,
        request,
        actor);
    var tables =
        List.of(
            "access_requests",
            "notification_events",
            "access_request_decisions",
            "idempotency_requests",
            "notification_reads");
    var before = new HashMap<String, List<Map<String, Object>>>();
    for (String table : tables) before.put(table, db.queryForList("SELECT * FROM " + table));
    var upgraded =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("23")
            .load();
    assertThat(upgraded.migrate().migrationsExecuted).isEqualTo(1);
    assertThat(upgraded.info().applied()).hasSize(23);
    for (String table : tables) {
      var after = db.queryForList("SELECT * FROM " + table);
      if (table.equals("access_requests") || table.equals("notification_events"))
        for (var row : after) assertThat(row.remove("requester_kind")).isEqualTo("MEMBER");
      assertThat(after).containsExactlyInAnyOrderElementsOf(before.get(table));
    }
    assertThat(upgraded.migrate().migrationsExecuted).isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM access_requests WHERE requester_kind='MEMBER'",
                Integer.class))
        .isEqualTo(AccessRequest.State.values().length);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM notification_events WHERE requester_kind='MEMBER'",
                Integer.class))
        .isEqualTo(AccessRequest.State.values().length);
  }
}

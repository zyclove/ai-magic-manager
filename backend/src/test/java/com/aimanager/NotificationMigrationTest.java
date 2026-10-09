package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.approval.AccessRequest;
import com.aimanager.identity.ActorKeys;
import java.util.*;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

/** Full V1–V20 schema with nonempty facts, then the actual V21 migration. */
class NotificationMigrationTest {
  @Test
  void existingCurrentVersionsBackfillOnceWithoutRewritingApprovalFacts() {
    var source =
        new DriverManagerDataSource(
            System.getenv()
                .getOrDefault(
                    "NOTIFICATION_MIGRATION_TEST_DATABASE_URL",
                    "jdbc:h2:mem:notification-upgrade-"
                        + UUID.randomUUID()
                        + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            System.getenv().getOrDefault("NOTIFICATION_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            System.getenv().getOrDefault("NOTIFICATION_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    String vendor = source.getUrl().startsWith("jdbc:mysql:") ? "mysql" : "h2";
    var config =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor);
    var old = config.target("20").load();
    old.migrate();
    assertThat(old.info().applied()).hasSize(20);
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
    var before = db.queryForList("SELECT * FROM access_requests ORDER BY id");
    var upgraded =
        Flyway.configure()
            .dataSource(source)
            .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
            .target("21")
            .load();
    assertThat(upgraded.migrate().migrationsExecuted).isEqualTo(1);
    assertThat(upgraded.info().applied()).hasSize(21);
    assertThat(db.queryForList("SELECT * FROM access_requests ORDER BY id")).isEqualTo(before);
    var notices = db.queryForList("SELECT * FROM notification_events ORDER BY id");
    assertThat(notices).hasSize(AccessRequest.State.values().length);
    for (int i = 0; i < notices.size(); i++) {
      var row = notices.get(i);
      var fact = before.get(i);
      assertThat(row.get("id")).isEqualTo(fact.get("id"));
      assertThat(row.get("request_id")).isEqualTo(fact.get("id"));
      assertThat(row.get("state")).isEqualTo(fact.get("state"));
      assertThat(row.get("request_version")).isEqualTo(fact.get("version"));
      assertThat(row.get("occurred_at")).isEqualTo(fact.get("updated_at"));
      assertThat(row.keySet()).doesNotContain("child_reason", "requester_actor_id");
    }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM notification_reads", Integer.class))
        .isZero();
    assertThat(upgraded.migrate().migrationsExecuted).isZero();
    assertThat(db.queryForList("SELECT * FROM notification_events ORDER BY id")).isEqualTo(notices);
  }
}

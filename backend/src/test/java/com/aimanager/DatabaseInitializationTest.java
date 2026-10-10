package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.*;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

/** 1.0.0 is a fresh installation baseline, without historical upgrade fixtures. */
class DatabaseInitializationTest {
  @Test
  void freshInstallationCreatesCompleteEmptySchemaAndRestartDoesNotReinitializeIt() {
    var env=System.getenv();
    var source=new DriverManagerDataSource(
        env.getOrDefault("INITIALIZATION_TEST_DATABASE_URL","jdbc:h2:mem:initialization-"+UUID.randomUUID()+";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
        env.getOrDefault("INITIALIZATION_TEST_DATABASE_USERNAME","sa"),
        env.getOrDefault("INITIALIZATION_TEST_DATABASE_PASSWORD",""));
    String vendor=source.getUrl().startsWith("jdbc:mysql:")?"mysql":"h2";
    var initializer=Flyway.configure().dataSource(source)
        .locations("classpath:db/migration","classpath:db/vendor/"+vendor).load();
    assertThat(initializer.migrate().migrationsExecuted).isEqualTo(2);
    assertThat(initializer.info().applied()).hasSize(2);
    var db=new JdbcTemplate(source);
    assertThat(db.queryForList("SELECT version FROM flyway_schema_history WHERE version IS NOT NULL ORDER BY installed_rank",String.class)).containsExactly("1","2");
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects",Integer.class)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM diagnostic_packages",Integer.class)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM commercial_catalog_offers",Integer.class)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM EVENT_PUBLICATION",Integer.class)).isZero();
    // Freshly created columns include current authority epochs, scopes and delivery-attempt fields.
    db.queryForList("SELECT version,revoked_at FROM tenant_members WHERE 1=0");
    db.queryForList("SELECT requester_kind FROM access_requests WHERE 1=0");
    db.queryForList("SELECT requester_kind FROM notification_events WHERE 1=0");
    db.queryForList("SELECT current_attempt FROM access_window_documents WHERE 1=0");
    db.queryForList("SELECT creator_actor_key FROM policy_previews WHERE 1=0");
    db.queryForList("SELECT previous_class_ids_json,class_ids_json FROM membership_access_changes WHERE 1=0");
    String tenant=UUID.randomUUID().toString();
    db.update("INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'New 1.0.0 workspace','FAMILY','UTC',1)",tenant);
    assertThat(initializer.migrate().migrationsExecuted).isZero();
    assertThat(db.queryForObject("SELECT name FROM tenants WHERE id=?",String.class,tenant)).isEqualTo("New 1.0.0 workspace");
  }
}

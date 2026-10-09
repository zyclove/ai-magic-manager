package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;

class AccessDeliveryMigrationTest {
  @Test
  void existingDocumentsAndEveryReceiptBecomeAttemptOneWithoutRewritingSignatures() {
    var data =
        new DriverManagerDataSource(
            System.getenv()
                .getOrDefault(
                    "ACCESS_MIGRATION_TEST_DATABASE_URL",
                    "jdbc:h2:mem:access-upgrade-"
                        + UUID.randomUUID()
                        + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE"),
            System.getenv().getOrDefault("ACCESS_MIGRATION_TEST_DATABASE_USERNAME", "sa"),
            System.getenv().getOrDefault("ACCESS_MIGRATION_TEST_DATABASE_PASSWORD", ""));
    var jdbc = new JdbcTemplate(data);
    // Minimal parent key required by the exact V15/V16 SQL under examination.
    jdbc.execute(
        "CREATE TABLE access_requests(tenant_id VARCHAR(36),id VARCHAR(36),device_id"
            + " VARCHAR(36),registration_id VARCHAR(36),PRIMARY KEY(tenant_id,id))");
    new ResourceDatabasePopulator(
            new ClassPathResource("db/migration/V15__access_window_documents.sql"))
        .execute(data);
    String tenant = UUID.randomUUID().toString();
    for (String state : List.of("SIGNED", "RECEIVED", "STORED", "REJECTED")) {
      String id = UUID.randomUUID().toString();
      jdbc.update("INSERT INTO access_requests(tenant_id,id) VALUES(?,?)", tenant, id);
      jdbc.update(
          "INSERT INTO"
              + " access_window_documents(tenant_id,id,request_id,approval_version,action,signed_document,issued_at,delivery_state,last_receipt_at)"
              + " VALUES(?,?,?,1,'UPSERT_ACCESS_WINDOW',?,100,?,?)",
          tenant,
          id,
          id,
          "immutable-fixture-" + state,
          state,
          state.equals("SIGNED") ? null : 120L);
      if (!state.equals("SIGNED"))
        jdbc.update(
            "INSERT INTO access_window_receipts VALUES(?,?,'RECEIVED',NULL,110)", tenant, id);
      if (state.equals("STORED") || state.equals("REJECTED"))
        jdbc.update(
            "INSERT INTO access_window_receipts VALUES(?,?,?,?,120)",
            tenant,
            id,
            state,
            state.equals("REJECTED") ? "STORAGE_FAILED" : null);
    }
    new ResourceDatabasePopulator(
            new ClassPathResource("db/migration/V16__access_delivery_attempts.sql"))
        .execute(data);
    var rows =
        jdbc.queryForList(
            "SELECT"
                + " d.signed_document,d.delivery_state,d.current_attempt,a.created_at,a.reason_code,a.last_receipt_at"
                + " FROM access_window_documents d JOIN access_window_attempts a ON"
                + " a.tenant_id=d.tenant_id AND a.document_id=d.id WHERE a.attempt_number=1");
    assertThat(rows).hasSize(4);
    for (var row : rows) {
      String state = row.get("delivery_state").toString();
      assertThat(row.get("signed_document")).isEqualTo("immutable-fixture-" + state);
      assertThat(((Number) row.get("current_attempt")).intValue()).isEqualTo(1);
      assertThat(((Number) row.get("created_at")).longValue()).isEqualTo(100);
      assertThat(row.get("reason_code"))
          .isEqualTo(state.equals("REJECTED") ? "STORAGE_FAILED" : null);
      if (state.equals("SIGNED")) assertThat(row.get("last_receipt_at")).isNull();
      else assertThat(((Number) row.get("last_receipt_at")).longValue()).isEqualTo(120);
    }
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM access_window_attempt_receipts WHERE attempt_number=1",
                Integer.class))
        .isEqualTo(5);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM access_window_receipts", Integer.class))
        .isEqualTo(5);
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM access_window_attempt_receipts WHERE"
                    + " reason_code='STORAGE_FAILED' AND phase='REJECTED'",
                Integer.class))
        .isEqualTo(1);
  }
}

package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.aimanager.retention.ErasureLedger;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(
    properties = {
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false",
      "manager.diagnostic-packages.worker.enabled=false",
      "manager.erasure-previews.cleanup.enabled=false"
    })
@AutoConfigureMockMvc
@EnabledIfEnvironmentVariable(named = "LEDGER_STORE_TEST_URL", matches = "jdbc:mysql:.*")
class ErasureLedgerRuntimeTest {
  private static final String LEDGER_ID = UUID.randomUUID().toString();
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate business;
  @Autowired ErasureLedger ledger;
  JdbcTemplate ledgerDb;
  String tenant, subject, owner, path;

  static String url(String prefix) {
    String value = System.getenv(prefix + "_URL");
    if (value == null
        || !value.matches("jdbc:mysql://127\\.0\\.0\\.1:3308/notification_it_[a-f0-9]{32}\\?.*"))
      throw new IllegalArgumentException("Runtime ledger tests require isolated schemas");
    return value;
  }

  @DynamicPropertySource
  static void databaseProperties(DynamicPropertyRegistry properties) {
    // The real startup guard must see a provisioned empty ledger before context refresh.
    ErasureLedgerBootstrap.initialize(
        new DriverManagerDataSource(
            url("LEDGER_STORE_TEST"),
            System.getenv("LEDGER_STORE_TEST_USERNAME"),
            System.getenv("LEDGER_STORE_TEST_PASSWORD")),
        LEDGER_ID);
    properties.add("spring.datasource.url", () -> url("LEDGER_BUSINESS_TEST"));
    properties.add(
        "spring.datasource.username", () -> System.getenv("LEDGER_BUSINESS_TEST_USERNAME"));
    properties.add(
        "spring.datasource.password", () -> System.getenv("LEDGER_BUSINESS_TEST_PASSWORD"));
    properties.add("manager.erasure-ledger.url", () -> url("LEDGER_STORE_TEST"));
    properties.add(
        "manager.erasure-ledger.username", () -> System.getenv("LEDGER_STORE_TEST_USERNAME"));
    properties.add(
        "manager.erasure-ledger.password", () -> System.getenv("LEDGER_STORE_TEST_PASSWORD"));
    properties.add("manager.erasure-ledger.id", () -> LEDGER_ID);
  }

  @BeforeEach
  void fixture() {
    var source =
        new DriverManagerDataSource(
            url("LEDGER_STORE_TEST"),
            System.getenv("LEDGER_STORE_TEST_USERNAME"),
            System.getenv("LEDGER_STORE_TEST_PASSWORD"));
    ledgerDb = new JdbcTemplate(source);
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_ledger_entries");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_ledger_head");
    ErasureLedgerBootstrap.initialize(source, LEDGER_ID);
    tenant = UUID.randomUUID().toString();
    subject = UUID.randomUUID().toString();
    owner = "ledger-" + UUID.randomUUID();
    business.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'runtime"
            + " fixture','FAMILY','UTC',?)",
        tenant,
        System.currentTimeMillis());
    business.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'OWNER')",
        tenant,
        owner,
        ActorKeys.key(owner));
    business.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'private"
            + " fixture','AGE_7_12',?)",
        tenant,
        subject,
        System.currentTimeMillis());
    path = "/api/v1/tenants/" + tenant + "/subjects/" + subject + "/erasure-preflight";
  }

  String inspect() throws Exception {
    return mvc.perform(
            get(path)
                .with(
                    jwt()
                        .jwt(
                            j ->
                                j.subject(owner)
                                    .claim("auth_time", Instant.now().getEpochSecond())
                                    .claim("amr", List.of("pwd", "otp")))))
        .andExpect(status().isOk())
        .andExpect(jsonPath("executionAvailable").value(false))
        .andReturn()
        .getResponse()
        .getContentAsString();
  }

  @Test
  void configuredIndependentLedgerAndPendingRecoveryReachTheAuthorizedPreflight() throws Exception {
    String empty = inspect();
    assertFalse(empty.contains("ERASURE_LEDGER_NOT_CONFIGURED"));
    assertFalse(empty.contains("ERASURE_LEDGER_RECONCILIATION_REQUIRED"));
    String hash = "c".repeat(64);
    ledger.append(
        new ErasureLedger.Request(
            UUID.randomUUID().toString(),
            tenant,
            subject,
            ActorKeys.key(owner),
            hash,
            hash,
            List.of()));
    String pending = inspect();
    assertTrue(pending.contains("ERASURE_LEDGER_RECONCILIATION_REQUIRED"));
    assertFalse(pending.contains(LEDGER_ID));
    assertFalse(pending.contains(hash));
    assertEquals(
        1,
        business.queryForObject(
            "SELECT COUNT(*) FROM subjects WHERE tenant_id=? AND id=?",
            Integer.class,
            tenant,
            subject));
  }

  @Test
  void mismatchedIdentityAndMissingLedgerAreReportedWithoutAutomaticRecreation() throws Exception {
    ledgerDb.update("UPDATE erasure_ledger_head SET ledger_id=?", UUID.randomUUID().toString());
    assertTrue(inspect().contains("ERASURE_LEDGER_IDENTITY_MISMATCH"));
    ledgerDb.execute("DROP TABLE erasure_ledger_entries");
    ledgerDb.execute("DROP TABLE erasure_ledger_head");
    assertTrue(inspect().contains("ERASURE_LEDGER_SCHEMA_INVALID"));
    assertEquals(
        0,
        ledgerDb.queryForObject(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()",
            Integer.class));
  }
}

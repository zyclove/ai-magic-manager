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
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "manager.exports.worker.enabled=false",
      "manager.report-jobs.worker.enabled=false",
      "manager.diagnostic-packages.worker.enabled=false",
      "manager.erasure-previews.cleanup.enabled=false"
    })
@AutoConfigureMockMvc
@org.springframework.context.annotation.Import(ErasureLedgerRuntimeTest.HttpFixture.class)
@EnabledIfEnvironmentVariable(named = "LEDGER_STORE_TEST_URL", matches = "jdbc:mysql:.*")
class ErasureLedgerRuntimeTest {
  private static final String LEDGER_ID = UUID.randomUUID().toString();
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate business;
  @Autowired ErasureLedger ledger;
  @org.springframework.boot.test.web.server.LocalServerPort int port;

  @org.springframework.test.context.bean.override.mockito.MockitoBean
  org.springframework.security.oauth2.jwt.JwtDecoder decoder;

  static volatile java.util.concurrent.CountDownLatch entered, finish;
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
    entered = new java.util.concurrent.CountDownLatch(1);
    finish = new java.util.concurrent.CountDownLatch(1);
    var source =
        new DriverManagerDataSource(
            url("LEDGER_STORE_TEST"),
            System.getenv("LEDGER_STORE_TEST_USERNAME"),
            System.getenv("LEDGER_STORE_TEST_PASSWORD"));
    ledgerDb = new JdbcTemplate(source);
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_work_admissions");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_admission_pause");
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
    org.mockito.Mockito.when(decoder.decode("fixture"))
        .thenReturn(
            org.springframework.security.oauth2.jwt.Jwt.withTokenValue("fixture")
                .header("alg", "RS256")
                .subject(owner)
                .issuedAt(Instant.now().minusSeconds(10))
                .expiresAt(Instant.now().plusSeconds(120))
                .claim("auth_time", Instant.now().getEpochSecond())
                .claim("amr", List.of("pwd", "otp"))
                .build());
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
  void acceptedLedgerStopsAuthorizedBusinessRequestsWithoutDeletingTheirData() throws Exception {
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
    String pending = blocked();
    assertTrue(pending.contains("ERASURE_MAINTENANCE_REQUIRED"));
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
    assertTrue(blocked().contains("ERASURE_MAINTENANCE_REQUIRED"));
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_work_admissions");
    ledgerDb.execute("DROP TABLE IF EXISTS erasure_admission_pause");
    ledgerDb.execute("DROP TABLE erasure_ledger_entries");
    ledgerDb.execute("DROP TABLE erasure_ledger_head");
    assertTrue(blocked().contains("ERASURE_MAINTENANCE_REQUIRED"));
    assertEquals(
        0,
        ledgerDb.queryForObject(
            "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE()",
            Integer.class));
  }

  String blocked() throws Exception {
    return mvc.perform(get(path).with(jwt().jwt(j -> j.subject(owner))))
        .andExpect(status().isServiceUnavailable())
        .andExpect(header().string("Cache-Control", "no-store"))
        .andReturn()
        .getResponse()
        .getContentAsString();
  }

  java.net.http.HttpRequest http(String route) {
    return java.net.http.HttpRequest.newBuilder(
            java.net.URI.create("http://127.0.0.1:" + port + route))
        .timeout(java.time.Duration.ofSeconds(15))
        .header("Authorization", "Bearer fixture")
        .GET()
        .build();
  }

  @Test
  void realHttpRequestDrainsBeforeAcceptanceAndProbesRemainAvailable() throws Exception {
    var client = java.net.http.HttpClient.newHttpClient();
    var running =
        client.sendAsync(
            http("/api/v1/admission-probe"), java.net.http.HttpResponse.BodyHandlers.ofString());
    try {
      assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS));
      String hash = "c".repeat(64);
      var request =
          new ErasureLedger.Request(
              UUID.randomUUID().toString(),
              tenant,
              subject,
              ActorKeys.key(owner),
              hash,
              hash,
              List.of());
      assertEquals(
          "ERASURE_LEDGER_WORK_ACTIVE",
          assertThrows(ErasureLedger.Failure.class, () -> ledger.append(request)).code());
      assertEquals(0, ledger.head().sequence());
      var blocked = client.send(http(path), java.net.http.HttpResponse.BodyHandlers.ofString());
      assertEquals(503, blocked.statusCode());
      assertEquals("no-store", blocked.headers().firstValue("Cache-Control").orElseThrow());
      assertEquals(
          200,
          client
              .send(
                  http("/actuator/health/liveness"),
                  java.net.http.HttpResponse.BodyHandlers.ofString())
              .statusCode());
      assertEquals(
          503,
          client
              .send(
                  http("/actuator/health/readiness"),
                  java.net.http.HttpResponse.BodyHandlers.ofString())
              .statusCode());
      finish.countDown();
      assertEquals(200, running.get(10, java.util.concurrent.TimeUnit.SECONDS).statusCode());
      assertEquals(1, ledger.append(request).sequence());
      assertEquals(
          503,
          client
              .send(
                  http("/api/v1/admission-probe"),
                  java.net.http.HttpResponse.BodyHandlers.ofString())
              .statusCode());
    } finally {
      finish.countDown();
      running.get(15, java.util.concurrent.TimeUnit.SECONDS);
    }
  }

  @Test
  void servletAsyncCannotEscapeTheRegisteredSynchronousPermit() throws Exception {
    var response =
        java.net.http.HttpClient.newHttpClient()
            .send(
                http("/api/v1/admission-async"),
                java.net.http.HttpResponse.BodyHandlers.ofString());
    assertEquals(500, response.statusCode());
    assertEquals(
        0, ledgerDb.queryForObject("SELECT COUNT(*) FROM erasure_work_admissions", Integer.class));
  }

  @org.springframework.boot.test.context.TestConfiguration(proxyBeanMethods = false)
  static class HttpFixture {
    @org.springframework.context.annotation.Bean
    ProbeController probeController() {
      return new ProbeController();
    }

    @org.springframework.context.annotation.Bean
    static org.springframework.beans.factory.config.BeanFactoryPostProcessor
        disableAutomaticSchedules() {
      // Deterministic HTTP/ledger fixtures. Scheduling and async advice have separate real-proxy
      // tests.
      return factory -> {
        var registry = (org.springframework.beans.factory.support.BeanDefinitionRegistry) factory;
        String name = "org.springframework.context.annotation.internalScheduledAnnotationProcessor";
        if (registry.containsBeanDefinition(name)) registry.removeBeanDefinition(name);
      };
    }
  }

  @org.springframework.web.bind.annotation.RestController
  static class ProbeController {
    @org.springframework.web.bind.annotation.GetMapping("/api/v1/admission-probe")
    Map<String, String> waitForRelease() throws InterruptedException {
      entered.countDown();
      if (!finish.await(15, java.util.concurrent.TimeUnit.SECONDS))
        throw new IllegalStateException("Fixture timeout");
      return Map.of("value", "synthetic response");
    }

    @org.springframework.web.bind.annotation.GetMapping("/api/v1/admission-async")
    void async(jakarta.servlet.http.HttpServletRequest request) {
      request.startAsync();
    }
  }
}

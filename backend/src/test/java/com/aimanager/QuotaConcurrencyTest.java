package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.fleet.DeviceAccess;
import com.aimanager.quota.QuotaExecutionSupport;
import com.aimanager.shared.*;
import com.aimanager.subject.SubjectAccess;
import com.fasterxml.jackson.databind.*;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.ECDSAVerifier;
import com.nimbusds.jose.jwk.*;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.*;
import org.springframework.context.annotation.*;
import org.springframework.http.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.test.context.*;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Real SQL, transactions, opaque credentials and Nimbus signatures. Execution certification alone
 * is a test double.
 */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${QUOTA_TEST_DATABASE_URL:jdbc:h2:mem:quota-concurrency;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${QUOTA_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${QUOTA_TEST_DATABASE_PASSWORD:}",
      "manager.quota.materialization-job.enabled=false",
      "manager.approval.expiry-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc
@Import(QuotaConcurrencyTest.TimeConfig.class)
class QuotaConcurrencyTest {
  @Autowired DeviceAccess fleet;
  @Autowired PlatformTransactionManager transactions;
  @MockitoSpyBean SubjectAccess subjects;

  @Test
  void applicationPoolCannotOmitPreviouslyIssuedReservations() throws Exception {
    var s = scope();
    pool(s, 600, false);
    var input = request(s, 300);
    var lease = json(reserve(s.first(), input).andExpect(status().isCreated()).andReturn());
    var body =
        Map.of(
            "name",
            "应用额度",
            "subjectId",
            s.subject(),
            "scope",
            "APPLICATION",
            "applicationId",
            s.application(),
            "periodId",
            LocalDate.now(clock).toString(),
            "timeZone",
            "UTC",
            "limitSeconds",
            120);
    for (boolean finalized : List.of(false, true)) {
      if (finalized) {
        clock.set(clock.instant().plusSeconds(60));
        settle(s.first(), lease, 1, 60, true, input.get("bootId").toString())
            .andExpect(status().isOk());
      }
      mvc.perform(
              post(path(s))
                  .with(actor(s.owner()))
                  .header("Idempotency-Key", UUID.randomUUID())
                  .contentType(APPLICATION_JSON)
                  .content(mapper.writeValueAsString(body)))
          .andExpect(status().isConflict())
          .andExpect(jsonPath("$.errorCode").value("QUOTA_SCOPE_ALREADY_USED"));
    }
    clock.set(clock.instant().plusSeconds(86400));
    pool(s, 120, true);
  }

  @Test
  void quotaAndAccessWindowLifecycleLocksUseTheSameOrder() throws Exception {
    var s = scope();
    pool(s, 600, false);
    var subjectAttempt = new CountDownLatch(1);
    SubjectAccess subjectTarget =
        org.springframework.test.util.AopTestUtils.getUltimateTargetObject(subjects);
    doAnswer(
            call -> {
              subjectAttempt.countDown();
              return call.callRealMethod();
            })
        .when(subjectTarget)
        .lockForDevice(s.tenant(), s.subject());
    var executor = Executors.newSingleThreadExecutor();
    var result = new AtomicReference<Future<MvcResult>>();
    var transaction = new TransactionTemplate(transactions);
    transaction.setTimeout(5);
    try {
      transaction.executeWithoutResult(
          status -> {
            // The exact public lifecycle boundaries used by PolicyExceptionAccess.accessWindow.
            subjects.lockActiveForScope(s.tenant(), s.owner(), s.subject());
            result.set(executor.submit(() -> reserve(s.first(), request(s, 120)).andReturn()));
            try {
              assertThat(subjectAttempt.await(5, TimeUnit.SECONDS)).isTrue();
            } catch (InterruptedException e) {
              Thread.currentThread().interrupt();
              throw new IllegalStateException(e);
            }
            fleet.lockVisibleActive(s.tenant(), s.owner(), s.first().id());
          });
      assertThat(result.get().get(15, TimeUnit.SECONDS).getResponse().getStatus()).isEqualTo(201);
    } finally {
      executor.shutdownNow();
    }
  }

  static final ECKey KEY;
  static final Path KEY_FILE;

  static {
    try {
      KEY = new ECKeyGenerator(Curve.P_256).keyID("quota-test").generate();
      Path dir = Path.of(".local").toAbsolutePath();
      Files.createDirectories(dir);
      KEY_FILE = Files.createTempFile(dir, "quota-signing-", ".jwk");
      Files.writeString(KEY_FILE, KEY.toJSONString());
    } catch (Exception e) {
      throw new IllegalStateException("Test signing fixture failed");
    }
  }

  @DynamicPropertySource
  static void properties(DynamicPropertyRegistry r) {
    r.add("manager.delivery.signing-key-file", () -> KEY_FILE.toString());
  }

  @AfterAll
  static void cleanKey() throws Exception {
    Files.deleteIfExists(KEY_FILE);
  }

  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper mapper;
  @Autowired MutableClock clock;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean QuotaExecutionSupport execution;

  @BeforeEach
  void setup() {
    clock.set(Instant.parse("2026-10-09T02:00:00Z"));
    doThrow(new BadJwtException("Test non-user credential")).when(decoder).decode(anyString());
  }

  RequestPostProcessor actor(String id) {
    return jwt()
        .jwt(
            t ->
                t.subject(id)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  JsonNode json(MvcResult r) throws Exception {
    return mapper.readTree(r.getResponse().getContentAsString());
  }

  Scope scope() throws Exception {
    String owner = "quota-" + UUID.randomUUID();
    String tenant =
        json(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(APPLICATION_JSON)
                        .content("{\"name\":\"并发额度\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
                .andExpect(status().isCreated())
                .andReturn())
            .get("id")
            .asText();
    String subject =
        json(mvc.perform(
                    post("/api/v1/tenants/" + tenant + "/subjects")
                        .with(actor(owner))
                        .contentType(APPLICATION_JSON)
                        .content("{\"nickname\":\"孩子\",\"ageBand\":\"AGE_7_12\"}"))
                .andExpect(status().isCreated())
                .andReturn())
            .get("id")
            .asText();
    String app =
        json(mvc.perform(
                    post("/api/v1/tenants/" + tenant + "/applications")
                        .with(actor(owner))
                        .contentType(APPLICATION_JSON)
                        .content(
                            "{\"displayName\":\"学习\",\"platform\":\"ANDROID\",\"packageName\":\"org.example.study\",\"profile\":\"PRIMARY\",\"signingDigests\":[]}"))
                .andExpect(status().isCreated())
                .andReturn())
            .get("id")
            .asText();
    return new Scope(owner, tenant, subject, app, device(tenant, subject), device(tenant, subject));
  }

  Agent device(String tenant, String subject) {
    String id = UUID.randomUUID().toString(),
        registration = UUID.randomUUID().toString(),
        token = SecretMaterial.token();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        id,
        subject,
        registration,
        "测试设备",
        clock.millis());
    db.update(
        "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
            + " VALUES(?,?,?,TRUE)",
        tenant,
        registration,
        id);
    db.update(
        "INSERT INTO"
            + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
            + " VALUES(?,?,?,?,?,TRUE,?,?)",
        UUID.randomUUID().toString(),
        tenant,
        id,
        registration,
        SecretMaterial.hash(token),
        clock.millis(),
        clock.millis() + 7 * 86400000L);
    return new Agent(id, registration, token);
  }

  String path(Scope s) {
    return "/api/v1/tenants/" + s.tenant() + "/quota-pools";
  }

  JsonNode pool(Scope s, long seconds, boolean app) throws Exception {
    var input = new LinkedHashMap<String, Object>();
    input.put("name", app ? "应用额度" : "每日额度");
    input.put("subjectId", s.subject());
    input.put("scope", app ? "APPLICATION" : "TOTAL");
    if (app) input.put("applicationId", s.application());
    input.put("periodId", LocalDate.now(clock).toString());
    input.put("timeZone", "UTC");
    input.put("limitSeconds", seconds);
    return json(
        mvc.perform(
                post(path(s))
                    .with(actor(s.owner()))
                    .header("Idempotency-Key", UUID.randomUUID())
                    .contentType(APPLICATION_JSON)
                    .content(mapper.writeValueAsString(input)))
            .andExpect(status().isCreated())
            .andReturn());
  }

  Map<String, Object> request(Scope s, long seconds) {
    return Map.of(
        "requestId",
        UUID.randomUUID().toString(),
        "applicationId",
        s.application(),
        "bootId",
        UUID.randomUUID().toString(),
        "sessionId",
        UUID.randomUUID().toString(),
        "startTickMillis",
        1000,
        "requestedSeconds",
        seconds);
  }

  ResultActions reserve(Agent a, Map<String, Object> in) throws Exception {
    return mvc.perform(
        post("/api/v1/device-api/quota-leases")
            .header("Authorization", "Bearer " + a.token())
            .contentType(APPLICATION_JSON)
            .content(mapper.writeValueAsString(in)));
  }

  ResultActions settle(
      Agent a, JsonNode lease, long sequence, long used, boolean finished, String boot)
      throws Exception {
    return mvc.perform(
        post("/api/v1/device-api/quota-leases/" + lease.get("id").asText() + "/settlements")
            .header("Authorization", "Bearer " + a.token())
            .contentType(APPLICATION_JSON)
            .content(
                mapper.writeValueAsString(
                    Map.of(
                        "bootId",
                        boot,
                        "sequence",
                        sequence,
                        "cumulativeUsedSeconds",
                        used,
                        "elapsedRealtimeMillis",
                        1000 + used * 1000,
                        "finished",
                        finished))));
  }

  JsonNode readPool(Scope s, JsonNode pool) throws Exception {
    return json(
        mvc.perform(get(path(s) + "/" + pool.get("id").asText()).with(actor(s.owner())))
            .andExpect(status().isOk())
            .andReturn());
  }

  @Test
  void parallelDevicesCannotReserveMoreThanOneSharedBalance() throws Exception {
    var s = scope();
    var p = pool(s, 600, false);
    var executor = Executors.newFixedThreadPool(8);
    try {
      var jobs = new ArrayList<Future<MvcResult>>();
      for (int i = 0; i < 8; i++) {
        var a = i % 2 == 0 ? s.first() : s.second();
        var in = request(s, 200);
        jobs.add(executor.submit(() -> reserve(a, in).andReturn()));
      }
      long allocated = 0;
      int rejected = 0;
      for (var f : jobs) {
        var r = f.get(15, TimeUnit.SECONDS);
        if (r.getResponse().getStatus() == 201)
          allocated += json(r).get("reservedSeconds").asLong();
        else {
          assertThat(r.getResponse().getStatus()).isEqualTo(409);
          assertThat(json(r).get("errorCode").asText()).isEqualTo("QUOTA_EXHAUSTED");
          rejected++;
        }
      }
      assertThat(allocated).isEqualTo(600);
      assertThat(rejected).isEqualTo(5);
    } finally {
      executor.shutdownNow();
    }
    var result = readPool(s, p);
    assertThat(result.get("reservedSeconds").asLong()).isEqualTo(600);
    assertThat(result.get("availableSeconds").asLong()).isZero();
  }

  @Test
  void totalAndApplicationLimitsAreReservedTogetherAndCumulativeReportsDeduplicate()
      throws Exception {
    var s = scope();
    var total = pool(s, 600, false);
    var app = pool(s, 120, true);
    var in = request(s, 300);
    var lease = json(reserve(s.first(), in).andExpect(status().isCreated()).andReturn());
    assertThat(lease.get("reservedSeconds").asLong()).isEqualTo(120);
    assertThat(json(reserve(s.first(), in).andExpect(status().isCreated()).andReturn()))
        .isEqualTo(lease);
    var jws = JWSObject.parse(lease.get("signedLease").asText());
    assertThat(jws.verify(new ECDSAVerifier(KEY.toPublicJWK()))).isTrue();
    assertThat(jws.getHeader().getType().toString()).isEqualTo("aimanager-quota-lease+jws");
    var payload = mapper.readTree(jws.getPayload().toString());
    assertThat(payload.get("pools").size()).isEqualTo(2);
    assertThat(payload.get("registrationId").asText()).isEqualTo(s.first().registration());
    clock.set(clock.instant().plusSeconds(60));
    String boot = in.get("bootId").toString();
    var first =
        json(settle(s.first(), lease, 1, 60, false, boot).andExpect(status().isOk()).andReturn());
    assertThat(
            json(
                settle(s.first(), lease, 1, 60, false, boot)
                    .andExpect(status().isOk())
                    .andReturn()))
        .isEqualTo(first);
    settle(s.first(), lease, 1, 61, false, boot).andExpect(status().isConflict());
    settle(s.first(), lease, 2, 60, true, boot)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("FINALIZED"));
    settle(s.first(), lease, 1, 60, false, boot).andExpect(status().isConflict());
    for (var p : List.of(total, app)) {
      var current = readPool(s, p);
      assertThat(current.get("usedSeconds").asLong()).isEqualTo(60);
      assertThat(current.get("reservedSeconds").asLong()).isZero();
    }
    assertThat(readPool(s, app).get("availableSeconds").asLong()).isEqualTo(60);
  }

  @Test
  void expiryAndRestartNeverRefundUnknownConsumptionAndLateSettlementStaysInOldPeriod()
      throws Exception {
    var s = scope();
    var old = pool(s, 600, false);
    var in = request(s, 300);
    var lease = json(reserve(s.first(), in).andExpect(status().isCreated()).andReturn());
    clock.set(clock.instant().plusSeconds(86400));
    var today = pool(s, 600, false);
    var replay = json(reserve(s.first(), in).andExpect(status().isCreated()).andReturn());
    assertThat(replay.get("notAfter")).isEqualTo(lease.get("notAfter"));
    assertThat(replay.get("state").asText()).isEqualTo("AWAITING_RECONCILIATION");
    assertThat(readPool(s, old).get("reservedSeconds").asLong()).isEqualTo(300);
    assertThat(readPool(s, today).get("availableSeconds").asLong()).isEqualTo(600);
    settle(s.first(), lease, 1, 80, true, UUID.randomUUID().toString())
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("QUOTA_BOOT_CHANGED"));
    settle(s.first(), lease, 1, 80, true, in.get("bootId").toString()).andExpect(status().isOk());
    assertThat(readPool(s, old).get("usedSeconds").asLong()).isEqualTo(80);
    assertThat(readPool(s, today).get("availableSeconds").asLong()).isEqualTo(600);
  }

  @Test
  void identityAndUnverifiedExecutionCannotGrantOrSettleOtherDevices() throws Exception {
    var s = scope();
    pool(s, 600, false);
    var in = request(s, 120);
    doThrow(new DomainException(HttpStatus.CONFLICT, "QUOTA_EXECUTION_UNVERIFIED"))
        .when(execution)
        .requireVerified(any(), anyString());
    reserve(s.first(), in)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("QUOTA_EXECUTION_UNVERIFIED"));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_leases WHERE tenant_id=?", Integer.class, s.tenant()))
        .isZero();
    doNothing().when(execution).requireVerified(any(), anyString());
    var lease = json(reserve(s.first(), in).andExpect(status().isCreated()).andReturn());
    settle(s.second(), lease, 1, 0, true, in.get("bootId").toString())
        .andExpect(status().isForbidden());
    db.update(
        "UPDATE device_credentials SET revoked_at=? WHERE tenant_id=? AND device_id=?",
        clock.millis(),
        s.tenant(),
        s.first().id());
    settle(s.first(), lease, 1, 0, true, in.get("bootId").toString())
        .andExpect(status().isUnauthorized());
  }

  @Test
  void decreasedLimitsCannotSpendReservationsAndChangedRequestCannotAllocateTwice()
      throws Exception {
    var s = scope();
    var p = pool(s, 600, false);
    var in = request(s, 300);
    reserve(s.first(), in).andExpect(status().isCreated());
    var changed = new LinkedHashMap<>(in);
    changed.put("requestedSeconds", 200);
    reserve(s.first(), changed)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    mvc.perform(
            post(path(s) + "/" + p.get("id").asText() + "/adjustments")
                .with(actor(s.owner()))
                .header("Idempotency-Key", "decrease")
                .header("If-Match", "\"1\"")
                .contentType(APPLICATION_JSON)
                .content("{\"deltaSeconds\":-400,\"reason\":\"CORRECTION\"}"))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("QUOTA_BALANCE_CONFLICT"));
    assertThat(readPool(s, p).get("limitSeconds").asLong()).isEqualTo(600);
  }

  @Test
  void monotonicProgressCannotGoBackwardsOrConsumeFasterThanServerElapsedTime() throws Exception {
    var s = scope();
    pool(s, 600, false);
    var in = request(s, 300);
    var lease = json(reserve(s.first(), in).andExpect(status().isCreated()).andReturn());
    settle(s.first(), lease, 1, 100, false, in.get("bootId").toString())
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("QUOTA_COUNTER_INVALID"));
    clock.set(clock.instant().plusSeconds(120));
    settle(s.first(), lease, 1, 100, false, in.get("bootId").toString()).andExpect(status().isOk());
    settle(s.first(), lease, 2, 90, false, in.get("bootId").toString())
        .andExpect(status().isConflict());
  }

  @Test
  void databaseFailureRollsBackAllocationsLedgerAndOutbox() throws Exception {
    var s = scope();
    var p = pool(s, 600, false);
    String constraint = "quota_test_failure";
    db.execute(
        "ALTER TABLE quota_outbox ADD CONSTRAINT "
            + constraint
            + " CHECK(tenant_id <> '"
            + s.tenant()
            + "' OR event_type <> 'QUOTA_RESERVED')");
    try {
      reserve(s.first(), request(s, 100)).andExpect(status().is5xxServerError());
    } finally {
      db.execute("ALTER TABLE quota_outbox DROP CONSTRAINT " + constraint);
    }
    assertThat(readPool(s, p).get("reservedSeconds").asLong()).isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_leases WHERE tenant_id=?", Integer.class, s.tenant()))
        .isZero();
  }

  @Test
  void aNewDayReservationMaterializesBothPlansBeforeIntersectingBalances() throws Exception {
    var s = scope();
    var weekly = new LinkedHashMap<String, Long>();
    for (var day : DayOfWeek.values()) weekly.put(day.name(), 600L);
    for (boolean app : List.of(false, true)) {
      var input = new LinkedHashMap<String, Object>();
      input.put("name", app ? "自动应用" : "自动总额");
      input.put("subjectId", s.subject());
      input.put("scope", app ? "APPLICATION" : "TOTAL");
      if (app) input.put("applicationId", s.application());
      input.put("timeZone", "UTC");
      input.put("effectiveFrom", "2026-10-10");
      input.put("weeklyLimits", weekly);
      input.put("dateOverrides", Map.of("2026-10-10", app ? 120 : 600));
      mvc.perform(
              post("/api/v1/tenants/" + s.tenant() + "/quota-plans")
                  .with(actor(s.owner()))
                  .header("Idempotency-Key", UUID.randomUUID())
                  .contentType(APPLICATION_JSON)
                  .content(mapper.writeValueAsString(input)))
          .andExpect(status().isCreated());
    }
    clock.set(clock.instant().plusSeconds(86400));
    var lease =
        json(reserve(s.first(), request(s, 300)).andExpect(status().isCreated()).andReturn());
    assertThat(lease.get("reservedSeconds").asLong()).isEqualTo(120);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_pools WHERE tenant_id=? AND reserved_seconds=120 AND"
                    + " plan_version=0",
                Integer.class,
                s.tenant()))
        .isEqualTo(2);
  }

  record Agent(String id, String registration, String token) {}

  record Scope(
      String owner, String tenant, String subject, String application, Agent first, Agent second) {}

  static class MutableClock extends Clock {
    private final AtomicReference<Instant> now = new AtomicReference<>();

    void set(Instant value) {
      now.set(value);
    }

    @Override
    public Instant instant() {
      return now.get();
    }

    @Override
    public ZoneId getZone() {
      return ZoneOffset.UTC;
    }

    @Override
    public Clock withZone(ZoneId zone) {
      return Clock.fixed(instant(), zone);
    }
  }

  @TestConfiguration
  static class TimeConfig {
    @Bean
    @Primary
    MutableClock quotaClock() {
      var clock = new MutableClock();
      clock.set(Instant.parse("2026-10-09T02:00:00Z"));
      return clock;
    }
  }
}

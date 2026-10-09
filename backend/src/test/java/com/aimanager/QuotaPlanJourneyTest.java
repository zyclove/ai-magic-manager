package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.http.MediaType.APPLICATION_JSON;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.aimanager.quota.QuotaPlanMaintenance;
import com.fasterxml.jackson.databind.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.*;
import org.springframework.context.annotation.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(
    properties = {
      "spring.datasource.url=${QUOTA_PLAN_TEST_DATABASE_URL:jdbc:h2:mem:quota-plans;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${QUOTA_PLAN_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${QUOTA_PLAN_TEST_DATABASE_PASSWORD:}",
      "manager.quota.materialization-job.enabled=false",
      "manager.approval.expiry-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc
@Import(QuotaPlanJourneyTest.TimeConfig.class)
class QuotaPlanJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @Autowired PlanClock clock;
  @Autowired QuotaPlanMaintenance maintenance;
  @MockitoBean JwtDecoder decoder;

  @BeforeEach
  void resetClock() {
    clock.set(Instant.parse("2026-10-09T02:00:00Z"));
  }

  @Test
  void calendarPreviewUsesTheSubjectsExistingZoneAndProtectsItsScope() throws Exception {
    var s = scope();
    var in = input(s);
    in.put("timeZone", "America/Los_Angeles");
    in.put("effectiveFrom", "2026-10-08");
    in.put("dateOverrides", Map.of());
    create(s, in, "create").andExpect(status().isCreated());
    mvc.perform(
            get(root(s) + "/quota-plans/calendar")
                .with(actor(s.child()))
                .param("subjectId", s.subject())
                .param("defaultTimeZone", "Asia/Shanghai"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.timeZone").value("America/Los_Angeles"))
        .andExpect(jsonPath("$.currentDate").value("2026-10-08"));
    mvc.perform(
            get(root(s) + "/quota-plans/calendar")
                .with(actor(s.child()))
                .param("subjectId", UUID.randomUUID().toString())
                .param("defaultTimeZone", "UTC"))
        .andExpect(status().isForbidden());
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

  JsonNode json(MvcResult result) throws Exception {
    return mapper.readTree(result.getResponse().getContentAsString());
  }

  Scope scope() throws Exception {
    String owner = "plan-" + UUID.randomUUID(), child = "child-" + UUID.randomUUID();
    String tenant =
        json(mvc.perform(
                    post("/api/v1/tenants")
                        .with(actor(owner))
                        .contentType(APPLICATION_JSON)
                        .content("{\"name\":\"重复额度验收\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
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
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        tenant,
        child,
        ActorKeys.key(child),
        subject);
    return new Scope(owner, child, tenant, subject);
  }

  String root(Scope s) {
    return "/api/v1/tenants/" + s.tenant();
  }

  Map<String, Long> weekly(long seconds) {
    var result = new LinkedHashMap<String, Long>();
    for (var day : DayOfWeek.values()) result.put(day.name(), seconds);
    return result;
  }

  Map<String, Object> input(Scope s) {
    var in = new LinkedHashMap<String, Object>();
    in.put("subjectId", s.subject());
    in.put("name", "平日与周末");
    in.put("scope", "TOTAL");
    in.put("timeZone", "UTC");
    in.put("effectiveFrom", "2026-10-09");
    in.put("weeklyLimits", weekly(3600));
    in.put("dateOverrides", Map.of("2026-10-09", 1200L));
    return in;
  }

  ResultActions create(Scope s, Map<String, Object> in, String key) throws Exception {
    return mvc.perform(
        post(root(s) + "/quota-plans")
            .with(actor(s.owner()))
            .header("Idempotency-Key", key)
            .contentType(APPLICATION_JSON)
            .content(mapper.writeValueAsString(in)));
  }

  @Test
  void plansCreateOneDailySnapshotAndReplayWithoutDuplicatingLedger() throws Exception {
    var s = scope();
    var in = input(s);
    var plan =
        json(
            create(s, in, "create")
                .andExpect(status().isCreated())
                .andExpect(header().string("ETag", "\"0\""))
                .andReturn());
    assertThat(json(create(s, in, "create").andExpect(status().isCreated()).andReturn()))
        .isEqualTo(plan);
    var pools =
        json(mvc.perform(get(root(s) + "/quota-pools").with(actor(s.owner())))
                .andExpect(status().isOk())
                .andReturn())
            .get("items");
    assertThat(pools.size()).isEqualTo(1);
    assertThat(pools.get(0).get("limitSeconds").asLong()).isEqualTo(1200);
    assertThat(pools.get(0).get("planId").asText()).isEqualTo(plan.get("id").asText());
    assertThat(pools.get(0).get("planVersion").asLong()).isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_ledger WHERE tenant_id=?", Integer.class, s.tenant()))
        .isEqualTo(1);
  }

  @Test
  void planWritesRequireAdultMfaAndVersionWhileChildReadsOnlyOwnScope() throws Exception {
    var s = scope();
    var in = input(s);
    mvc.perform(
            post(root(s) + "/quota-plans")
                .with(jwt().jwt(t -> t.subject(s.owner())))
                .header("Idempotency-Key", "weak")
                .contentType(APPLICATION_JSON)
                .content(mapper.writeValueAsString(in)))
        .andExpect(status().isUnauthorized());
    mvc.perform(
            post(root(s) + "/quota-plans")
                .with(actor(s.child()))
                .header("Idempotency-Key", "child")
                .contentType(APPLICATION_JSON)
                .content(mapper.writeValueAsString(in)))
        .andExpect(status().isForbidden());
    var plan = json(create(s, in, "create").andExpect(status().isCreated()).andReturn());
    mvc.perform(get(root(s) + "/quota-plans").with(actor(s.child())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
    mvc.perform(get(root(s) + "/quota-plans/" + plan.get("id").asText()).with(actor("outsider")))
        .andExpect(status().isForbidden());
    String update =
        mapper.writeValueAsString(
            Map.of(
                "name",
                "调整后",
                "state",
                "ACTIVE",
                "weeklyLimits",
                weekly(600),
                "dateOverrides",
                Map.of()));
    String path = root(s) + "/quota-plans/" + plan.get("id").asText();
    mvc.perform(
            put(path)
                .with(actor(s.owner()))
                .header("Idempotency-Key", "missing")
                .contentType(APPLICATION_JSON)
                .content(update))
        .andExpect(status().isPreconditionRequired());
    mvc.perform(
            put(path)
                .with(actor(s.owner()))
                .header("Idempotency-Key", "edit")
                .header("If-Match", "\"0\"")
                .contentType(APPLICATION_JSON)
                .content(update))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.effectiveFrom").value("2026-10-10"))
        .andExpect(header().string("ETag", "\"1\""));
    mvc.perform(
            put(path)
                .with(actor(s.owner()))
                .header("Idempotency-Key", "stale")
                .header("If-Match", "\"0\"")
                .contentType(APPLICATION_JSON)
                .content(update))
        .andExpect(status().isPreconditionFailed());
    assertThat(
            db.queryForObject(
                "SELECT limit_seconds FROM quota_pools WHERE tenant_id=?", Long.class, s.tenant()))
        .isEqualTo(1200);
  }

  @Test
  void aManualDailyPoolIsNeverOverwrittenByAnAutomaticPlan() throws Exception {
    var s = scope();
    mvc.perform(
            post(root(s) + "/quota-pools")
                .with(actor(s.owner()))
                .header("Idempotency-Key", "manual")
                .contentType(APPLICATION_JSON)
                .content(
                    mapper.writeValueAsString(
                        Map.of(
                            "name",
                            "临时安排",
                            "subjectId",
                            s.subject(),
                            "scope",
                            "TOTAL",
                            "periodId",
                            "2026-10-09",
                            "timeZone",
                            "UTC",
                            "limitSeconds",
                            300))))
        .andExpect(status().isCreated());
    create(s, input(s), "plan").andExpect(status().isCreated());
    assertThat(
            db.queryForObject(
                "SELECT limit_seconds FROM quota_pools WHERE tenant_id=?", Long.class, s.tenant()))
        .isEqualTo(300);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_ledger WHERE tenant_id=?", Integer.class, s.tenant()))
        .isEqualTo(1);
  }

  @Test
  void changesAndPausesStartTomorrowAndHistoryKeepsEveryRevision() throws Exception {
    var s = scope();
    var plan = json(create(s, input(s), "create").andExpect(status().isCreated()).andReturn());
    String path = root(s) + "/quota-plans/" + plan.get("id").asText();
    var config =
        new LinkedHashMap<String, Object>(
            Map.of(
                "name",
                "次日安排",
                "state",
                "PAUSED",
                "weeklyLimits",
                weekly(600),
                "dateOverrides",
                Map.of()));
    mvc.perform(
            put(path)
                .with(actor(s.owner()))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "pause")
                .contentType(APPLICATION_JSON)
                .content(mapper.writeValueAsString(config)))
        .andExpect(status().isOk());
    clock.set(Instant.parse("2026-10-10T02:00:00Z"));
    maintenance.materializeDue(100);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_pools WHERE tenant_id=?", Integer.class, s.tenant()))
        .isEqualTo(1);
    config.put("state", "ACTIVE");
    mvc.perform(
            put(path)
                .with(actor(s.owner()))
                .header("If-Match", "\"1\"")
                .header("Idempotency-Key", "resume")
                .contentType(APPLICATION_JSON)
                .content(mapper.writeValueAsString(config)))
        .andExpect(status().isOk());
    clock.set(Instant.parse("2026-10-11T02:00:00Z"));
    maintenance.materializeDue(100);
    assertThat(
            db.queryForObject(
                "SELECT limit_seconds FROM quota_pools WHERE tenant_id=? AND"
                    + " period_id='2026-10-11'",
                Long.class,
                s.tenant()))
        .isEqualTo(600);
    assertThat(
            db.queryForObject(
                "SELECT plan_version FROM quota_pools WHERE tenant_id=? AND period_id='2026-10-11'",
                Long.class,
                s.tenant()))
        .isEqualTo(2);
    mvc.perform(get(path + "/revisions?limit=2").with(actor(s.child())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].version").value(2))
        .andExpect(jsonPath("$.nextCursor").value("1"));
    mvc.perform(get(path + "/revisions?limit=2&cursor=1").with(actor(s.child())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].version").value(0));
  }

  @Test
  void parallelWorkersAndDowntimeCreateOnlyOneCurrentDayWithoutBackfilling() throws Exception {
    var s = scope();
    create(s, input(s), "create").andExpect(status().isCreated());
    clock.set(Instant.parse("2026-10-12T02:00:00Z"));
    var executor = Executors.newFixedThreadPool(6);
    try {
      var futures = new ArrayList<Future<Integer>>();
      for (int i = 0; i < 6; i++)
        futures.add(executor.submit(() -> maintenance.materializeDue(100)));
      for (var f : futures) f.get(20, TimeUnit.SECONDS);
    } finally {
      executor.shutdownNow();
    }
    assertThat(
            db.queryForList(
                "SELECT period_id FROM quota_pools WHERE tenant_id=? ORDER BY period_id",
                String.class,
                s.tenant()))
        .containsExactly("2026-10-09", "2026-10-12");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_ledger WHERE tenant_id=?", Integer.class, s.tenant()))
        .isEqualTo(2);
    clock.set(Instant.parse("2026-10-09T04:00:00Z"));
    maintenance.materializeDue(100);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM quota_pools WHERE tenant_id=?", Integer.class, s.tenant()))
        .isEqualTo(2);
  }

  @Test
  void dailySnapshotsRespectDstAndDoNotAssumeTwentyFourHours() throws Exception {
    for (var sample : Map.of("2026-11-01T06:00:00Z", 25L, "2027-03-14T06:00:00Z", 23L).entrySet()) {
      clock.set(Instant.parse(sample.getKey()));
      var s = scope();
      var in = input(s);
      in.put("timeZone", "America/New_York");
      in.put(
          "effectiveFrom", LocalDate.now(clock.withZone(ZoneId.of("America/New_York"))).toString());
      in.put("dateOverrides", Map.of());
      create(s, in, "create").andExpect(status().isCreated());
      assertThat(
              db.queryForObject(
                  "SELECT period_end-period_start FROM quota_pools WHERE tenant_id=?",
                  Long.class,
                  s.tenant()))
          .isEqualTo(sample.getValue() * 3600000);
    }
  }

  @Test
  void invalidWeeklyValuesAndDuplicateScopesAreRejected() throws Exception {
    var s = scope();
    var in = input(s);
    in.put("weeklyLimits", Map.of("MONDAY", 600));
    create(s, in, "incomplete").andExpect(status().isBadRequest());
    in.put("weeklyLimits", weekly(-1));
    create(s, in, "negative").andExpect(status().isBadRequest());
    in.put("weeklyLimits", weekly(86401));
    create(s, in, "over").andExpect(status().isBadRequest());
    in = input(s);
    in.put("dateOverrides", Map.of("2026-02-30", 600));
    create(s, in, "date").andExpect(status().isBadRequest());
    create(s, input(s), "valid").andExpect(status().isCreated());
    create(s, input(s), "duplicate")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("QUOTA_PLAN_EXISTS"));
  }

  @Test
  void automaticPoolFailureRollsBackPlanRevisionAuditAndLedger() throws Exception {
    var s = scope();
    db.execute(
        "ALTER TABLE quota_outbox ADD CONSTRAINT quota_plan_failure CHECK(tenant_id <> '"
            + s.tenant()
            + "' OR event_type <> 'QUOTA_POOL_CREATED')");
    try {
      create(s, input(s), "failed").andExpect(status().is5xxServerError());
    } finally {
      db.execute("ALTER TABLE quota_outbox DROP CONSTRAINT quota_plan_failure");
    }
    for (String table :
        List.of(
            "quota_plans", "quota_plan_revisions", "quota_pools", "quota_ledger", "quota_outbox"))
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?",
                  Integer.class,
                  s.tenant()))
          .isZero();
  }

  record Scope(String owner, String child, String tenant, String subject) {}

  static class PlanClock extends Clock {
    private final AtomicReference<Instant> now = new AtomicReference<>();

    void set(Instant instant) {
      now.set(instant);
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
    PlanClock planClock() {
      var c = new PlanClock();
      c.set(Instant.parse("2026-10-09T02:00:00Z"));
      return c;
    }
  }
}

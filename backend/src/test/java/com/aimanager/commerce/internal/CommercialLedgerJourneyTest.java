package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.audit.AuditService;
import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.commerce.internal.CommercialFact.SourceSystem;
import com.aimanager.commerce.internal.CommercialFact.State;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Contract, duplicate, refund and authorization path using the real transaction and migration. */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${COMMERCIAL_TEST_DATABASE_URL:jdbc:h2:mem:commercial-ledger;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${COMMERCIAL_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${COMMERCIAL_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false"
    })
@AutoConfigureMockMvc
class CommercialLedgerJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate jdbc;
  @Autowired CommercialLedger ledger;
  @Autowired Clock clock;
  @MockitoBean JwtDecoder decoder;
  @MockitoSpyBean AuditService audit;

  private String tenant;
  private String owner;

  @BeforeEach
  void createTenant() throws Exception {
    owner = "commerce-owner-" + UUID.randomUUID();
    var response =
        mvc.perform(
                post("/api/v1/tenants")
                    .with(actor(owner))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content("{\"name\":\"Commercial\",\"kind\":\"FAMILY\",\"timeZone\":\"UTC\"}"))
            .andExpect(status().isCreated())
            .andReturn();
    tenant = json.readTree(response.getResponse().getContentAsString()).path("id").asText();
  }

  @Test
  void emptyAccountHasNoPaidRightsAndOnlyCurrentAdministratorsCanRead() throws Exception {
    mvc.perform(get(path()).with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(
            header().string("Cache-Control", org.hamcrest.Matchers.containsString("no-store")))
        .andExpect(jsonPath("$.paidDeviceCapacity").value(0))
        .andExpect(jsonPath("$.features.length()").value(0))
        .andExpect(jsonPath("$.technicalCapabilityIndependent").value(true));
    mvc.perform(get(path()).with(actor("stranger-" + UUID.randomUUID())))
        .andExpect(status().isForbidden());
    String teacher = "commerce-teacher-" + UUID.randomUUID();
    jdbc.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'TEACHER')",
        tenant,
        teacher,
        ActorKeys.key(teacher));
    mvc.perform(get(path()).with(actor(teacher))).andExpect(status().isForbidden());
  }

  @Test
  void verifiedSourcesMergeByBaseMaximumAndExplicitAddOnOnly() throws Exception {
    long now = clock.millis();
    var base =
        fact(
            "contract-A",
            1,
            CapacityKind.BASE,
            5,
            Set.of(Feature.ADVANCED_SCHEDULES),
            now - 1000,
            now + 86400000,
            State.ACTIVE);
    var smallerBase =
        fact(
            "contract-B",
            1,
            CapacityKind.BASE,
            3,
            Set.of(Feature.WEB_FILTERING),
            now - 1000,
            now + 86400000,
            State.ACTIVE);
    var addOn =
        fact(
            "seat-addon",
            1,
            CapacityKind.ADD_ON,
            2,
            Set.of(Feature.ORG_BULK),
            now - 1000,
            now + 86400000,
            State.ACTIVE);
    assertThat(ledger.apply(base).changed()).isTrue();
    ledger.apply(smallerBase);
    ledger.apply(addOn);
    mvc.perform(get(path()).with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.version").value(3))
        .andExpect(jsonPath("$.activeSourceCount").value(3))
        .andExpect(jsonPath("$.baseDeviceCapacity").value(5))
        .andExpect(jsonPath("$.addOnDeviceCapacity").value(2))
        .andExpect(jsonPath("$.paidDeviceCapacity").value(7))
        .andExpect(jsonPath("$.features.length()").value(3));
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isEqualTo(3);
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_sources WHERE source_key=?",
                Integer.class,
                "contract-A"))
        .isZero();
  }

  @Test
  void exactReplayIsIdempotentAndChangedOrStaleRevisionConflicts() {
    long now = clock.millis();
    var original =
        fact(
            "play-order-1",
            1,
            CapacityKind.BASE,
            4,
            Set.of(Feature.WEB_FILTERING),
            now - 1000,
            now + 86400000,
            State.ACTIVE);
    assertThat(ledger.apply(original).accountVersion()).isEqualTo(1);
    assertThat(ledger.apply(original).changed()).isFalse();
    assertThatThrownBy(
            () ->
                ledger.apply(
                    fact(
                        "play-order-1",
                        1,
                        CapacityKind.BASE,
                        9,
                        Set.of(Feature.WEB_FILTERING),
                        now - 1000,
                        now + 86400000,
                        State.ACTIVE)))
        .isInstanceOf(DomainException.class)
        .hasMessage("COMMERCIAL_SOURCE_REVISION_CONFLICT");
    assertThat(
            ledger
                .apply(
                    fact(
                        "play-order-1",
                        2,
                        CapacityKind.BASE,
                        4,
                        Set.of(Feature.WEB_FILTERING),
                        now - 1000,
                        now + 86400000,
                        State.REVOKED))
                .accountVersion())
        .isEqualTo(2);
    assertThatThrownBy(() -> ledger.apply(original)).isInstanceOf(DomainException.class);
    assertThat(ledger.read(tenant, owner).paidDeviceCapacity()).isZero();
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isEqualTo(2);
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='COMMERCIAL_FACT_ACCEPTED'",
                Integer.class,
                tenant))
        .isEqualTo(2);
    assertThat(
            jdbc.queryForObject(
                "SELECT DISTINCT verified_by FROM commercial_source_events WHERE tenant_id=?",
                String.class,
                tenant))
        .isEqualTo("system:contract-verifier");
    assertThat(
            jdbc.queryForObject(
                "SELECT DISTINCT actor_id FROM audit_events WHERE tenant_id=?"
                    + " AND action='COMMERCIAL_FACT_ACCEPTED'",
                String.class,
                tenant))
        .isEqualTo("system:contract-verifier");
  }

  @Test
  void expiredBaseCannotBeExtendedByAnActiveAddOn() {
    long now = clock.millis();
    ledger.apply(
        fact(
            "expired-base",
            1,
            CapacityKind.BASE,
            5,
            Set.of(),
            now - 86400000,
            now - 1000,
            State.ACTIVE));
    ledger.apply(
        fact(
            "active-addon",
            1,
            CapacityKind.ADD_ON,
            2,
            Set.of(Feature.ORG_BULK),
            now - 1000,
            now + 86400000,
            State.ACTIVE));
    var view = ledger.read(tenant, owner);
    assertThat(view.activeSourceCount()).isEqualTo(1);
    assertThat(view.paidDeviceCapacity()).isZero();
    assertThat(view.addOnDeviceCapacity()).isZero();
    assertThat(view.features()).isEmpty();
  }

  @Test
  void concurrentIndependentSourcesKeepBothFactsAndMonotonicAccountVersion() throws Exception {
    long now = clock.millis();
    var first =
        fact(
            "concurrent-A",
            1,
            CapacityKind.BASE,
            5,
            Set.of(),
            now - 1000,
            now + 86400000,
            State.ACTIVE);
    var second =
        fact(
            "concurrent-B",
            1,
            CapacityKind.ADD_ON,
            2,
            Set.of(),
            now - 1000,
            now + 86400000,
            State.ACTIVE);
    var ready = new CountDownLatch(2);
    var start = new CountDownLatch(1);
    var pool = Executors.newFixedThreadPool(2);
    try {
      var a =
          pool.submit(
              () -> {
                ready.countDown();
                start.await();
                return ledger.apply(first);
              });
      var b =
          pool.submit(
              () -> {
                ready.countDown();
                start.await();
                return ledger.apply(second);
              });
      assertThat(ready.await(5, TimeUnit.SECONDS)).isTrue();
      start.countDown();
      assertThat(a.get(10, TimeUnit.SECONDS).changed()).isTrue();
      assertThat(b.get(10, TimeUnit.SECONDS).changed()).isTrue();
    } finally {
      pool.shutdownNow();
    }
    assertThat(ledger.read(tenant, owner).version()).isEqualTo(2);
    assertThat(ledger.read(tenant, owner).paidDeviceCapacity()).isEqualTo(7);
  }

  @Test
  void auditFailureRollsBackCommercialSourceEventAndVersion() {
    long now = clock.millis();
    AuditService auditTarget = AopTestUtils.getTargetObject(audit);
    doThrow(new IllegalStateException("audit unavailable"))
        .when(auditTarget)
        .record(
            eq(tenant),
            eq("system:contract-verifier"),
            eq("COMMERCIAL_FACT_ACCEPTED"),
            anyString());
    assertThatThrownBy(
            () ->
                ledger.apply(
                    fact(
                        "rollback-source",
                        1,
                        CapacityKind.BASE,
                        4,
                        Set.of(),
                        now - 1000,
                        now + 86400000,
                        State.ACTIVE)))
        .isInstanceOf(IllegalStateException.class);
    assertThat(ledger.read(tenant, owner).version()).isZero();
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?", Integer.class, tenant))
        .isZero();
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isZero();
  }

  private CommercialFact fact(
      String source,
      long revision,
      CapacityKind kind,
      int seats,
      Set<Feature> features,
      long from,
      long until,
      State state) {
    return new CommercialFact(
        tenant,
        SourceSystem.CONTRACT,
        source,
        revision,
        "STANDARD",
        kind,
        seats,
        features,
        from,
        until,
        state,
        "a".repeat(64),
        "system:contract-verifier");
  }

  private String path() {
    return "/api/v1/tenants/" + tenant + "/commercial-entitlements";
  }

  private RequestPostProcessor actor(String subject) {
    return jwt()
        .jwt(token -> token.subject(subject))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
}

package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.util.UUID;
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
import org.springframework.test.context.jdbc.Sql;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Rejecting a forged purchase must never create a ledger entitlement. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:family-subscriptions;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=",
    "manager.exports.worker.enabled=false", "manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false"})
@AutoConfigureMockMvc
@Sql("/family/family-subscription.sql")
class FamilySubscriptionJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate jdbc;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean Clock clock;
  private String tenant;
  private String owner;

  @BeforeEach
  void createFamily() throws Exception {
    Instant now = Instant.parse("2026-01-31T02:00:00Z");
    when(clock.millis()).thenReturn(now.toEpochMilli());
    when(clock.instant()).thenReturn(now);
    when(clock.getZone()).thenReturn(ZoneId.of("UTC"));
    owner = "family-owner-" + UUID.randomUUID();
    tenant = createTenant("FAMILY", owner);
  }

  @Test
  void catalogAndSubscriptionAreForCurrentFamilyAdultsOnly() throws Exception {
    mvc.perform(get(base() + "/subscription-offers").with(actor(owner)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].planKey").value("FAMILY_MONTH"))
        .andExpect(jsonPath("$.items[0].priceMinor").value(1900))
        .andExpect(jsonPath("$.items[1].priceMinor").value(19900))
        .andExpect(jsonPath("$.items[0].childDeviceLimit").value(3))
        .andExpect(jsonPath("$.items[0].renewalMode").value("MANUAL"))
        .andExpect(jsonPath("$.items[0].paymentAvailable").value(false));
    mvc.perform(get(base() + "/subscription").with(actor(owner)))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("NONE"));
    String guardian = member("GUARDIAN");
    mvc.perform(get(base() + "/subscription").with(actor(guardian))).andExpect(status().isOk());
    for (String denied : new String[] {member("CHILD"), member("TEACHER"), member("AUDITOR"), "outsider"}) {
      mvc.perform(get(base() + "/subscription-offers").with(actor(denied))).andExpect(status().isForbidden());
    }
    jdbc.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",
        tenant, ActorKeys.key(guardian));
    mvc.perform(get(base() + "/subscription").with(actor(guardian))).andExpect(status().isForbidden());
    String organization = createTenant("ORGANIZATION", owner);
    mvc.perform(get("/api/v1/tenants/" + organization + "/subscription-offers").with(actor(owner)))
        .andExpect(status().isForbidden());
  }

  @Test
  void ordersFreezeCalendarPeriodsAndIdempotencyRejectsChangedPurchase() throws Exception {
    JsonNode order = order("FAMILY_MONTH", "order-1");
    assertThat(order.path("periodStart").asLong()).isEqualTo(Instant.parse("2026-01-31T02:00:00Z").toEpochMilli());
    assertThat(order.path("periodEnd").asLong()).isEqualTo(Instant.parse("2026-02-28T02:00:00Z").toEpochMilli());
    assertThat(order.path("status").asText()).isEqualTo("CREATED");
    assertThat(order("FAMILY_MONTH", "order-1").path("id").asText()).isEqualTo(order.path("id").asText());
    mvc.perform(post(base() + "/orders").with(actor(owner)).header("Idempotency-Key", "order-1")
        .contentType(MediaType.APPLICATION_JSON).content("{\"planKey\":\"FAMILY_YEAR\"}"))
        .andExpect(status().isConflict());
    mvc.perform(post(base() + "/orders").with(actor(member("GUARDIAN")))
        .header("Idempotency-Key", "guardian-buy").contentType(MediaType.APPLICATION_JSON)
        .content("{\"planKey\":\"FAMILY_MONTH\"}")).andExpect(status().isForbidden());
    mvc.perform(get(base() + "/orders/" + order.path("id").asText()).with(actor("outsider")))
        .andExpect(status().isForbidden());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?", Integer.class, tenant)).isZero();
  }

  @Test
  void unavailablePaymentAndForgedClientSuccessCannotGrantPaidRights() throws Exception {
    String id = order("FAMILY_MONTH", "order-unavailable").path("id").asText();
    mvc.perform(post(base() + "/orders/" + id + "/payment-attempts").with(actor(owner))
        .header("Idempotency-Key", "attempt-1").contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isServiceUnavailable());
    mvc.perform(post(base() + "/orders/" + id + "/payment-attempts").with(actor(owner))
        .header("Idempotency-Key", "attempt-forged").contentType(MediaType.APPLICATION_JSON)
        .content("{\"paid\":true,\"transactionId\":\"forged\"}"))
        .andExpect(status().isBadRequest());
    mvc.perform(post(base() + "/orders/" + id + "/confirm").with(actor(owner))
        .contentType(MediaType.APPLICATION_JSON).content("{\"paid\":true}"))
        .andExpect(status().isNotFound());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?", Integer.class, tenant)).isZero();
    mvc.perform(get(base() + "/orders/" + id).with(actor(owner)))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("CREATED"));
  }

  @Test
  void trialRequiresServerVerifiedAssistedActivation() throws Exception {
    mvc.perform(post(base() + "/subscription/trial").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"deviceId\":\"" + UUID.randomUUID() + "\"}"))
        .andExpect(status().isConflict());
    mvc.perform(post(base() + "/subscription/trial").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"deviceId\":\"" + UUID.randomUUID() + "\",\"activated\":true}"))
        .andExpect(status().isBadRequest());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?", Integer.class, tenant)).isZero();
  }

  private JsonNode order(String plan, String key) throws Exception {
    var result = mvc.perform(post(base() + "/orders").with(actor(owner)).header("Idempotency-Key", key)
        .contentType(MediaType.APPLICATION_JSON).content("{\"planKey\":\"" + plan + "\"}"))
        .andExpect(status().is2xxSuccessful()).andReturn();
    return json.readTree(result.getResponse().getContentAsString());
  }

  private String member(String role) {
    String actor = role + "-" + UUID.randomUUID();
    jdbc.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,?)",
        tenant, actor, ActorKeys.key(actor), role);
    return actor;
  }

  private String createTenant(String kind, String actorId) throws Exception {
    var result = mvc.perform(post("/api/v1/tenants").with(actor(actorId)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"Family\",\"kind\":\"" + kind + "\",\"timeZone\":\"UTC\"}"))
        .andExpect(status().isCreated()).andReturn();
    return json.readTree(result.getResponse().getContentAsString()).path("id").asText();
  }

  private String base() { return "/api/v1/tenants/" + tenant; }

  private RequestPostProcessor actor(String subject) {
    return jwt().jwt(token -> token.subject(subject).claim("phone_number","+8613900000000").claim("phone_number_verified",true))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
}

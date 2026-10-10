package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.commerce.internal.CommercialOfferDraft.BillingPeriod;
import com.aimanager.commerce.internal.CommercialOfferDraft.BuyerKind;
import com.aimanager.commerce.internal.CommercialOfferDraft.Channel;
import com.aimanager.commerce.internal.CommercialOfferDraft.DeviceMode;
import com.aimanager.commerce.internal.CommercialOfferDraft.Platform;
import com.aimanager.commerce.internal.CommercialOfferDraft.PriceType;
import com.aimanager.commerce.internal.CommercialOfferDraft.TaxBasis;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.List;
import java.util.Map;
import java.util.Set;
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
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Real HTTP authorization, V30 state changes and immutable operator history. */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${CATALOG_TEST_DATABASE_URL:jdbc:h2:mem:commercial-catalog;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${CATALOG_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${CATALOG_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false"
    })
@AutoConfigureMockMvc
class CommercialCatalogJourneyTest {
  private static final String PATH = "/api/v1/platform/catalog/offers";
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate jdbc;
  @Autowired Clock clock;
  @MockitoBean JwtDecoder decoder;

  @BeforeEach
  void resetCatalogFixture() {
    jdbc.update("DELETE FROM commercial_catalog_events");
    jdbc.update("DELETE FROM commercial_catalog_offers");
  }

  @Test
  void onlyPlatformScopesCanCreateOrInspectDrafts() throws Exception {
    String id = UUID.randomUUID().toString();
    mvc.perform(
            post(PATH)
                .with(actor("family-owner", "SCOPE_tenant:create", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(id, offer())))
        .andExpect(status().isForbidden());
    mvc.perform(get(PATH).with(actor("family-owner", "SCOPE_tenant:create", false)))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(PATH)
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(id, offer())))
        .andExpect(status().isCreated())
        .andExpect(header().string("ETag", "\"1\""))
        .andExpect(jsonPath("$.purchaseAvailable").value(false))
        .andExpect(jsonPath("$.state").value("DRAFT"));
    mvc.perform(get(PATH + "/" + id).with(actor("approver", "SCOPE_catalog:approve", false)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.offer.sku").value("FAMILY_BASIC"));
    mvc.perform(get(PATH).with(actor("operator", "SCOPE_catalog:manage", false)))
        .andExpect(status().isOk())
        .andExpect(
            jsonPath("$.items.length()").value(org.hamcrest.Matchers.greaterThanOrEqualTo(1)));
  }

  @Test
  void replayIsIdempotentButSameIdDifferentPriceOrSameOfferKeyConflicts() throws Exception {
    String id = UUID.randomUUID().toString();
    var original = offer();
    create(id, "operator", original);
    mvc.perform(
            post(PATH)
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(id, original)))
        .andExpect(status().isOk());
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_catalog_events WHERE offer_id=?",
                Integer.class,
                id))
        .isEqualTo(1);
    mvc.perform(
            post(PATH)
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(id, offerWithAmount(200L))))
        .andExpect(status().isConflict());
    mvc.perform(
            post(PATH)
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(UUID.randomUUID().toString(), offer())))
        .andExpect(status().isConflict());
  }

  @Test
  void revisionReviewAndIndependentMfaApprovalNeverOpenSales() throws Exception {
    String id = UUID.randomUUID().toString();
    create(id, "operator", offer());
    mvc.perform(
            put(PATH + "/" + id)
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .header("If-Match", "\"0\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(offerWithAmount(200L))))
        .andExpect(status().isPreconditionFailed());
    mvc.perform(
            put(PATH + "/" + id)
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(offerWithAmount(200L))))
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"2\""));
    mvc.perform(
            post(PATH + "/" + id + "/submit")
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .header("If-Match", "\"2\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Ready for independent review\"}"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("IN_REVIEW"));
    mvc.perform(
            post(PATH + "/" + id + "/approve")
                .with(actor("operator", "SCOPE_catalog:approve", true))
                .header("If-Match", "\"3\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Reviewed price and applicability\"}"))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(PATH + "/" + id + "/approve")
                .with(actor("approver", "SCOPE_catalog:approve", false))
                .header("If-Match", "\"3\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Reviewed price and applicability\"}"))
        .andExpect(status().isUnauthorized());
    mvc.perform(
            post(PATH + "/" + id + "/approve")
                .with(actor("approver", "SCOPE_catalog:approve", true))
                .header("If-Match", "\"3\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Reviewed price and applicability\"}"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("APPROVED"))
        .andExpect(jsonPath("$.purchaseAvailable").value(false));
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_catalog_events WHERE offer_id=?",
                Integer.class,
                id))
        .isEqualTo(4);
    mvc.perform(
            get(PATH + "/" + id + "/history")
                .with(actor("approver", "SCOPE_catalog:approve", false))
                .param("limit", "2"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(2))
        .andExpect(jsonPath("$.items[0].action").value("APPROVED"))
        .andExpect(jsonPath("$.items[0].reason").value("Reviewed price and applicability"))
        .andExpect(jsonPath("$.items[0].offer.priceMinor").value(200))
        .andExpect(jsonPath("$.nextBeforeRevision").value(3));
    mvc.perform(
            get(PATH + "/" + id + "/history")
                .with(actor("approver", "SCOPE_catalog:approve", false))
                .param("limit", "2")
                .param("beforeRevision", "3"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].action").value("REVISED"))
        .andExpect(jsonPath("$.nextBeforeRevision").doesNotExist());
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_sources", Integer.class))
        .isZero();
  }

  @Test
  void retirementRequiresRecentMfaAndPreservesHistory() throws Exception {
    String id = UUID.randomUUID().toString();
    create(id, "operator", offer());
    mvc.perform(
            post(PATH + "/" + id + "/retire")
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Withdrawn before publication\"}"))
        .andExpect(status().isUnauthorized());
    mvc.perform(
            post(PATH + "/" + id + "/retire")
                .with(actor("operator", "SCOPE_catalog:manage", true))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Withdrawn before publication\"}"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("RETIRED"));
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_catalog_events WHERE offer_id=?",
                Integer.class,
                id))
        .isEqualTo(2);
  }

  @Test
  void malformedOfferAndMissingVersionDoNotCreateCatalogEvents() throws Exception {
    String id = UUID.randomUUID().toString();
    mvc.perform(
            post(PATH)
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(id, Map.of("sku", "bad"))))
        .andExpect(status().isBadRequest());
    create(id, "operator", offer());
    mvc.perform(
            post(PATH + "/" + id + "/submit")
                .with(actor("operator", "SCOPE_catalog:manage", false)))
        .andExpect(status().isPreconditionRequired());
    mvc.perform(
            post(PATH + "/" + id + "/submit")
                .with(actor("operator", "SCOPE_catalog:manage", false))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"x\"}"))
        .andExpect(status().isBadRequest());
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_catalog_events WHERE offer_id=?",
                Integer.class,
                id))
        .isEqualTo(1);
  }

  private void create(String id, String actorId, CommercialOfferDraft input) throws Exception {
    mvc.perform(
            post(PATH)
                .with(actor(actorId, "SCOPE_catalog:manage", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(id, input)))
        .andExpect(status().isCreated());
  }

  private String body(String id, Object offer) throws Exception {
    return json.writeValueAsString(Map.of("id", id, "offer", offer));
  }

  private CommercialOfferDraft offer() {
    return offerWithAmount(100L);
  }

  private CommercialOfferDraft offerWithAmount(long amount) {
    long now = clock.millis();
    return new CommercialOfferDraft(
        "FAMILY_BASIC",
        1,
        "CN",
        Channel.CONTRACT,
        BuyerKind.FAMILY,
        Platform.ANDROID,
        DeviceMode.BYOD,
        BillingPeriod.YEAR,
        PriceType.FIXED,
        "CNY",
        amount,
        TaxBasis.INCLUSIVE,
        CapacityKind.BASE,
        3,
        Set.of(Feature.ADVANCED_SCHEDULES),
        now - 1000,
        now + 86_400_000);
  }

  private RequestPostProcessor actor(String subject, String scope, boolean mfa) {
    return jwt()
        .jwt(
            token ->
                token
                    .subject(subject)
                    .claim("auth_time", clock.instant())
                    .claim("amr", mfa ? List.of("pwd", "otp") : List.of("pwd")))
        .authorities(new SimpleGrantedAuthority(scope));
  }
}

package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.commerce.internal.CommercialFact.State;
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

/**
 * API flow with a replaceable verified source and real catalog, ledger, audit and tenant guards.
 */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${CONTRACT_TEST_DATABASE_URL:jdbc:h2:mem:commercial-contract;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${CONTRACT_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${CONTRACT_TEST_DATABASE_PASSWORD:}",
      "manager.exports.worker.enabled=false"
    })
@AutoConfigureMockMvc
class CommercialContractJourneyTest {
  private static final String CATALOG = "/api/v1/platform/catalog/offers";
  private static final String CONTRACTS = "/api/v1/platform/contracts";
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate jdbc;
  @Autowired Clock clock;
  @MockitoBean JwtDecoder identityDecoder;
  @MockitoBean ContractEvidenceVerifier verifier;

  private String tenant;
  private String owner;
  private String offerId;
  private long offerRevision;

  @BeforeEach
  void provision() throws Exception {
    owner = "org-owner-" + UUID.randomUUID();
    tenant =
        json.readTree(
                mvc.perform(
                        post("/api/v1/tenants")
                            .with(actor(owner, "SCOPE_tenant:create", false))
                            .contentType(MediaType.APPLICATION_JSON)
                            .content(
                                "{\"name\":\"Institution\",\"kind\":\"ORGANIZATION\",\"timeZone\":\"Asia/Shanghai\"}"))
                    .andExpect(status().isCreated())
                    .andReturn()
                    .getResponse()
                    .getContentAsString())
            .path("id")
            .asText();
    offerId = UUID.randomUUID().toString();
    var offer =
        new CommercialOfferDraft(
            "ORG_STANDARD_" + UUID.randomUUID().toString().replace("-", "").toUpperCase(),
            1,
            "CN",
            Channel.CONTRACT,
            BuyerKind.ORGANIZATION,
            Platform.ANDROID,
            DeviceMode.FULLY_MANAGED,
            BillingPeriod.YEAR,
            PriceType.QUOTE,
            "CNY",
            null,
            TaxBasis.QUOTE_REQUIRED,
            CapacityKind.BASE,
            25,
            Set.of(Feature.ORG_BULK),
            clock.millis() - 10_000,
            clock.millis() + 86_400_000);
    mvc.perform(
            post(CATALOG)
                .with(actor("catalog-author", "SCOPE_catalog:manage", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsString(Map.of("id", offerId, "offer", offer))))
        .andExpect(status().isCreated());
    mvc.perform(
            post(CATALOG + "/" + offerId + "/submit")
                .with(actor("catalog-author", "SCOPE_catalog:manage", false))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Institution contract review\"}"))
        .andExpect(status().isOk());
    mvc.perform(
            post(CATALOG + "/" + offerId + "/approve")
                .with(actor("catalog-approver", "SCOPE_catalog:approve", true))
                .header("If-Match", "\"2\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Approved institution offer\"}"))
        .andExpect(status().isOk());
    offerRevision = 3;
  }

  @Test
  void submitReviewAndCustomerAcceptanceApplyExactlyOnce() throws Exception {
    String id = UUID.randomUUID().toString();
    ContractEvidence evidence = evidence("contract-A-" + id, 1, State.ACTIVE);
    when(verifier.verify("signed-assertion-A")).thenReturn(evidence);
    mvc.perform(
            post(CONTRACTS)
                .with(actor(owner, "SCOPE_tenant:create", true))
                .contentType(MediaType.APPLICATION_JSON)
                .content(create(id, "signed-assertion-A")))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(CONTRACTS)
                .with(actor("contract-author", "SCOPE_contract:manage", false))
                .contentType(MediaType.APPLICATION_JSON)
                .content(create(id, "signed-assertion-A")))
        .andExpect(status().isUnauthorized());
    mvc.perform(
            post(CONTRACTS)
                .with(actor("contract-author", "SCOPE_contract:manage", true))
                .contentType(MediaType.APPLICATION_JSON)
                .content(create(id, "signed-assertion-A")))
        .andExpect(status().isCreated())
        .andExpect(header().string("ETag", "\"1\""))
        .andExpect(jsonPath("$.state").value("PENDING_REVIEW"))
        .andExpect(jsonPath("$.entitlementApplied").value(false));
    mvc.perform(
            post(CONTRACTS)
                .with(actor("contract-author", "SCOPE_contract:manage", true))
                .contentType(MediaType.APPLICATION_JSON)
                .content(create(id, "signed-assertion-A")))
        .andExpect(status().isOk());
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_contract_events WHERE review_id=?",
                Integer.class,
                id))
        .isEqualTo(1);
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?", Integer.class, tenant))
        .isZero();
    mvc.perform(
            post(CONTRACTS + "/" + id + "/approve")
                .with(actor("contract-author", "SCOPE_contract:approve", true))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Independent contract check\"}"))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(CONTRACTS + "/" + id + "/approve")
                .with(actor("contract-approver", "SCOPE_contract:approve", true))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Independent contract check\"}"))
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"2\""))
        .andExpect(jsonPath("$.state").value("AWAITING_CUSTOMER"));
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?", Integer.class, tenant))
        .isZero();
    mvc.perform(
            post(tenantPath(id) + "/accept")
                .with(actor("stranger", "SCOPE_tenant:create", true))
                .header("If-Match", "\"2\""))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(tenantPath(id) + "/accept")
                .with(actor(owner, "SCOPE_tenant:create", true))
                .header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("APPLIED"))
        .andExpect(jsonPath("$.entitlementApplied").value(true))
        .andExpect(jsonPath("$.submittedBy").doesNotExist())
        .andExpect(jsonPath("$.approvedBy").doesNotExist());
    mvc.perform(
            get("/api/v1/tenants/" + tenant + "/commercial-entitlements")
                .with(actor(owner, "SCOPE_tenant:create", false)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.paidDeviceCapacity").value(25));
    mvc.perform(
            post(tenantPath(id) + "/accept")
                .with(actor(owner, "SCOPE_tenant:create", true))
                .header("If-Match", "\"2\""))
        .andExpect(status().isPreconditionFailed());
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isEqualTo(1);
  }

  @Test
  void signedRevocationNeedsIndependentApprovalAndWithdrawsEntitlement() throws Exception {
    String reference = "contract-B-" + UUID.randomUUID();
    String original = UUID.randomUUID().toString();
    when(verifier.verify("signed-active")).thenReturn(evidence(reference, 1, State.ACTIVE));
    createReview(original, "signed-active");
    approve(original);
    mvc.perform(
            post(tenantPath(original) + "/accept")
                .with(actor(owner, "SCOPE_tenant:create", true))
                .header("If-Match", "\"2\""))
        .andExpect(status().isOk());
    String revoked = UUID.randomUUID().toString();
    when(verifier.verify("signed-revoked")).thenReturn(evidence(reference, 2, State.REVOKED));
    createReview(revoked, "signed-revoked");
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isEqualTo(1);
    approve(revoked);
    mvc.perform(get(tenantPath(revoked)).with(actor(owner, "SCOPE_tenant:create", false)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("APPLIED"));
    mvc.perform(
            get("/api/v1/tenants/" + tenant + "/commercial-entitlements")
                .with(actor(owner, "SCOPE_tenant:create", false)))
        .andExpect(jsonPath("$.paidDeviceCapacity").value(0));
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isEqualTo(2);
  }

  @Test
  void tenantBoundariesAndRejectionPreventAcceptance() throws Exception {
    String id = UUID.randomUUID().toString();
    when(verifier.verify("signed-reject"))
        .thenReturn(evidence("contract-C-" + id, 1, State.ACTIVE));
    createReview(id, "signed-reject");
    mvc.perform(get(CONTRACTS + "/" + id).with(actor(owner, "SCOPE_tenant:create", false)))
        .andExpect(status().isForbidden());
    mvc.perform(
            get("/api/v1/tenants/" + UUID.randomUUID() + "/contracts/" + id)
                .with(actor(owner, "SCOPE_tenant:create", false)))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(CONTRACTS + "/" + id + "/reject")
                .with(actor("contract-approver", "SCOPE_contract:approve", true))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Contract source requires correction\"}"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("REJECTED"));
    mvc.perform(
            post(tenantPath(id) + "/accept")
                .with(actor(owner, "SCOPE_tenant:create", true))
                .header("If-Match", "\"2\""))
        .andExpect(status().isConflict());
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?", Integer.class, tenant))
        .isZero();
  }

  private void createReview(String id, String token) throws Exception {
    mvc.perform(
            post(CONTRACTS)
                .with(actor("contract-author", "SCOPE_contract:manage", true))
                .contentType(MediaType.APPLICATION_JSON)
                .content(create(id, token)))
        .andExpect(status().isCreated());
  }

  private void approve(String id) throws Exception {
    mvc.perform(
            post(CONTRACTS + "/" + id + "/approve")
                .with(actor("contract-approver", "SCOPE_contract:approve", true))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Independently verified contract\"}"))
        .andExpect(status().isOk());
  }

  private ContractEvidence evidence(String reference, long revision, State state) {
    long now = clock.millis();
    return new ContractEvidence(
        UUID.randomUUID().toString(),
        tenant,
        offerId,
        offerRevision,
        reference,
        revision,
        "buyer-1",
        CapacityKind.BASE,
        25,
        Set.of(Feature.ORG_BULK),
        now - 1000,
        now + 86_400_000,
        state,
        now,
        "buyer-signature-1",
        "seller-signature-1",
        UUID.randomUUID().toString().replace("-", "")
            + UUID.randomUUID().toString().replace("-", ""));
  }

  private String tenantPath(String id) {
    return "/api/v1/tenants/" + tenant + "/contracts/" + id;
  }

  private String create(String id, String token) throws Exception {
    return json.writeValueAsString(Map.of("id", id, "evidence", token));
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

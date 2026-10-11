package com.aimanager.commerce.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.commerce.internal.CommercialFact.SourceSystem;
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

/** A paused sale must not block a trusted, independently reviewed revocation. */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${CONTRACT_PAUSE_TEST_DATABASE_URL:jdbc:h2:mem:paused-contract;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${CONTRACT_PAUSE_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${CONTRACT_PAUSE_TEST_DATABASE_PASSWORD:}",
      "manager.contract.evidence-enabled=true",
      "manager.contract.active-submissions-enabled=false",
      "manager.contract.issuer=https://issuer.example.test/contracts",
      "manager.contract.audience=ai-manager-contracts",
      "manager.contract.jwk-set-uri=https://issuer.example.test/jwks",
      "manager.exports.worker.enabled=false"
    })
@AutoConfigureMockMvc
class PausedContractSubmissionJourneyTest {
  private static final String CATALOG = "/api/v1/platform/catalog/offers";
  private static final String CONTRACTS = "/api/v1/platform/contracts";
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate jdbc;
  @Autowired Clock clock;
  @Autowired CommercialLedger ledger;
  @MockitoBean JwtDecoder identityDecoder;
  @MockitoBean ContractEvidenceVerifier verifier;

  @Test
  void pausedActiveContractRejectsNewBusinessButSignedRevocationStillApplies() throws Exception {
    long now = clock.millis();
    String owner = "owner-" + UUID.randomUUID();
    String tenant =
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
    String offerId = UUID.randomUUID().toString();
    String sku = "ORG_PAUSED_" + UUID.randomUUID().toString().replace("-", "").toUpperCase();
    var offer =
        new CommercialOfferDraft(
            sku,
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
            now - 10_000,
            now + 86_400_000);
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
                .content("{\"reason\":\"Institution pilot offer\"}"))
        .andExpect(status().isOk());
    mvc.perform(
            post(CATALOG + "/" + offerId + "/approve")
                .with(actor("catalog-approver", "SCOPE_catalog:approve", true))
                .header("If-Match", "\"2\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Approved pilot offer\"}"))
        .andExpect(status().isOk());

    String reference = "contract-" + UUID.randomUUID();
    ledger.apply(
        new CommercialFact(
            tenant,
            SourceSystem.CONTRACT,
            reference,
            1,
            sku,
            CapacityKind.BASE,
            25,
            Set.of(Feature.ORG_BULK),
            now - 1000,
            now + 86_400_000,
            State.ACTIVE,
            "a".repeat(64),
            "seed-verified-source"));
    mvc.perform(
            get(CONTRACTS + "/capabilities")
                .with(actor("contract-author", "SCOPE_contract:manage", false)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.submissionEnabled").value(false))
        .andExpect(jsonPath("$.revocationSubmissionEnabled").value(true));

    ContractEvidence pending =
        evidence(tenant, offerId, "pending-" + UUID.randomUUID(), 1, State.ACTIVE, now);
    String pendingId = insertActiveReview(pending, "PENDING_REVIEW", 1, now);
    when(verifier.verify("signed-existing")).thenReturn(pending);
    mvc.perform(
            post(CONTRACTS)
                .with(actor("contract-author", "SCOPE_contract:manage", true))
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsString(
                        Map.of("id", pendingId, "evidence", "signed-existing"))))
        .andExpect(status().isOk());
    mvc.perform(
            post(CONTRACTS + "/" + pendingId + "/approve")
                .with(actor("contract-approver", "SCOPE_contract:approve", true))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Previously submitted contract\"}"))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("CONTRACT_ACTIVE_SUBMISSIONS_PAUSED"));

    ContractEvidence awaiting =
        evidence(tenant, offerId, "awaiting-" + UUID.randomUUID(), 1, State.ACTIVE, now);
    String awaitingId = insertActiveReview(awaiting, "AWAITING_CUSTOMER", 2, now);
    mvc.perform(
            post("/api/v1/tenants/" + tenant + "/contracts/" + awaitingId + "/accept")
                .with(actor(owner, "SCOPE_tenant:create", true))
                .header("If-Match", "\"2\""))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("CONTRACT_ACTIVE_SUBMISSIONS_PAUSED"));

    when(verifier.verify("signed-active"))
        .thenReturn(evidence(tenant, offerId, reference, 2, State.ACTIVE, now));
    mvc.perform(
            post(CONTRACTS)
                .with(actor("contract-author", "SCOPE_contract:manage", true))
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsString(
                        Map.of("id", UUID.randomUUID(), "evidence", "signed-active"))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("CONTRACT_ACTIVE_SUBMISSIONS_PAUSED"));

    String reviewId = UUID.randomUUID().toString();
    when(verifier.verify("signed-revoked"))
        .thenReturn(evidence(tenant, offerId, reference, 2, State.REVOKED, now));
    mvc.perform(
            post(CONTRACTS)
                .with(actor("contract-author", "SCOPE_contract:manage", true))
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsString(Map.of("id", reviewId, "evidence", "signed-revoked"))))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.state").value("PENDING_REVIEW"));
    mvc.perform(
            post(CONTRACTS + "/" + reviewId + "/approve")
                .with(actor("contract-approver", "SCOPE_contract:approve", true))
                .header("If-Match", "\"1\"")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"reason\":\"Verified issuer revocation\"}"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("APPLIED"));
    mvc.perform(
            get("/api/v1/tenants/" + tenant + "/commercial-entitlements")
                .with(actor(owner, "SCOPE_tenant:create", false)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.paidDeviceCapacity").value(0));
    assertThat(
            jdbc.queryForObject(
                "SELECT COUNT(*) FROM commercial_source_events WHERE tenant_id=?",
                Integer.class,
                tenant))
        .isEqualTo(2);
  }

  private ContractEvidence evidence(
      String tenant, String offer, String reference, long revision, State state, long now) {
    return new ContractEvidence(
        UUID.randomUUID().toString(),
        tenant,
        offer,
        3,
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

  private String insertActiveReview(ContractEvidence evidence, String state, long version, long now)
      throws Exception {
    String id = UUID.randomUUID().toString();
    jdbc.update(
        "INSERT INTO commercial_contract_reviews(id,tenant_id,offer_id,offer_revision,"
            + "contract_reference,source_revision,evidence_event_id,evidence_hash,evidence_json,"
            + "state,version,submitted_by,approved_by,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        id,
        evidence.tenantId(),
        evidence.offerId(),
        evidence.offerRevision(),
        evidence.contractReference(),
        evidence.sourceRevision(),
        evidence.eventId(),
        evidence.evidenceHash(),
        json.writeValueAsString(evidence),
        state,
        version,
        "contract-author",
        "AWAITING_CUSTOMER".equals(state) ? "contract-approver" : null,
        now,
        now);
    return id;
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

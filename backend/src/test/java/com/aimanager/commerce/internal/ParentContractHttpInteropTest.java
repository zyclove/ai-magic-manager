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
@org.junit.jupiter.api.condition.EnabledIfSystemProperty(named="parent.dart.command",matches=".+")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "spring.datasource.url=jdbc:h2:mem:parentcontracthttp;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "manager.contract.evidence-enabled=true",
      "manager.contract.active-submissions-enabled=true",
      "manager.exports.worker.enabled=false", "server.address=127.0.0.1"
    })
@AutoConfigureMockMvc
class ParentContractHttpInteropTest {
  private static final String CATALOG = "/api/v1/platform/catalog/offers";
  private static final String CONTRACTS = "/api/v1/platform/contracts";
  @org.springframework.boot.test.web.server.LocalServerPort int port;
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

  @Test void productionPhoneAcceptsOnceAndRecoversCurrentContractAfterReplyLoss() throws Exception {
    String id=UUID.randomUUID().toString(), token=com.aimanager.shared.SecretMaterial.token();
    when(verifier.verify("explicit-contract-fixture")).thenReturn(evidence("contract-phone-"+id,1,State.ACTIVE));
    createReview(id,"explicit-contract-fixture");approve(id);
    when(identityDecoder.decode(org.mockito.ArgumentMatchers.anyString())).thenAnswer(call->{
      String supplied=call.getArgument(0);
      if(!token.equals(supplied))throw new org.springframework.security.oauth2.jwt.BadJwtException("Not a fixture identity");
      return org.springframework.security.oauth2.jwt.Jwt.withTokenValue(token).header("alg","fixture").subject(owner)
          .claim("scope","tenant:create").claim("auth_time",clock.instant().getEpochSecond()).claim("amr",List.of("pwd","otp"))
          .issuedAt(clock.instant()).expiresAt(clock.instant().plusSeconds(600)).build();
    });
    java.nio.file.Path output=java.nio.file.Path.of("target","parent-contract-http.log").toAbsolutePath();
    var builder=new ProcessBuilder(System.getProperty("parent.dart.command"),System.getProperty("parent.flutter.tool"),
        "test","--no-pub","tool/verify_contract_http_test.dart")
        .directory(java.nio.file.Path.of(System.getProperty("parent.package","../apps/parent")).toAbsolutePath().toFile())
        .redirectErrorStream(true).redirectOutput(output.toFile());
    builder.environment().put("PARENT_CONTRACT_HTTP_FIXTURE",json.writeValueAsString(Map.of(
        "testOnly",true,"apiRoot","http://127.0.0.1:"+port+"/api/v1","tenantId",tenant,"reviewId",id,"actorId",owner,"token",token)));
    var process=builder.start();
    try {
      assertThat(process.waitFor(90,java.util.concurrent.TimeUnit.SECONDS)).isTrue();
      assertThat(process.exitValue()).as("Flutter diagnostics: %s",output).isZero();
      assertThat(java.nio.file.Files.readString(output)).contains("All tests passed!");
    }finally{if(process.isAlive())process.destroyForcibly();}
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_sources WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM commercial_contract_events WHERE review_id=? AND action='CUSTOMER_ACCEPTED'",Integer.class,id)).isEqualTo(1);
    assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='CONTRACT_CUSTOMER_ACCEPTED'",Integer.class,tenant)).isEqualTo(1);
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

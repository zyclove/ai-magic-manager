package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.commerce.CommercialCapacity;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.identity.ActorKeys;
import com.aimanager.managedandroid.ManagedAgentEvidence;
import com.aimanager.managedandroid.ManagedAgentProofVerifier;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedEnterpriseAuthority;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.ECDSASigner;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.ECKey;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import com.nimbusds.jwt.*;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** 真实 MVC、设备凭证和事务；只有机构资格与远端提供方由明确夹具替代。 */
@SpringBootTest(
    properties = {
      "spring.datasource.url=jdbc:h2:mem:agent-binding;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "manager.emm.agent-binding.package-name=com.aimanager.child",
      "manager.emm.agent-binding.signing-certificates=" + ManagedAgentBindingJourneyTest.CERT
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ManagedAgentBindingJourneyTest {
  static final String CERT = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired JdbcTemplate db;
  @Autowired DeviceCredentials credentials;
  @Autowired PlatformTransactionManager transactions;
  @Autowired ManagedAndroidGateway gateway;
  @Autowired ManagedAgentBindingStore store;
  @MockitoBean JwtDecoder decoder;
  @Autowired ManagedEnterpriseAuthority enterprises;
  @Autowired CommercialCapacity capacity;

  @Test
  void contextReturnsOnlyActiveDevicesForTheEnrollmentSubjectAndExplainsSetup() throws Exception {
    var f = fixture();
    var another = fixture();
    String otherSubject = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'另一学生','AGE_7_12',?)",
        f.tenant(),
        otherSubject,
        System.currentTimeMillis());
    cloneDevice(f, otherSubject, "ACTIVE");
    cloneDevice(f, f.subject(), "REVOKED");
    mvc.perform(get(f.root() + "/context/" + f.intent()).with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.enrollmentId").value(f.intent()))
        .andExpect(jsonPath("$.subjectId").value(f.subject()))
        .andExpect(jsonPath("$.reasonCode").value("READY"))
        .andExpect(jsonPath("$.candidates.items.length()").value(1))
        .andExpect(jsonPath("$.candidates.items[0].id").value(f.device()))
        .andExpect(jsonPath("$.currentBinding").isEmpty());
    when(gateway.supportsAgentBindingEvidence()).thenReturn(false);
    mvc.perform(get(f.root() + "/context/" + f.intent()).with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.ready").value(false))
        .andExpect(jsonPath("$.reasonCode").value("PROVIDER_EVIDENCE_UNSUPPORTED"));
    mvc.perform(get(f.root() + "/context/" + f.intent()).with(actor(another.actor())))
        .andExpect(status().isForbidden());
  }

  private String cloneDevice(Fixture f, String subject, String state) {
    String device = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " SELECT"
            + " tenant_id,?,?,?,'候选平板',platform,os_version,?,public_key_jwk,key_thumbprint,created_at"
            + " FROM devices WHERE tenant_id=? AND id=?",
        device,
        subject,
        UUID.randomUUID().toString(),
        state,
        f.tenant(),
        f.device());
    return device;
  }

  @Test
  void selectionContextPaginatesCandidatesAndShowsCurrentBindingWithoutNonce() throws Exception {
    var f = fixture();
    cloneDevice(f, f.subject(), "ACTIVE");
    var binding = create(f, UUID.randomUUID().toString());
    var first =
        json.readTree(
            mvc.perform(
                    get(f.root() + "/context/" + f.intent() + "?limit=1").with(actor(f.actor())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.currentBinding.id").value(binding.get("id").asText()))
                .andExpect(jsonPath("$.currentBinding.nonce").doesNotExist())
                .andReturn()
                .getResponse()
                .getContentAsString());
    String cursor = first.get("candidates").get("nextCursor").asText();
    var second =
        json.readTree(
            mvc.perform(
                    get(f.root() + "/context/" + f.intent() + "?limit=1&cursor=" + cursor)
                        .with(actor(f.actor())))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.candidates.items.length()").value(1))
                .andExpect(jsonPath("$.candidates.nextCursor").isEmpty())
                .andReturn()
                .getResponse()
                .getContentAsString());
    assertThat(second.get("candidates").get("items").get(0).get("id").asText())
        .isNotEqualTo(cursor);
    db.update("UPDATE tenant_members SET role='AUDITOR' WHERE tenant_id=?", f.tenant());
    mvc.perform(get(f.root() + "/context/" + f.intent()).with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.currentBinding.id").value(binding.get("id").asText()));
  }

  @Test
  void schemaIndexesCoverCurrentDeviceLookupAndPendingCounts() {
    var columns =
        db.execute(
            (org.springframework.jdbc.core.ConnectionCallback<
                    java.util.Map<String, java.util.List<String>>>)
                connection -> {
                  var indexes = new java.util.HashMap<String, java.util.List<String>>();
                  try (var rows =
                      connection
                          .getMetaData()
                          .getIndexInfo(
                              connection.getCatalog(),
                              connection.getSchema(),
                              "managed_agent_bindings",
                              false,
                              false)) {
                    while (rows.next()) {
                      String name = rows.getString("INDEX_NAME"),
                          column = rows.getString("COLUMN_NAME");
                      if (name != null && column != null)
                        indexes
                            .computeIfAbsent(
                                name.toLowerCase(java.util.Locale.ROOT),
                                ignored -> new java.util.ArrayList<>())
                            .add(column);
                    }
                  }
                  return indexes;
                });
    assertThat(columns.get("ix_managed_agent_pending"))
        .containsExactly("tenant_id", "state", "expires_at");
    assertThat(
            columns.entrySet().stream()
                .filter(e -> e.getKey().startsWith("uq_managed_agent_device"))
                .findFirst()
                .orElseThrow()
                .getValue())
        .containsExactly("tenant_id", "active_device_id");
  }

  @Test
  void invalidExpiryAndReleaseTrustConfigurationAreRejected() {
    org.assertj.core.api.Assertions.assertThatThrownBy(
            () -> new ManagedAgentBindingExpiryJob(store, 0, 30))
        .isInstanceOf(IllegalArgumentException.class);
    org.assertj.core.api.Assertions.assertThatThrownBy(
            () -> new ManagedAgentBindingExpiryJob(store, 100, 1))
        .isInstanceOf(IllegalArgumentException.class);
    org.assertj.core.api.Assertions.assertThatThrownBy(
            () -> new ManagedAgentBindingSettings("https://wrong", CERT))
        .isInstanceOf(IllegalArgumentException.class);
    org.assertj.core.api.Assertions.assertThatThrownBy(
            () -> new ManagedAgentBindingSettings("com.aimanager.child", "not-a-certificate"))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @TestConfiguration
  static class Provider {
    @Bean
    @Primary
    ManagedEnterpriseAuthority bindingTestAuthority() {
      return mock(ManagedEnterpriseAuthority.class);
    }

    @Bean
    @Primary
    CommercialCapacity bindingTestCapacity() {
      return mock(CommercialCapacity.class);
    }

    @Bean
    @Primary
    ManagedAndroidGateway bindingTestGateway() {
      var gateway = mock(ManagedAndroidGateway.class);
      when(gateway.providerCode()).thenReturn("LOCAL_TEST");
      when(gateway.available()).thenReturn(true);
      return gateway;
    }
  }

  record Fixture(
      String tenant,
      String actor,
      String subject,
      String device,
      String registration,
      String intent,
      String enterprise,
      String providerDevice,
      String enrollmentNonce,
      String credential,
      ECKey key) {
    String root() {
      return "/api/v1/tenants/" + tenant + "/managed-android/agent-bindings";
    }
  }

  @BeforeEach
  void setup() {
    reset(gateway, enterprises, capacity);
    when(gateway.providerCode()).thenReturn("LOCAL_TEST");
    when(gateway.available()).thenReturn(true);
    when(capacity.currentForUpdate(anyString())).thenReturn(100L);
    when(gateway.supportsAgentBindingEvidence()).thenReturn(true);
  }

  RequestPostProcessor actor(String id) {
    return jwt()
        .jwt(
            t ->
                t.subject(id)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")));
  }

  Fixture fixture() throws Exception {
    String tenant = UUID.randomUUID().toString(),
        user = UUID.randomUUID().toString(),
        subject = UUID.randomUUID().toString();
    String device = UUID.randomUUID().toString(),
        registration = UUID.randomUUID().toString(),
        intent = UUID.randomUUID().toString();
    String enterprise = "ent_" + tenant,
        providerDevice = "dev_" + device,
        nonce = SecretMaterial.token();
    long now = System.currentTimeMillis();
    ECKey key = new ECKeyGenerator(Curve.P_256).generate();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at)"
            + " VALUES(?,'机构','ORGANIZATION','UTC',?)",
        tenant,
        now);
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'学生','AGE_7_12',?)",
        tenant,
        subject,
        now);
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'OWNER')",
        tenant,
        user,
        ActorKeys.key(user));
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'平板','ANDROID','14','ACTIVE',?,?,?)",
        tenant,
        device,
        subject,
        registration,
        key.toPublicJWK().toJSONString(),
        key.computeThumbprint().toString(),
        now);
    db.update(
        "INSERT INTO"
            + " managed_enterprise_bindings(tenant_id,provider,enterprise_id,contract_reference,state,version,requested_by,created_at,updated_at)"
            + " VALUES(?,'LOCAL_TEST',?,'contract','ACTIVE',1,?,?,?)",
        tenant,
        enterprise,
        user,
        now,
        now);
    db.update(
        "INSERT INTO"
            + " managed_enrollment_intents(tenant_id,id,subject_id,provider,enterprise_id,binding_version,policy_id,policy_version,token_name,nonce_hash,provider_device_id,provider_mode,state,version,requested_by,created_at,issued_at,expires_at,verified_at,updated_at)"
            + " VALUES(?,?,?,'LOCAL_TEST',?,1,'baseline',1,?,?,?,'DEVICE_OWNER','VERIFIED',3,?,?,?,?,?,?)",
        tenant,
        intent,
        subject,
        enterprise,
        "enterprises/" + enterprise + "/enrollmentTokens/token",
        SecretMaterial.hash(nonce),
        providerDevice,
        user,
        now - 1000,
        now - 1000,
        now + 300000,
        now,
        now);
    when(enterprises.requireActive(tenant))
        .thenReturn(new ManagedEnterpriseAuthority.EnterpriseAccess("LOCAL_TEST", enterprise, 1));
    var issued =
        new TransactionTemplate(transactions)
            .execute(
                s -> {
                  var token = credentials.issuePending(tenant, device, registration);
                  credentials.activate(tenant, registration);
                  return token;
                });
    return new Fixture(
        tenant,
        user,
        subject,
        device,
        registration,
        intent,
        enterprise,
        providerDevice,
        nonce,
        issued.credential(),
        key);
  }

  String body(Fixture f) throws Exception {
    return json.writeValueAsString(
        Map.of(
            "enrollmentId",
            f.intent(),
            "deviceId",
            f.device(),
            "registrationId",
            f.registration()));
  }

  JsonNode create(Fixture f, String request) throws Exception {
    var response =
        mvc.perform(
                post(f.root())
                    .with(actor(f.actor()))
                    .header("Idempotency-Key", request)
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(body(f)))
            .andExpect(status().isCreated())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(jsonPath("$.state").value("PENDING"))
            .andExpect(jsonPath("$.nonce").doesNotExist())
            .andReturn()
            .getResponse();
    return json.readTree(response.getContentAsString());
  }

  @Test
  void administratorStartsOneRecoverableChallengeAndOnlyTargetDeviceCanReadNonce()
      throws Exception {
    var f = fixture();
    String request = UUID.randomUUID().toString();
    var first = create(f, request);
    var repeated = create(f, request);
    assertThat(repeated.get("id")).isEqualTo(first.get("id"));
    mvc.perform(
            get("/api/v1/device-api/managed-agent-challenge")
                .header("Authorization", "Bearer " + f.credential()))
        .andExpect(status().isOk())
        .andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(jsonPath("$.challengeId").value(first.get("id").asText()))
        .andExpect(jsonPath("$.nonce").isString())
        .andExpect(jsonPath("$.tenantId").doesNotExist());
    var other = fixture();
    mvc.perform(
            get("/api/v1/device-api/managed-agent-challenge")
                .header("Authorization", "Bearer " + other.credential()))
        .andExpect(status().isNoContent());
    mvc.perform(get(f.root() + "/" + first.get("id").asText()).with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.nonce").doesNotExist())
        .andExpect(jsonPath("$.systemControlAvailable").value(false));
  }

  private ManagedAndroidGateway.ManagedEnrollmentIdentity identity(Fixture f) {
    long issued =
        db.queryForObject(
            "SELECT issued_at FROM managed_enrollment_intents WHERE id=?", Long.class, f.intent());
    return new ManagedAndroidGateway.ManagedEnrollmentIdentity(
        "enterprises/" + f.enterprise() + "/devices/" + f.providerDevice(),
        "DEVICE_OWNER",
        Instant.ofEpochMilli(issued).toString(),
        "enterprises/" + f.enterprise() + "/enrollmentTokens/token",
        f.enrollmentNonce());
  }

  private ManagedAgentEvidence proof(Fixture f, String id) throws Exception {
    var values =
        db.queryForMap(
            "SELECT nonce,created_at,expires_at FROM managed_agent_bindings WHERE id=?", id);
    long issued = ((Number) values.get("created_at")).longValue() / 1000;
    long expires = ((Number) values.get("expires_at")).longValue() / 1000;
    var jwt =
        new SignedJWT(
            new JWSHeader.Builder(JWSAlgorithm.ES256).type(JOSEObjectType.JWT).build(),
            new JWTClaimsSet.Builder()
                .subject(id)
                .claim("nonce", values.get("nonce"))
                .audience(ManagedAgentProofVerifier.AUDIENCE)
                .issueTime(new Date(issued * 1000))
                .expirationTime(new Date(expires * 1000))
                .jwtID(UUID.randomUUID().toString())
                .build());
    jwt.sign(new ECDSASigner(f.key()));
    String now = Instant.now().toString();
    return new ManagedAgentEvidence(
        "enterprises/" + f.enterprise() + "/devices/" + f.providerDevice(),
        "DEVICE_OWNER",
        "com.aimanager.child",
        "INSTALLED",
        List.of(CERT),
        ManagedAgentEvidence.FEEDBACK_KEY,
        "INFO",
        jwt.serialize(),
        now,
        now);
  }

  private void provider(Fixture f, String id) throws Exception {
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenReturn(identity(f));
    when(gateway.readAgentEvidence(f.enterprise(), f.providerDevice(), "com.aimanager.child"))
        .thenReturn(Optional.of(proof(f, id)));
  }

  @Test
  void successfulProofIsConsumedOnceAndRevocationNeverReleasesProviderSeat() throws Exception {
    var f = fixture();
    var binding = create(f, UUID.randomUUID().toString());
    String id = binding.get("id").asText();
    provider(f, id);
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("VERIFIED"))
        .andExpect(header().string("ETag", "\"2\""));
    var saved =
        db.queryForMap("SELECT nonce,proof_sha256 FROM managed_agent_bindings WHERE id=?", id);
    assertThat(saved.get("nonce")).isNull();
    assertThat(saved.get("proof_sha256").toString()).hasSize(64);
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isPreconditionFailed());
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE resource_id=? AND"
                    + " action='MANAGED_AGENT_BINDING_VERIFIED'",
                Integer.class,
                id))
        .isEqualTo(1);
    mvc.perform(
            get("/api/v1/device-api/managed-agent-challenge")
                .header("Authorization", "Bearer " + f.credential()))
        .andExpect(status().isNoContent());
    mvc.perform(
            post(f.root() + "/" + id + "/revoke")
                .with(actor(f.actor()))
                .header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("REVOKED"));
    assertThat(
            db.queryForObject(
                "SELECT state FROM managed_enrollment_intents WHERE id=?",
                String.class,
                f.intent()))
        .isEqualTo("VERIFIED");
    create(f, UUID.randomUUID().toString());
    verify(gateway, never()).deleteEnrollmentToken(anyString(), anyString());
  }

  @Test
  void pendingReportIsRetryableAndPollingIsBounded() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenReturn(identity(f));
    when(gateway.readAgentEvidence(anyString(), anyString(), anyString()))
        .thenReturn(Optional.empty());
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isAccepted())
        .andExpect(jsonPath("$.state").value("PENDING"));
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isTooManyRequests());
  }

  @Test
  void revokedRegistrationAndArchivedSubjectCannotBindOrRetrieveChallenge() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    provider(f, id);
    db.update(
        "UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?",
        System.currentTimeMillis(),
        f.tenant(),
        f.subject());
    mvc.perform(
            get("/api/v1/device-api/managed-agent-challenge")
                .header("Authorization", "Bearer " + f.credential()))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isConflict());
    db.update(
        "UPDATE subjects SET archived_at=NULL WHERE tenant_id=? AND id=?", f.tenant(), f.subject());
    new TransactionTemplate(transactions)
        .executeWithoutResult(s -> credentials.revoke(f.tenant(), f.registration()));
    db.update(
        "UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?", f.tenant(), f.device());
    mvc.perform(
            get("/api/v1/device-api/managed-agent-challenge")
                .header("Authorization", "Bearer " + f.credential()))
        .andExpect(status().isUnauthorized());
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isConflict());
    verify(gateway, never()).readAgentEvidence(anyString(), anyString(), anyString());
  }

  @Test
  void tenantRolesRecentAuthenticationVersionsAndCanonicalIdsAreRequired() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    mvc.perform(
            post(f.root())
                .with(jwt().jwt(t -> t.subject(f.actor())))
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(f)))
        .andExpect(status().isUnauthorized());
    mvc.perform(post(f.root() + "/" + id + "/revoke").with(actor(f.actor())))
        .andExpect(status().isPreconditionRequired());
    var other = fixture();
    mvc.perform(get(f.root() + "/" + id).with(actor(other.actor())))
        .andExpect(status().isForbidden());
    mvc.perform(get(other.root() + "/" + id).with(actor(other.actor())))
        .andExpect(status().isNotFound());
    db.update("UPDATE tenant_members SET role='AUDITOR' WHERE tenant_id=?", f.tenant());
    mvc.perform(get(f.root()).with(actor(f.actor()))).andExpect(status().isOk());
    mvc.perform(
            post(f.root() + "/" + id + "/revoke")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET role='CHILD',subject_id=? WHERE tenant_id=?",
        f.subject(),
        f.tenant());
    mvc.perform(get(f.root()).with(actor(f.actor()))).andExpect(status().isForbidden());
  }

  @Test
  void proofCannotCommitAfterAuthorityChangesDuringRemoteRead() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    var evidence = proof(f, id);
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenReturn(identity(f));
    when(gateway.readAgentEvidence(anyString(), anyString(), anyString()))
        .thenAnswer(
            call -> {
              db.update(
                  "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?",
                  f.tenant());
              return Optional.of(evidence);
            });
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isForbidden());
    assertThat(
            db.queryForObject(
                "SELECT state FROM managed_agent_bindings WHERE id=?", String.class, id))
        .isEqualTo("PENDING");
  }

  @Test
  void noReportOrProofCanResurrectAdministratorRevocationDuringRemoteRead() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    var evidence = proof(f, id);
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenReturn(identity(f));
    when(gateway.readAgentEvidence(anyString(), anyString(), anyString()))
        .thenAnswer(
            call -> {
              store.revoke(f.tenant(), f.actor(), id, 1);
              return Optional.of(evidence);
            });
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isPreconditionFailed());
    assertThat(
            db.queryForObject(
                "SELECT nonce FROM managed_agent_bindings WHERE id=?", String.class, id))
        .isNull();
  }

  @Test
  void contractAndProviderIdentityAreRecheckedBeforeCommit() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    var evidence = proof(f, id);
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenReturn(identity(f));
    when(gateway.readAgentEvidence(anyString(), anyString(), anyString()))
        .thenAnswer(
            call -> {
              when(capacity.currentForUpdate(f.tenant())).thenReturn(0L);
              return Optional.of(evidence);
            });
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isConflict());
    assertThat(
            db.queryForObject(
                "SELECT state FROM managed_agent_bindings WHERE id=?", String.class, id))
        .isEqualTo("PENDING");
  }

  @Test
  void expiryClearsNonceAndSlotsWithOneAuditAndAllowsNewRequest() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    db.update(
        "UPDATE managed_agent_bindings SET expires_at=? WHERE id=?",
        System.currentTimeMillis() - 1,
        id);
    mvc.perform(
            get("/api/v1/device-api/managed-agent-challenge")
                .header("Authorization", "Bearer " + f.credential()))
        .andExpect(status().isNoContent());
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isConflict());
    store.expireBatch(100);
    store.expireBatch(100);
    var saved =
        db.queryForMap(
            "SELECT nonce,active_device_id,active_enrollment_id,state FROM managed_agent_bindings"
                + " WHERE id=?",
            id);
    assertThat(saved.get("state")).isEqualTo("EXPIRED");
    assertThat(saved.get("nonce")).isNull();
    assertThat(saved.get("active_device_id")).isNull();
    assertThat(saved.get("active_enrollment_id")).isNull();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE resource_id=? AND"
                    + " action='MANAGED_AGENT_BINDING_EXPIRED'",
                Integer.class,
                id))
        .isEqualTo(1);
    create(f, UUID.randomUUID().toString());
  }

  @Test
  void mismatchedStudentRegistrationAndOccupiedDeviceAreRejected() throws Exception {
    var f = fixture();
    create(f, UUID.randomUUID().toString());
    mvc.perform(
            post(f.root())
                .with(actor(f.actor()))
                .header("Idempotency-Key", UUID.randomUUID().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(f)))
        .andExpect(status().isConflict());
    mvc.perform(
            post(f.root())
                .with(actor(f.actor()))
                .header("Idempotency-Key", UUID.randomUUID().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(f).replace(f.registration(), UUID.randomUUID().toString())))
        .andExpect(status().isConflict());
    String another = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'另一个','AGE_7_12',?)",
        f.tenant(),
        another,
        System.currentTimeMillis());
    db.update("UPDATE managed_enrollment_intents SET subject_id=? WHERE id=?", another, f.intent());
    mvc.perform(
            post(f.root())
                .with(actor(f.actor()))
                .header("Idempotency-Key", UUID.randomUUID().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(f)))
        .andExpect(status().isConflict());
  }

  @Test
  void providerMustExplicitlySupportTrustedEvidenceAndReleaseTrustDefaultsClosed()
      throws Exception {
    var f = fixture();
    when(gateway.supportsAgentBindingEvidence()).thenReturn(false);
    mvc.perform(
            post(f.root())
                .with(actor(f.actor()))
                .header("Idempotency-Key", UUID.randomUUID().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(body(f)))
        .andExpect(status().isServiceUnavailable());
    when(gateway.supportsAgentBindingEvidence()).thenReturn(true);
    assertThat(new ManagedAgentBindingSettings("", "").enabled(gateway)).isFalse();
    assertThat(new ManagedAgentBindingSettings("com.aimanager.child", "").enabled(gateway))
        .isFalse();
  }

  @Test
  void alteredProviderIdentityAndInvalidSignatureNeverConsumeChallenge() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    provider(f, id);
    var wrong =
        new ManagedAndroidGateway.ManagedEnrollmentIdentity(
            identity(f).deviceName(),
            "DEVICE_OWNER",
            identity(f).enrollmentTime(),
            identity(f).enrollmentTokenName(),
            "wrong-nonce");
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenReturn(identity(f), wrong);
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isConflict());
    db.update("UPDATE managed_agent_bindings SET next_verification_at=0 WHERE id=?", id);
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenReturn(identity(f));
    var valid = proof(f, id);
    when(gateway.readAgentEvidence(anyString(), anyString(), anyString()))
        .thenReturn(
            Optional.of(
                new ManagedAgentEvidence(
                    valid.deviceName(),
                    valid.managementMode(),
                    valid.packageName(),
                    valid.applicationState(),
                    valid.signingCertificateSha256(),
                    valid.feedbackKey(),
                    valid.severity(),
                    "invalid-proof",
                    valid.feedbackUpdatedAt(),
                    valid.deviceReportedAt())));
    mvc.perform(
            post(f.root() + "/" + id + "/verify")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isUnprocessableEntity());
    assertThat(
            db.queryForObject(
                "SELECT state FROM managed_agent_bindings WHERE id=?", String.class, id))
        .isEqualTo("PENDING");
    assertThat(
            db.queryForObject(
                "SELECT nonce FROM managed_agent_bindings WHERE id=?", String.class, id))
        .hasSize(43);
  }

  @Test
  void concurrentDuplicateCreateReturnsOneChallengeAndOneAudit() throws Exception {
    var f = fixture();
    String request = UUID.randomUUID().toString();
    var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    var start = new java.util.concurrent.CountDownLatch(1);
    try {
      java.util.concurrent.Callable<String> command =
          () -> {
            start.await();
            return store
                .create(f.tenant(), f.actor(), request, f.intent(), f.device(), f.registration())
                .id();
          };
      var first = pool.submit(command);
      var second = pool.submit(command);
      start.countDown();
      assertThat(first.get(15, java.util.concurrent.TimeUnit.SECONDS))
          .isEqualTo(second.get(15, java.util.concurrent.TimeUnit.SECONDS));
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM managed_agent_bindings WHERE tenant_id=?",
                  Integer.class,
                  f.tenant()))
          .isEqualTo(1);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                      + " action='MANAGED_AGENT_BINDING_REQUESTED'",
                  Integer.class,
                  f.tenant()))
          .isEqualTo(1);
    } finally {
      pool.shutdownNow();
    }
  }

  @Test
  void concurrentProofConsumptionCommitsExactlyOnce() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    var proof = proof(f, id);
    var identity = identity(f);
    var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    var start = new java.util.concurrent.CountDownLatch(1);
    try {
      java.util.concurrent.Callable<Integer> command =
          () -> {
            start.await();
            try {
              store.complete(f.tenant(), f.actor(), id, 1, identity, identity, proof);
              return 200;
            } catch (DomainException failure) {
              return failure.status().value();
            }
          };
      var first = pool.submit(command);
      var second = pool.submit(command);
      start.countDown();
      assertThat(
              List.of(
                  first.get(15, java.util.concurrent.TimeUnit.SECONDS),
                  second.get(15, java.util.concurrent.TimeUnit.SECONDS)))
          .containsExactlyInAnyOrder(200, 412);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM audit_events WHERE resource_id=? AND"
                      + " action='MANAGED_AGENT_BINDING_VERIFIED'",
                  Integer.class,
                  id))
          .isEqualTo(1);
    } finally {
      pool.shutdownNow();
    }
  }
}

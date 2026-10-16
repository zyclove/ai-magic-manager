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
  @Autowired ManagedEnterpriseBindingService realEnterpriseAuthority;

  @Test
  void policyPreviewIncludesApplicationFactsForEachCurrentRegistration() throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    mvc.perform(
            post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                .with(actor(f.actor()))
                .header("If-Match", "\"2\""))
        .andExpect(status().isOk());
    String other = cloneDevice(f, f.subject(), "ACTIVE");
    var draft =
        json.readTree(
            mvc.perform(
                    post("/api/v1/tenants/" + f.tenant() + "/policies")
                        .with(actor(f.actor()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            json.writeValueAsString(
                                Map.of(
                                    "name",
                                    "逐设备应用规则",
                                    "kind",
                                    "POLICY",
                                    "rules",
                                    List.of(
                                        Map.of(
                                            "id",
                                            "reader",
                                            "kind",
                                            "APP_LAUNCH",
                                            "effect",
                                            "DENY",
                                            "applicationId",
                                            app,
                                            "required",
                                            true))))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    when(capacity.currentForUpdate(f.tenant()))
        .thenAnswer(
            call -> {
              assertThat(
                      org.springframework.transaction.support.TransactionSynchronizationManager
                          .getCurrentTransactionIsolationLevel())
                  .isEqualTo(java.sql.Connection.TRANSACTION_READ_COMMITTED);
              return 100L;
            });
    clearInvocations(gateway);
    var preview =
        json.readTree(
            mvc.perform(
                    post("/api/v1/tenants/"
                            + f.tenant()
                            + "/policies/"
                            + draft.get("id").asText()
                            + "/previews")
                        .with(actor(f.actor()))
                        .header("If-Match", "\"0\"")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            json.writeValueAsString(
                                Map.of("deviceIds", List.of(f.device(), other)))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    for (var target : preview.get("targets")) {
      assertThat(target.has("applicationEvidence"))
          .as("preview must carry per-registration application facts")
          .isTrue();
      var fact = target.get("applicationEvidence").get(0);
      assertThat(fact.get("applicationId").asText()).isEqualTo(app);
      assertThat(fact.get("deviceId").asText()).isEqualTo(target.get("deviceId").asText());
      assertThat(fact.get("registrationId").asText())
          .isEqualTo(target.get("registrationId").asText());
      assertThat(fact.get("state").asText())
          .isEqualTo(
              target.get("deviceId").asText().equals(f.device())
                  ? "VERIFIED_IDENTITY"
                  : "UNAVAILABLE");
      assertThat(fact.get("systemControlAvailable").asBoolean()).isFalse();
    }
    assertThat(preview.get("enforceable").asBoolean()).isFalse();
    verify(gateway, never()).readApplicationReport(anyString(), anyString(), anyString());
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
  }

  private String policyDraft(Fixture f, String app) throws Exception {
    return json.readTree(
            mvc.perform(
                    post("/api/v1/tenants/" + f.tenant() + "/policies")
                        .with(actor(f.actor()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            json.writeValueAsString(
                                Map.of(
                                    "name",
                                    "应用核验预览",
                                    "kind",
                                    "POLICY",
                                    "rules",
                                    List.of(
                                        Map.of(
                                            "id",
                                            "reader",
                                            "kind",
                                            "APP_LAUNCH",
                                            "effect",
                                            "DENY",
                                            "applicationId",
                                            app,
                                            "required",
                                            true))))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
        .get("id")
        .asText();
  }

  private org.springframework.test.web.servlet.ResultActions policyPreview(
      Fixture f, String policy, List<String> devices) throws Exception {
    return mvc.perform(
        post("/api/v1/tenants/" + f.tenant() + "/policies/" + policy + "/previews")
            .with(actor(f.actor()))
            .header("If-Match", "\"0\"")
            .contentType(MediaType.APPLICATION_JSON)
            .content(json.writeValueAsString(Map.of("deviceIds", devices))));
  }

  private JsonNode policyPreviewBody(Fixture f, String policy) throws Exception {
    return json.readTree(
        policyPreview(f, policy, List.of(f.device()))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.CsvSource({
    "absent,ABSENT,MANAGED_APPLICATION_EVIDENCE_REQUIRED",
    "expired,STALE,MANAGED_APPLICATION_REPORT_STALE",
    "connector,UNAVAILABLE,MANAGED_APPLICATION_CONNECTOR_UNSUPPORTED",
    "capacity,UNAVAILABLE,MANAGED_ANDROID_CONTRACT_REQUIRED",
    "enterprise,UNAVAILABLE,MANAGED_ANDROID_CONTRACT_REQUIRED",
    "enrollment,UNAVAILABLE,MANAGED_ENROLLMENT_NOT_VERIFIED",
    "revoked,UNAVAILABLE,MANAGED_BINDING_REQUIRED",
    "replacement,UNAVAILABLE,MANAGED_BINDING_REQUIRED",
    "guardian,UNAVAILABLE,MANAGED_APPLICATION_ADMIN_REQUIRED",
    "metadata,UNAVAILABLE,APPLICATION_IDENTITY_METADATA_UNAVAILABLE",
    "disabled,UNAVAILABLE,MANAGED_AGENT_BINDING_UNAVAILABLE"
  })
  void unavailableApplicationEvidenceStillCommitsAnHonestPreview(
      String mutation, String state, String reason) throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    if (!mutation.equals("absent"))
      mvc.perform(
              post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                  .with(actor(f.actor()))
                  .header("If-Match", "\"2\""))
          .andExpect(status().isOk());
    String policy = policyDraft(f, app);
    switch (mutation) {
      case "expired" ->
          db.update(
              "UPDATE managed_application_evidence SET expires_at=0 WHERE binding_id=?",
              binding.id());
      case "connector" -> when(gateway.supportsApplicationReports()).thenReturn(false);
      case "capacity" -> when(capacity.currentForUpdate(f.tenant())).thenReturn(0L);
      case "enterprise" ->
          when(enterprises.requireActive(f.tenant()))
              .thenAnswer(call -> realEnterpriseAuthority.requireActive(f.tenant()));
      case "enrollment" ->
          db.update(
              "UPDATE managed_enrollment_intents SET state='CANCELLED' WHERE tenant_id=?",
              f.tenant());
      case "revoked" -> store.revoke(f.tenant(), f.actor(), binding.id(), 2);

      case "guardian" ->
          db.update("UPDATE tenant_members SET role='GUARDIAN' WHERE tenant_id=?", f.tenant());
      case "metadata" ->
          db.update(
              "UPDATE application_definitions SET identity_hash=? WHERE tenant_id=?",
              "0".repeat(64),
              f.tenant());
      case "disabled" -> when(gateway.supportsAgentBindingEvidence()).thenReturn(false);
      default -> {}
    }
    clearInvocations(gateway);
    String targetId =
        mutation.equals("replacement") ? cloneDevice(f, f.subject(), "ACTIVE") : f.device();
    var preview =
        json.readTree(
            policyPreview(f, policy, List.of(targetId))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    var fact = preview.get("targets").get(0).get("applicationEvidence").get(0);
    assertThat(fact.get("deviceId").asText()).isEqualTo(targetId);
    if (mutation.equals("replacement"))
      assertThat(fact.get("registrationId").asText()).isNotEqualTo(f.registration());
    assertThat(fact.get("state").asText()).isEqualTo(state);
    assertThat(fact.get("reasonCode").asText()).isEqualTo(reason);
    assertThat(fact.get("systemControlAvailable").asBoolean()).isFalse();
    assertThat(fact.get("profileScope").asText()).isEqualTo("UNKNOWN");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM policy_previews WHERE tenant_id=?",
                Integer.class,
                f.tenant()))
        .isEqualTo(1);
    assertThat(preview.toString())
        .doesNotContain(
            f.credential(),
            f.enrollmentNonce(),
            f.providerDevice(),
            "contextRevision",
            "keyThumbprint");
    // The enclosing snapshot contains administrator-declared signing digests; the fact DTO does
    // not.
    assertThat(fact.toString()).doesNotContain(CERT);
    verify(gateway, never()).readApplicationReport(anyString(), anyString(), anyString());
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {"refresh", "expiry", "revoke", "device-revoke", "connector", "contract"})
  void changedApplicationFactsRequireAnotherPreviewBeforePublication(String mutation)
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    String path = applicationEvidencePath(f, binding.id(), app);
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk());
    String policy = policyDraft(f, app);
    var preview = policyPreviewBody(f, policy);
    assertThat(preview.get("expiresAt").asLong())
        .isLessThanOrEqualTo(
            preview
                .get("targets")
                .get(0)
                .get("applicationEvidence")
                .get(0)
                .get("expiresAt")
                .asLong());
    switch (mutation) {
      case "refresh" -> {
        db.update(
            "UPDATE managed_application_evidence SET next_attempt_at=0 WHERE binding_id=?",
            binding.id());
        mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
            .andExpect(status().isOk());
      }
      case "expiry" ->
          db.update(
              "UPDATE managed_application_evidence SET expires_at=0 WHERE binding_id=?",
              binding.id());
      case "revoke" -> store.revoke(f.tenant(), f.actor(), binding.id(), 2);
      case "device-revoke" ->
          mvc.perform(
                  post("/api/v1/tenants/" + f.tenant() + "/devices/" + f.device() + "/revoke")
                      .with(actor(f.actor())))
              .andExpect(status().isNoContent());
      case "connector" ->
          when(gateway.applicationReportRevision()).thenReturn("changed-report-revision");
      case "contract" -> when(capacity.currentForUpdate(f.tenant())).thenReturn(0L);
    }
    mvc.perform(
            post("/api/v1/tenants/" + f.tenant() + "/policies/" + policy + "/publications")
                .with(actor(f.actor()))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", UUID.randomUUID().toString())
                .contentType(MediaType.APPLICATION_JSON)
                .content(
                    json.writeValueAsString(
                        Map.of(
                            "previewId",
                            preview.get("id").asText(),
                            "previewHash",
                            preview.get("hash").asText(),
                            "mode",
                            "CONFIGURE_ONLY"))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("PREVIEW_STALE"));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM policy_versions WHERE tenant_id=?",
                Integer.class,
                f.tenant()))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND"
                    + " operation='policy.publish'",
                Integer.class,
                f.tenant()))
        .isZero();
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(booleans = {false, true})
  void policyEvidenceNeverDowngradesAuthorityOrDatabaseFailures(boolean databaseFailure)
      throws Exception {
    var f = fixture();
    verifiedBinding(f);
    String app = application(f, "ANDROID");
    String policy = policyDraft(f, app);
    if (databaseFailure)
      when(capacity.currentForUpdate(f.tenant()))
          .thenThrow(
              new org.springframework.dao.TransientDataAccessResourceException(
                  "fixture database failure"));
    else when(enterprises.requireActive(f.tenant())).thenThrow(DomainException.denied());
    policyPreview(f, policy, List.of(f.device()))
        .andExpect(status().is(databaseFailure ? 500 : 403));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM policy_previews WHERE tenant_id=?",
                Integer.class,
                f.tenant()))
        .isZero();
  }

  @Test
  void policyEvidenceRejectsAnotherTenantsDeviceBeforeSavingPreview() throws Exception {
    var f = fixture();
    var other = fixture();
    String app = application(f, "ANDROID");
    String policy = policyDraft(f, app);
    policyPreview(f, policy, List.of(f.device(), other.device())).andExpect(status().isForbidden());
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM policy_previews WHERE tenant_id=?",
                Integer.class,
                f.tenant()))
        .isZero();
  }

  @Test
  void policyEvidenceWaiterReadsCommittedVersionAfterBindingLock() throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    mvc.perform(
            post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                .with(actor(f.actor()))
                .header("If-Match", "\"2\""))
        .andExpect(status().isOk());
    String policy = policyDraft(f, app);
    var locked = new java.util.concurrent.CountDownLatch(1);
    var release = new java.util.concurrent.CountDownLatch(1);
    var started = new java.util.concurrent.CountDownLatch(1);
    when(capacity.currentForUpdate(f.tenant()))
        .thenAnswer(
            call -> {
              assertThat(
                      org.springframework.transaction.support.TransactionSynchronizationManager
                          .getCurrentTransactionIsolationLevel())
                  .isEqualTo(java.sql.Connection.TRANSACTION_READ_COMMITTED);
              // The reader reached the authority chain immediately before taking the binding lock.
              started.countDown();
              return 100L;
            });
    var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    try {
      var writer =
          pool.submit(
              () ->
                  new TransactionTemplate(transactions)
                      .executeWithoutResult(
                          s -> {
                            db.queryForList(
                                "SELECT id FROM managed_agent_bindings WHERE tenant_id=? AND id=?"
                                    + " FOR UPDATE",
                                f.tenant(),
                                binding.id());
                            db.update(
                                "UPDATE managed_application_evidence SET version=version+1 WHERE"
                                    + " binding_id=?",
                                binding.id());
                            locked.countDown();
                            try {
                              if (!release.await(10, java.util.concurrent.TimeUnit.SECONDS))
                                throw new AssertionError("Writer deadline");
                            } catch (InterruptedException interrupted) {
                              Thread.currentThread().interrupt();
                              throw new AssertionError(interrupted);
                            }
                          }));
      assertThat(locked.await(5, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
      var reader =
          pool.submit(
              () -> {
                return policyPreviewBody(f, policy);
              });
      assertThat(started.await(5, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
      org.assertj.core.api.Assertions.assertThatThrownBy(
              () -> reader.get(200, java.util.concurrent.TimeUnit.MILLISECONDS))
          .isInstanceOf(java.util.concurrent.TimeoutException.class);
      release.countDown();
      writer.get(10, java.util.concurrent.TimeUnit.SECONDS);
      var preview = reader.get(10, java.util.concurrent.TimeUnit.SECONDS);
      long version =
          db.queryForObject(
              "SELECT version FROM managed_application_evidence WHERE binding_id=?",
              Long.class,
              binding.id());
      assertThat(
              preview
                  .get("targets")
                  .get(0)
                  .get("applicationEvidence")
                  .get(0)
                  .get("evidenceVersion")
                  .asLong())
          .isEqualTo(version);
    } finally {
      release.countDown();
      pool.shutdownNow();
    }
  }

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
    when(gateway.applicationReportRevision()).thenReturn("fixture-application-report-v1");
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
  void verifiedContextLoadsCurrentAuthorizedRegistrationWithoutReusingChallengeExpiry()
      throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    var identity = identity(f);
    var verified = store.complete(f.tenant(), f.actor(), id, 1, identity, identity, proof(f, id));
    // 挑战截止只限制一次性绑定；已验证绑定的当前有效性由当前授权和注册决定。
    db.update("UPDATE managed_agent_bindings SET expires_at=1 WHERE id=?", id);
    var context =
        org.assertj.core.api.Assertions.catchThrowableOfType(
            () -> store.requireVerifiedContext(f.tenant(), f.actor(), id, verified.version()),
            DomainException.class);
    assertThat(context).as("current verified binding must be available").isNull();
    var current = store.requireVerifiedContext(f.tenant(), f.actor(), id, verified.version());
    assertThat(current.tenantId()).isEqualTo(f.tenant());
    assertThat(current.actorId()).isEqualTo(f.actor());
    assertThat(current.authorityVersion()).isZero();
    assertThat(current.subjectId()).isEqualTo(f.subject());
    assertThat(current.deviceId()).isEqualTo(f.device());
    assertThat(current.registrationId()).isEqualTo(f.registration());
    assertThat(current.keyThumbprint()).isEqualTo(f.key().computeThumbprint().toString());
    assertThat(current.bindingId()).isEqualTo(id);
    assertThat(current.bindingVersion()).isEqualTo(2);
    assertThat(current.enrollmentId()).isEqualTo(f.intent());
    assertThat(current.enrollmentVersion()).isEqualTo(3);
    assertThat(current.provider()).isEqualTo("LOCAL_TEST");
    assertThat(current.enterpriseId()).isEqualTo(f.enterprise());
    assertThat(current.enterpriseBindingVersion()).isEqualTo(1);
    assertThat(current.providerDeviceId()).isEqualTo(f.providerDevice());
    assertThat(current.managementMode()).isEqualTo("DEVICE_OWNER");
    assertThat(current.bindingVerifiedAt()).isEqualTo(verified.verifiedAt());
    assertThat(current.agentPackageName()).isEqualTo("com.aimanager.child");
    assertThat(current.agentTrustRevision()).hasSize(64);
    assertThat(
            db.queryForObject(
                "SELECT agent_trust_revision FROM managed_agent_bindings WHERE id=?",
                String.class,
                id))
        .isEqualTo(current.agentTrustRevision());
    assertThat(current.toString())
        .doesNotContain(f.tenant(), f.device(), f.actor(), f.enterprise());
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
    verify(gateway, never()).readAgentEvidence(anyString(), anyString(), anyString());
    verify(gateway, never()).readApplicationReport(anyString(), anyString(), anyString());
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {"GUARDIAN", "TEACHER", "CHILD", "AUDITOR"})
  void currentVerifiedContextRejectsReadOnlyAndOutOfScopeRoles(String role) throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
    var failure =
        org.assertj.core.api.Assertions.catchThrowableOfType(
            () ->
                store.requireVerifiedContext(
                    f.tenant(), f.actor(), binding.id(), binding.version()),
            DomainException.class);
    assertThat(failure).isNotNull();
    assertThat(failure.status().value()).isEqualTo(403);
  }

  @Test
  void currentVerifiedContextReloadsMembershipEpochAndAcceptsOrganizationAdministrator()
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    var before =
        store.requireVerifiedContext(f.tenant(), f.actor(), binding.id(), binding.version());
    db.update(
        "UPDATE tenant_members SET role='ORG_ADMIN',version=version+1 WHERE tenant_id=?",
        f.tenant());
    var after =
        store.requireVerifiedContext(f.tenant(), f.actor(), binding.id(), binding.version());
    assertThat(before.authorityVersion()).isZero();
    assertThat(after.authorityVersion()).isEqualTo(1);
    assertThat(after).isNotEqualTo(before);
    db.update(
        "UPDATE tenant_members SET revoked_at=? WHERE tenant_id=?",
        java.sql.Timestamp.from(Instant.now()),
        f.tenant());
    var failure =
        org.assertj.core.api.Assertions.catchThrowableOfType(
            () ->
                store.requireVerifiedContext(
                    f.tenant(), f.actor(), binding.id(), binding.version()),
            DomainException.class);
    assertThat(failure).isNotNull();
    assertThat(failure.status().value()).isEqualTo(403);
  }

  @Test
  void currentVerifiedContextDoesNotExposeAnotherTenantsBinding() throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    var other = fixture();
    var failure =
        org.assertj.core.api.Assertions.catchThrowableOfType(
            () ->
                store.requireVerifiedContext(
                    other.tenant(), other.actor(), binding.id(), binding.version()),
            DomainException.class);
    assertThat(failure).isNotNull();
    assertThat(failure.errorCode()).isEqualTo("MANAGED_BINDING_NOT_FOUND");
  }

  @Test
  void currentVerifiedContextRejectsPendingAndExplicitlyRevokedBindings() throws Exception {
    var f = fixture();
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    assertContextFailure(f, id, 1, "MANAGED_BINDING_NOT_VERIFIED");
    var identity = identity(f);
    store.complete(f.tenant(), f.actor(), id, 1, identity, identity, proof(f, id));
    store.revoke(f.tenant(), f.actor(), id, 2);
    assertContextFailure(f, id, 3, "MANAGED_BINDING_NOT_VERIFIED");
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.CsvSource({
    "SUBJECT_ARCHIVED,MANAGED_BINDING_SUBJECT_INACTIVE",
    "DEVICE_REVOKED,MANAGED_BINDING_DEVICE_MISMATCH",
    "DEVICE_PENDING,MANAGED_BINDING_DEVICE_MISMATCH",
    "KEY_CHANGED,MANAGED_BINDING_CONTEXT_CHANGED",
    "PACKAGE_CHANGED,MANAGED_BINDING_CONTEXT_CHANGED",
    "PROVIDER_CHANGED,MANAGED_BINDING_PROVIDER_CHANGED",
    "ENTERPRISE_CHANGED,MANAGED_ENTERPRISE_CHANGED",
    "ENROLLMENT_CANCELLED,MANAGED_ENROLLMENT_NOT_VERIFIED",
    "ENROLLMENT_MODE_CHANGED,MANAGED_BINDING_MODE_UNSUPPORTED",
    "PROVIDER_DEVICE_CHANGED,MANAGED_BINDING_CONTEXT_CHANGED",
    "VERIFIED_AT_MISSING,MANAGED_BINDING_VERIFICATION_INVALID",
    "VERIFIED_AT_FUTURE,MANAGED_BINDING_VERIFICATION_INVALID",
    "VERIFIED_AT_BEFORE_REQUEST,MANAGED_BINDING_VERIFICATION_INVALID",
    "DEVICE_SLOT_CLEARED,MANAGED_BINDING_VERIFICATION_INVALID",
    "ENROLLMENT_SLOT_CLEARED,MANAGED_BINDING_VERIFICATION_INVALID",
    "CHALLENGE_NOT_CONSUMED,MANAGED_BINDING_VERIFICATION_INVALID",
    "TRUST_REVISION_MISSING,MANAGED_BINDING_RELEASE_TRUST_CHANGED",
    "TRUST_REVISION_CHANGED,MANAGED_BINDING_RELEASE_TRUST_CHANGED",
    "CONTRACT_REVOKED,MANAGED_ANDROID_CONTRACT_REQUIRED",
    "PROVIDER_UNAVAILABLE,MANAGED_AGENT_BINDING_UNAVAILABLE",
    "BINDING_EVIDENCE_UNSUPPORTED,MANAGED_AGENT_BINDING_UNAVAILABLE"
  })
  void currentVerifiedContextRejectsChangedAuthorityAndInvalidBindingFacts(
      String mutation, String code) throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    switch (mutation) {
      case "SUBJECT_ARCHIVED" ->
          db.update(
              "UPDATE subjects SET archived_at=1 WHERE tenant_id=? AND id=?",
              f.tenant(),
              f.subject());
      case "DEVICE_REVOKED" ->
          db.update("UPDATE devices SET state='REVOKED' WHERE id=?", f.device());
      case "DEVICE_PENDING" ->
          db.update("UPDATE devices SET state='AWAITING_CONFIRMATION' WHERE id=?", f.device());
      case "KEY_CHANGED" ->
          db.update("UPDATE devices SET key_thumbprint=? WHERE id=?", "b".repeat(43), f.device());
      case "PACKAGE_CHANGED" ->
          db.update(
              "UPDATE managed_agent_bindings SET package_name='com.other.agent' WHERE id=?",
              binding.id());
      case "PROVIDER_CHANGED" -> when(gateway.providerCode()).thenReturn("ANOTHER_PROVIDER");
      case "ENTERPRISE_CHANGED" ->
          when(enterprises.requireActive(f.tenant()))
              .thenReturn(
                  new ManagedEnterpriseAuthority.EnterpriseAccess("LOCAL_TEST", f.enterprise(), 2));
      case "ENROLLMENT_CANCELLED" ->
          db.update(
              "UPDATE managed_enrollment_intents SET state='CANCELLED' WHERE id=?", f.intent());
      case "ENROLLMENT_MODE_CHANGED" ->
          db.update(
              "UPDATE managed_enrollment_intents SET provider_mode='PROFILE_OWNER' WHERE id=?",
              f.intent());
      case "PROVIDER_DEVICE_CHANGED" ->
          db.update(
              "UPDATE managed_enrollment_intents SET provider_device_id='replacement_device' WHERE"
                  + " id=?",
              f.intent());
      case "VERIFIED_AT_MISSING" ->
          db.update("UPDATE managed_agent_bindings SET verified_at=NULL WHERE id=?", binding.id());
      case "VERIFIED_AT_FUTURE" ->
          db.update(
              "UPDATE managed_agent_bindings SET verified_at=? WHERE id=?",
              System.currentTimeMillis() + 60_000,
              binding.id());
      case "VERIFIED_AT_BEFORE_REQUEST" ->
          db.update(
              "UPDATE managed_agent_bindings SET verified_at=created_at-1 WHERE id=?",
              binding.id());
      case "DEVICE_SLOT_CLEARED" ->
          db.update(
              "UPDATE managed_agent_bindings SET active_device_id=NULL WHERE id=?", binding.id());
      case "ENROLLMENT_SLOT_CLEARED" ->
          db.update(
              "UPDATE managed_agent_bindings SET active_enrollment_id=NULL WHERE id=?",
              binding.id());
      case "CHALLENGE_NOT_CONSUMED" ->
          db.update(
              "UPDATE managed_agent_bindings SET nonce=? WHERE id=?",
              SecretMaterial.token(),
              binding.id());
      case "TRUST_REVISION_MISSING" ->
          db.update(
              "UPDATE managed_agent_bindings SET agent_trust_revision=NULL WHERE id=?",
              binding.id());
      case "TRUST_REVISION_CHANGED" ->
          db.update(
              "UPDATE managed_agent_bindings SET agent_trust_revision=? WHERE id=?",
              "b".repeat(64),
              binding.id());
      case "CONTRACT_REVOKED" -> when(capacity.currentForUpdate(f.tenant())).thenReturn(0L);
      case "PROVIDER_UNAVAILABLE" -> when(gateway.available()).thenReturn(false);
      case "BINDING_EVIDENCE_UNSUPPORTED" ->
          when(gateway.supportsAgentBindingEvidence()).thenReturn(false);
      default -> throw new AssertionError("Unknown authority mutation");
    }
    assertContextFailure(f, binding.id(), binding.version(), code);
  }

  @Test
  void currentVerifiedContextRejectsAnOldBindingVersionAndKeepsItsLedgerUnchanged()
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    assertContextFailure(f, binding.id(), 1, "RESOURCE_VERSION_CONFLICT");
    var before = db.queryForMap("SELECT * FROM managed_agent_bindings WHERE id=?", binding.id());
    store.requireVerifiedContext(f.tenant(), f.actor(), binding.id(), binding.version());
    assertThat(db.queryForMap("SELECT * FROM managed_agent_bindings WHERE id=?", binding.id()))
        .isEqualTo(before);
  }

  @Test
  void currentVerifiedContextRequiresBindingAndEnrollmentToBelongToTheSameStudent()
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String otherSubject = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'同机构另一学生','AGE_7_12',?)",
        f.tenant(),
        otherSubject,
        System.currentTimeMillis());
    // 两个独立外键不能证明绑定和受管注册归属同一学生。
    db.update(
        "UPDATE managed_agent_bindings SET subject_id=? WHERE id=?", otherSubject, binding.id());
    assertContextFailure(f, binding.id(), binding.version(), "MANAGED_BINDING_CONTEXT_CHANGED");
  }

  @Test
  void currentVerifiedContextIncludesEnrollmentRevisionEvenWhenDeviceIdentityIsUnchanged()
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    var before =
        store.requireVerifiedContext(f.tenant(), f.actor(), binding.id(), binding.version());
    db.update("UPDATE managed_enrollment_intents SET version=version+1 WHERE id=?", f.intent());
    var after =
        store.requireVerifiedContext(f.tenant(), f.actor(), binding.id(), binding.version());
    assertThat(after.enrollmentVersion()).isEqualTo(4);
    assertThat(after.deviceId()).isEqualTo(before.deviceId());
    assertThat(after.registrationId()).isEqualTo(before.registrationId());
    assertThat(after).isNotEqualTo(before);
  }

  @Test
  void agentTrustRevisionChangesOnlyWithNormalizedReleaseIdentity() {
    String otherCertificate = "b".repeat(64);
    var first =
        new ManagedAgentBindingSettings("com.aimanager.child", CERT + "," + otherCertificate);
    var reordered =
        new ManagedAgentBindingSettings(
            " com.aimanager.child ", " " + otherCertificate + "," + CERT);
    var revoked = new ManagedAgentBindingSettings("com.aimanager.child", otherCertificate);
    var otherPackage =
        new ManagedAgentBindingSettings("com.aimanager.other", CERT + "," + otherCertificate);
    assertThat(first.trustRevision()).isEqualTo(reordered.trustRevision());
    assertThat(first.trustRevision()).isNotEqualTo(revoked.trustRevision());
    assertThat(first.trustRevision()).isNotEqualTo(otherPackage.trustRevision());
  }

  private ManagedAgentBindingStore.View verifiedBinding(Fixture f) throws Exception {
    String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    var identity = identity(f);
    return store.complete(f.tenant(), f.actor(), id, 1, identity, identity, proof(f, id));
  }

  @Test
  void applicationEvidenceRefreshPersistsCurrentIdentityOutsideProviderTransactions()
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    when(gateway.supportsApplicationReports()).thenReturn(true);
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenAnswer(
            call -> {
              assertThat(
                      org.springframework.transaction.support.TransactionSynchronizationManager
                          .isActualTransactionActive())
                  .isFalse();
              return identity(f);
            });
    when(gateway.readApplicationReport(f.enterprise(), f.providerDevice(), "org.example.Reader"))
        .thenAnswer(
            call -> {
              assertThat(
                      org.springframework.transaction.support.TransactionSynchronizationManager
                          .isActualTransactionActive())
                  .isFalse();
              return Optional.of(
                  new com.aimanager.managedandroid.ManagedApplicationReport(
                      identity(f).deviceName(),
                      "DEVICE_OWNER",
                      "org.example.Reader",
                      "INSTALLED",
                      List.of(CERT),
                      Instant.now().toString()));
            });
    mvc.perform(
            post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                .with(actor(f.actor()))
                .header("If-Match", "\"" + binding.version() + "\""))
        .andExpect(status().isOk())
        .andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"))
        .andExpect(jsonPath("$.profileScope").value("UNKNOWN"))
        .andExpect(jsonPath("$.systemControlAvailable").value(false));
    assertThat(
            db.queryForObject(
                "SELECT state FROM managed_application_evidence WHERE tenant_id=? AND binding_id=?"
                    + " AND application_id=?",
                String.class,
                f.tenant(),
                binding.id(),
                app))
        .isEqualTo("VERIFIED");
    verify(gateway, times(2)).readEnrollmentIdentity(f.enterprise(), f.providerDevice());
    verify(gateway).readApplicationReport(f.enterprise(), f.providerDevice(), "org.example.Reader");
  }

  private String application(Fixture f, String platform) throws Exception {
    return json.readTree(
            mvc.perform(
                    post("/api/v1/tenants/" + f.tenant() + "/applications")
                        .with(actor(f.actor()))
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            json.writeValueAsString(
                                Map.of(
                                    "displayName",
                                    "学习应用",
                                    "platform",
                                    platform,
                                    "profile",
                                    "PRIMARY",
                                    "packageName",
                                    "org.example.Reader",
                                    "signingDigests",
                                    List.of(CERT)))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString())
        .get("id")
        .asText();
  }

  private String applicationEvidencePath(Fixture f, String binding, String app) {
    return f.root() + "/" + binding + "/applications/" + app + "/evidence";
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {
        "MISSING",
        "SIGNER",
        "STALE",
        "MODE",
        "NOT_INSTALLED",
        "PROVENANCE",
        "PROVENANCE_TIME"
      })
  void applicationEvidenceRejectsMissingOrUntrustedFactsWithoutRetainingSigners(String variant)
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    if (variant.equals("MISSING"))
      when(gateway.readApplicationReport(anyString(), anyString(), anyString()))
          .thenReturn(Optional.empty());
    else if (variant.startsWith("PROVENANCE")) {
      var wrong =
          new ManagedAndroidGateway.ManagedEnrollmentIdentity(
              identity(f).deviceName(),
              "DEVICE_OWNER",
              variant.equals("PROVENANCE_TIME")
                  ? Instant.parse(identity(f).enrollmentTime()).plusSeconds(1).toString()
                  : identity(f).enrollmentTime(),
              identity(f).enrollmentTokenName(),
              variant.equals("PROVENANCE_TIME") ? f.enrollmentNonce() : "wrong-nonce");
      when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
          .thenReturn(identity(f), wrong);
    } else
      when(gateway.readApplicationReport(anyString(), anyString(), anyString()))
          .thenAnswer(
              call ->
                  Optional.of(
                      new com.aimanager.managedandroid.ManagedApplicationReport(
                          identity(f).deviceName(),
                          variant.equals("MODE") ? "PROFILE_OWNER" : "DEVICE_OWNER",
                          "org.example.Reader",
                          variant.equals("NOT_INSTALLED") ? "REMOVED" : "INSTALLED",
                          List.of(variant.equals("SIGNER") ? "b".repeat(64) : CERT),
                          (variant.equals("STALE")
                                  ? Instant.now().minusSeconds(3601)
                                  : Instant.now())
                              .toString())));
    mvc.perform(
            post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                .with(actor(f.actor()))
                .header("If-Match", "\"" + binding.version() + "\""))
        .andExpect(status().isOk())
        .andExpect(
            jsonPath("$.state").value(variant.equals("MISSING") ? "WAITING_REPORT" : "REJECTED"))
        .andExpect(jsonPath("$.systemControlAvailable").value(false));
    var row =
        db.queryForMap(
            "SELECT signing_digests_json,reported_at,retrieved_at,expires_at FROM"
                + " managed_application_evidence WHERE binding_id=?",
            binding.id());
    assertThat(row.values()).allMatch(java.util.Objects::isNull);
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {"REVOKE", "ROLE", "AUTHORITY_VERSION", "CONTRACT", "DEVICE", "CATALOG"})
  void applicationEvidenceRechecksCurrentAuthorityAfterNetworkRead(String mutation)
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    when(gateway.readApplicationReport(anyString(), anyString(), anyString()))
        .thenAnswer(
            call -> {
              assertThat(
                      org.springframework.transaction.support.TransactionSynchronizationManager
                          .isActualTransactionActive())
                  .isFalse();
              switch (mutation) {
                case "REVOKE" ->
                    store.revoke(f.tenant(), f.actor(), binding.id(), binding.version());
                case "ROLE" ->
                    db.update(
                        "UPDATE tenant_members SET role='CHILD' WHERE tenant_id=?", f.tenant());
                case "AUTHORITY_VERSION" ->
                    db.update(
                        "UPDATE tenant_members SET version=version+1 WHERE tenant_id=?",
                        f.tenant());
                case "CONTRACT" -> when(capacity.currentForUpdate(f.tenant())).thenReturn(0L);
                case "DEVICE" ->
                    db.update(
                        "UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?",
                        f.tenant(),
                        f.device());
                case "CATALOG" ->
                    db.update(
                        "UPDATE application_definitions SET created_at=NULL WHERE tenant_id=? AND"
                            + " id=?",
                        f.tenant(),
                        app);
                default -> throw new AssertionError();
              }
              return Optional.of(applicationReport(f));
            });
    mvc.perform(
            post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                .with(actor(f.actor()))
                .header("If-Match", "\"" + binding.version() + "\""))
        .andExpect(
            status().is(mutation.equals("ROLE") ? 403 : mutation.equals("REVOKE") ? 412 : 409));
    assertThat(
            db.queryForObject(
                "SELECT signing_digests_json FROM managed_application_evidence WHERE binding_id=?",
                String.class,
                binding.id()))
        .isNull();
  }

  @Test
  void applicationEvidenceReadDoesNotCallProviderOrExtendExpiryAndNewBindingCannotInheritIt()
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    String path = applicationEvidencePath(f, binding.id(), app);
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk());
    long expires =
        db.queryForObject(
            "SELECT expires_at FROM managed_application_evidence WHERE binding_id=?",
            Long.class,
            binding.id());
    mvc.perform(get(path).with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"));
    assertThat(
            db.queryForObject(
                "SELECT expires_at FROM managed_application_evidence WHERE binding_id=?",
                Long.class,
                binding.id()))
        .isEqualTo(expires);
    verify(gateway, times(1)).readApplicationReport(anyString(), anyString(), anyString());
    db.update(
        "UPDATE managed_application_evidence SET expires_at=0 WHERE binding_id=?", binding.id());
    mvc.perform(get(path).with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("STALE"));
    store.revoke(f.tenant(), f.actor(), binding.id(), 2);
    var second = verifiedBinding(f);
    mvc.perform(
            get(applicationEvidencePath(f, second.id(), app))
                .with(actor(f.actor()))
                .header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("ABSENT"));
  }

  @Test
  void missingReportAfterRefreshInvalidatesPreviousVerifiedFact() throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    String path = applicationEvidencePath(f, binding.id(), app);
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"));
    db.update(
        "UPDATE managed_application_evidence SET next_attempt_at=0 WHERE binding_id=?",
        binding.id());
    when(gateway.readApplicationReport(anyString(), anyString(), anyString()))
        .thenReturn(Optional.empty());
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("WAITING_REPORT"));
    mvc.perform(get(path).with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("WAITING_REPORT"));
  }

  @Test
  void recentProviderReportStillMustFollowApplicationIdentityDeclaration() throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    long declared =
        db.queryForObject(
            "SELECT created_at FROM application_definitions WHERE id=?", Long.class, app);
    when(gateway.readApplicationReport(anyString(), anyString(), anyString()))
        .thenReturn(
            Optional.of(
                new com.aimanager.managedandroid.ManagedApplicationReport(
                    identity(f).deviceName(),
                    "DEVICE_OWNER",
                    "org.example.Reader",
                    "INSTALLED",
                    List.of(CERT),
                    Instant.ofEpochMilli(declared - 1).toString())));
    mvc.perform(
            post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                .with(actor(f.actor()))
                .header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("REJECTED"))
        .andExpect(jsonPath("$.reasonCode").value("MANAGED_APPLICATION_REPORT_STALE"));
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {"null", "[null]", "[\"private-invalid-signer\"]"})
  void damagedPersistedSigningFactsAreNeverReused(String damaged) throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    String path = applicationEvidencePath(f, binding.id(), app);
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk());
    db.update(
        "UPDATE managed_application_evidence SET signing_digests_json=? WHERE binding_id=?",
        damaged,
        binding.id());
    var response =
        mvc.perform(get(path).with(actor(f.actor())).header("If-Match", "\"2\""))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.state").value("STALE"))
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertThat(response).doesNotContain("private-invalid-signer");
  }

  @Test
  void unsupportedApplicationPlatformStopsBeforeProviderRead() throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID_TV");
    applicationProvider(f);
    mvc.perform(
            post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                .with(actor(f.actor()))
                .header("If-Match", "\"2\""))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("MANAGED_APPLICATION_PLATFORM_MISMATCH"));
    verify(gateway, never()).readApplicationReport(anyString(), anyString(), anyString());
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM managed_application_evidence WHERE tenant_id=?",
                Long.class,
                f.tenant()))
        .isZero();
  }

  private void applicationProvider(Fixture f) {
    when(gateway.supportsApplicationReports()).thenReturn(true);
    when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
        .thenReturn(identity(f));
    when(gateway.readApplicationReport(f.enterprise(), f.providerDevice(), "org.example.Reader"))
        .thenAnswer(call -> Optional.of(applicationReport(f)));
  }

  @Test
  void failedProviderReadIsSanitizedAndRefreshCooldownIsEnforced() throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    when(gateway.readApplicationReport(anyString(), anyString(), anyString()))
        .thenThrow(new IllegalStateException("secret-upstream-response"));
    String path = applicationEvidencePath(f, binding.id(), app);
    var body =
        mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.state").value("FAILED"))
            .andExpect(jsonPath("$.reasonCode").value("MANAGED_APPLICATION_PROVIDER_UNAVAILABLE"))
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertThat(body).doesNotContain("secret-upstream-response");
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isTooManyRequests());
    verify(gateway, times(1)).readApplicationReport(anyString(), anyString(), anyString());
  }

  @Test
  void anotherCurrentManagerWithDifferentAuthorityEpochCanReadTheSameDeviceFact() throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    String path = applicationEvidencePath(f, binding.id(), app);
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"));
    String second = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,version)"
            + " VALUES(?,?,?,'ORG_ADMIN',19)",
        f.tenant(),
        second,
        ActorKeys.key(second));
    mvc.perform(get(path).with(actor(second)).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"));
    verify(gateway, times(1)).readApplicationReport(anyString(), anyString(), anyString());
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(
      strings = {"CHILD", "GUARDIAN", "AUDITOR", "TEACHER"})
  void applicationEvidenceCannotBeReadOrRefreshedByNonInstitutionManagers(String role)
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
    String path = applicationEvidencePath(f, binding.id(), app);
    mvc.perform(get(path).with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isForbidden());
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isForbidden());
    verify(gateway, never()).readApplicationReport(anyString(), anyString(), anyString());
  }

  @Test
  void applicationEvidenceRequiresBindingVersionRecentMfaAndTenantScope() throws Exception {
    var f = fixture();
    var other = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    String path = applicationEvidencePath(f, binding.id(), app);
    mvc.perform(
            post(path + "/refresh")
                .with(jwt().jwt(t -> t.subject(f.actor())))
                .header("If-Match", "\"2\""))
        .andExpect(status().isUnauthorized());
    mvc.perform(post(path + "/refresh").with(actor(other.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isForbidden());
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isPreconditionFailed());
    mvc.perform(get(path).with(actor(f.actor()))).andExpect(status().isPreconditionRequired());
    verify(gateway, never()).readApplicationReport(anyString(), anyString(), anyString());
  }

  @org.junit.jupiter.params.ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(booleans = {false, true})
  void expiredSlowAttemptCannotOverwriteNewerEvidence(boolean lateFailure) throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    String path = applicationEvidencePath(f, binding.id(), app);
    var entered = new java.util.concurrent.CountDownLatch(1);
    var release = new java.util.concurrent.CountDownLatch(1);
    var calls = new java.util.concurrent.atomic.AtomicInteger();
    when(gateway.readApplicationReport(anyString(), anyString(), anyString()))
        .thenAnswer(
            call -> {
              if (calls.incrementAndGet() == 1) {
                entered.countDown();
                if (!release.await(15, java.util.concurrent.TimeUnit.SECONDS))
                  throw new AssertionError("Owned fixture deadline");
                if (lateFailure) throw new IllegalStateException("old-provider-error");
                return Optional.empty();
              }
              return Optional.of(applicationReport(f));
            });
    var pool = java.util.concurrent.Executors.newSingleThreadExecutor();
    try {
      var first =
          pool.submit(
              () ->
                  mvc.perform(
                      post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\"")));
      assertThat(entered.await(10, java.util.concurrent.TimeUnit.SECONDS)).isTrue();
      mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
          .andExpect(status().isConflict());
      db.update(
          "UPDATE managed_application_evidence SET attempt_expires_at=0,next_attempt_at=0 WHERE"
              + " binding_id=?",
          binding.id());
      mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"));
      release.countDown();
      first.get(10, java.util.concurrent.TimeUnit.SECONDS).andExpect(status().isConflict());
      mvc.perform(get(path).with(actor(f.actor())).header("If-Match", "\"2\""))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"));
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM managed_application_evidence WHERE binding_id=?",
                  Long.class,
                  binding.id()))
          .isEqualTo(1);
    } finally {
      release.countDown();
      pool.shutdownNow();
    }
  }

  @Test
  void connectorRevisionChangesInvalidateStoredFactsAndMissingRevisionDisablesRefresh()
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String app = application(f, "ANDROID");
    applicationProvider(f);
    String path = applicationEvidencePath(f, binding.id(), app);
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"));
    when(gateway.applicationReportRevision()).thenReturn("fixture-application-report-v2");
    mvc.perform(get(path).with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("STALE"));
    when(gateway.applicationReportRevision()).thenReturn(null);
    mvc.perform(post(path + "/refresh").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isServiceUnavailable());
    verify(gateway, times(1)).readApplicationReport(anyString(), anyString(), anyString());
  }

  @Test
  void differentAppsCompeteForLastEvidenceSlotButExistingAppCanRefreshAtCapacity()
      throws Exception {
    var f = fixture();
    var binding = verifiedBinding(f);
    String firstApp = application(f, "ANDROID");
    var secondBody =
        Map.of(
            "displayName",
            "另一应用",
            "platform",
            "ANDROID",
            "profile",
            "PRIMARY",
            "packageName",
            "org.example.Other",
            "signingDigests",
            List.of(CERT));
    String secondApp =
        json.readTree(
                mvc.perform(
                        post("/api/v1/tenants/" + f.tenant() + "/applications")
                            .with(actor(f.actor()))
                            .contentType(MediaType.APPLICATION_JSON)
                            .content(json.writeValueAsString(secondBody)))
                    .andExpect(status().isCreated())
                    .andReturn()
                    .getResponse()
                    .getContentAsString())
            .get("id")
            .asText();
    for (int i = 0; i < 199; i++) {
      String app = UUID.randomUUID().toString();
      db.update(
          "INSERT INTO application_definitions(tenant_id,id,identity_hash,definition_json)"
              + " VALUES(?,?,?,'{}')",
          f.tenant(),
          app,
          SecretMaterial.hash(app));
      db.update(
          "INSERT INTO"
              + " managed_application_evidence(tenant_id,binding_id,application_id,id,context_revision,state,reason_code,version,attempt_expires_at,next_attempt_at,created_at,updated_at)"
              + " VALUES(?,?,?,?,?,'WAITING_REPORT','MANAGED_APPLICATION_REPORT_MISSING',1,0,0,1,1)",
          f.tenant(),
          binding.id(),
          app,
          UUID.randomUUID().toString(),
          "a".repeat(64));
    }
    applicationProvider(f);
    when(gateway.readApplicationReport(anyString(), anyString(), anyString()))
        .thenAnswer(
            call ->
                Optional.of(
                    new com.aimanager.managedandroid.ManagedApplicationReport(
                        identity(f).deviceName(),
                        "DEVICE_OWNER",
                        call.getArgument(2),
                        "INSTALLED",
                        List.of(CERT),
                        Instant.now().toString())));
    var start = new java.util.concurrent.CountDownLatch(1);
    var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    try {
      var futures = new java.util.ArrayList<java.util.concurrent.Future<Integer>>();
      for (String app : List.of(firstApp, secondApp))
        futures.add(
            pool.submit(
                () -> {
                  start.await();
                  return mvc.perform(
                          post(applicationEvidencePath(f, binding.id(), app) + "/refresh")
                              .with(actor(f.actor()))
                              .header("If-Match", "\"2\""))
                      .andReturn()
                      .getResponse()
                      .getStatus();
                }));
      start.countDown();
      assertThat(
              List.of(
                  futures.get(0).get(15, java.util.concurrent.TimeUnit.SECONDS),
                  futures.get(1).get(15, java.util.concurrent.TimeUnit.SECONDS)))
          .containsExactlyInAnyOrder(200, 409);
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM managed_application_evidence WHERE binding_id=?",
                  Long.class,
                  binding.id()))
          .isEqualTo(200);
      String winner =
          db.queryForObject(
              "SELECT application_id FROM managed_application_evidence WHERE binding_id=? AND"
                  + " state='VERIFIED'",
              String.class,
              binding.id());
      db.update(
          "UPDATE managed_application_evidence SET next_attempt_at=0 WHERE binding_id=? AND"
              + " application_id=?",
          binding.id(),
          winner);
      mvc.perform(
              post(applicationEvidencePath(f, binding.id(), winner) + "/refresh")
                  .with(actor(f.actor()))
                  .header("If-Match", "\"2\""))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.state").value("VERIFIED_IDENTITY"));
      assertThat(
              db.queryForObject(
                  "SELECT COUNT(*) FROM managed_application_evidence WHERE binding_id=?",
                  Long.class,
                  binding.id()))
          .isEqualTo(200);
    } finally {
      pool.shutdownNow();
    }
  }

  private com.aimanager.managedandroid.ManagedApplicationReport applicationReport(Fixture f) {
    return new com.aimanager.managedandroid.ManagedApplicationReport(
        identity(f).deviceName(),
        "DEVICE_OWNER",
        "org.example.Reader",
        "INSTALLED",
        List.of(CERT),
        Instant.now().toString());
  }

  private void assertContextFailure(Fixture f, String binding, long version, String code) {
    var failure =
        org.assertj.core.api.Assertions.catchThrowableOfType(
            () -> store.requireVerifiedContext(f.tenant(), f.actor(), binding, version),
            DomainException.class);
    assertThat(failure).isNotNull();
    assertThat(failure.errorCode()).isEqualTo(code);
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

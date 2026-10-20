package com.aimanager;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.fleet.Device;
import com.aimanager.fleet.FleetPolicyAccess;
import com.aimanager.managedandroid.*;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Real HTTP/SQL/rollback; device qualification and admission port are explicit boundary fixtures.
 */
@SpringBootTest(
    properties = {
      "spring.datasource.url=jdbc:h2:mem:managed_publish_admission;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "spring.flyway.enabled=true"
    })
@AutoConfigureMockMvc
class ManagedPublicationAdmissionHttpTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper json;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean ManagedPolicyEvidenceAccess evidence;
  @MockitoBean ManagedExecutionAdmission admission;
  String owner, tenant, subject, device, registration, policy, application, key;
  JsonNode preview;

  RequestPostProcessor actor() {
    return jwt()
        .jwt(
            t ->
                t.subject(owner)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  @BeforeEach
  void setup() throws Exception {
    owner = "publication-owner-" + UUID.randomUUID();
    tenant =
        created(
                "/api/v1/tenants",
                Map.of("name", "机构", "kind", "FAMILY", "timeZone", "Asia/Shanghai"))
            .get("id")
            .asText();
    subject =
        created(path() + "/subjects", Map.of("nickname", "学生", "ageBand", "AGE_7_12"))
            .get("id")
            .asText();
    device = UUID.randomUUID().toString();
    registration = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'Tablet','ANDROID','14','ACTIVE','{}','fixture',1)",
        tenant,
        device,
        subject,
        registration);
    application =
        created(
                path() + "/applications",
                Map.of(
                    "displayName",
                    "阅读",
                    "platform",
                    "ANDROID",
                    "packageName",
                    "org.example.reader",
                    "profile",
                    "PRIMARY",
                    "signingDigests",
                    List.of("a".repeat(64))))
            .get("id")
            .asText();
    policy =
        created(
                path() + "/policies",
                Map.of(
                    "name",
                    "学习规则",
                    "kind",
                    "POLICY",
                    "rules",
                    List.of(
                        Map.of(
                            "id",
                            "launch",
                            "kind",
                            "APP_LAUNCH",
                            "effect",
                            "DENY",
                            "required",
                            true,
                            "applicationId",
                            application))))
            .get("id")
            .asText();
    long now = Instant.now().toEpochMilli();
    var fleet =
        new FleetPolicyAccess.Target(
            new Device(
                device,
                subject,
                registration,
                "Tablet",
                Device.Platform.ANDROID,
                "14",
                Device.State.ACTIVE,
                "FULLY_MANAGED",
                "MANAGED",
                now,
                "RECENT",
                "fixture",
                0L),
            List.of());
    var fact =
        new ManagedPolicyEvidenceAccess.ApplicationEvidence(
            device,
            registration,
            application,
            UUID.randomUUID().toString(),
            2,
            "b".repeat(64),
            2,
            "VERIFIED_IDENTITY",
            "MANAGED_APPLICATION_CONTROL_VERIFIED",
            "PRIMARY",
            true,
            now,
            now,
            now + 600000,
            List.of(
                new ManagedControlOperation(
                    ManagedControlOperation.Kind.APP_LAUNCH,
                    ManagedControlOperation.Effect.DENY,
                    null)));
    when(evidence.snapshot(eq(tenant), eq(owner), eq(List.of(device)), anySet()))
        .thenReturn(List.of(new ManagedPolicyEvidenceAccess.Target(fleet, List.of(fact))));
    preview =
        json.readTree(
            mvc.perform(
                    post(path() + "/policies/" + policy + "/previews")
                        .with(actor())
                        .header("If-Match", "\"0\"")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json.writeValueAsString(Map.of("deviceIds", List.of(device)))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    assertThat(preview.get("enforceable").asBoolean()).isTrue();
    key = UUID.randomUUID().toString();
  }

  @Test
  void enforceQueuesInsideThePublicationTransactionWithoutConfigurationDelivery() throws Exception {
    doAnswer(
            call -> {
              assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isTrue();
              assertThat(TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())
                  .isEqualTo(TransactionDefinition.ISOLATION_READ_COMMITTED);
              String publication = call.getArgument(2);
              assertThat(
                      db.queryForObject(
                          "SELECT state FROM policy_publications WHERE tenant_id=? AND id=?",
                          String.class,
                          tenant,
                          publication))
                  .isEqualTo("PENDING_EXECUTION");
              assertThat(
                      db.queryForObject(
                          "SELECT mode FROM policy_versions WHERE tenant_id=?",
                          String.class,
                          tenant))
                  .isEqualTo("ENFORCE");
              return null;
            })
        .when(admission)
        .accept(eq(tenant), eq(owner), anyString());
    publish("ENFORCE")
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.state").value("PENDING_EXECUTION"));
    verify(admission).accept(eq(tenant), eq(owner), anyString());
    assertThat(count("policy_versions")).isEqualTo(1);
    assertThat(count("policy_publications")).isEqualTo(1);
    assertThat(count("policy_outbox")).isZero();
  }

  @Test
  void admissionFailureRollsBackVersionPublicationSequenceAndIdempotency() throws Exception {
    doThrow(new DomainException(HttpStatus.CONFLICT, "EXECUTION_DEVICE_BUSY"))
        .when(admission)
        .accept(eq(tenant), eq(owner), anyString());
    publish("ENFORCE")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_DEVICE_BUSY"));
    assertThat(count("policy_versions")).isZero();
    assertThat(count("policy_publications")).isZero();
    assertThat(count("policy_outbox")).isZero();
    assertThat(
            db.queryForObject(
                "SELECT next_sequence FROM policy_drafts WHERE tenant_id=? AND id=?",
                Long.class,
                tenant,
                policy))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND"
                    + " operation='policy.publish'",
                Long.class,
                tenant))
        .isZero();
  }

  @Test
  void repeatedPublicationDoesNotReadmitOrAllocateAnotherVersion() throws Exception {
    String original =
        publish("ENFORCE")
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString();
    String replay =
        publish("ENFORCE")
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertThat(json.readTree(replay)).isEqualTo(json.readTree(original));
    verify(admission, times(1)).accept(eq(tenant), eq(owner), anyString());
    assertThat(count("policy_versions")).isEqualTo(1);
  }

  @Test
  void configurationKeepsItsDeliveryPathWithoutExecutionAdmission() throws Exception {
    publish("CONFIGURE_ONLY")
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.state").value("CONFIGURED_NOT_ENFORCED"));
    verifyNoInteractions(admission);
    assertThat(count("policy_outbox")).isEqualTo(1);
  }

  String path() {
    return "/api/v1/tenants/" + tenant;
  }

  long count(String table) {
    return db.queryForObject(
        "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Long.class, tenant);
  }

  JsonNode created(String path, Object body) throws Exception {
    return json.readTree(
        mvc.perform(
                post(path)
                    .with(actor())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(json.writeValueAsString(body)))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  ResultActions publish(String mode) throws Exception {
    return mvc.perform(
        post(path() + "/policies/" + policy + "/publications")
            .with(actor())
            .header("If-Match", "\"0\"")
            .header("Idempotency-Key", key)
            .contentType(MediaType.APPLICATION_JSON)
            .content(
                json.writeValueAsString(
                    Map.of(
                        "previewId",
                        preview.get("id").asText(),
                        "previewHash",
                        preview.get("hash").asText(),
                        "mode",
                        mode))));
  }
}

package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/**
 * Actual opaque device authentication and domain/SQL transactions; adult MFA and registration are
 * fixtures.
 */
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
      "server.address=127.0.0.1",
      "spring.datasource.url=${ACCESS_SUBMISSION_TEST_DATABASE_URL:jdbc:h2:mem:accesssubmission;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${ACCESS_SUBMISSION_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${ACCESS_SUBMISSION_TEST_DATABASE_PASSWORD:}",
      "manager.approval.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class DeviceAccessSubmissionJourneyTest {
  private static final String ROUTE = "/api/v1/device-api/access-submissions";
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper mapper;
  @Autowired DeviceCredentials credentials;
  @Autowired Clock clock;
  @Autowired org.springframework.context.ApplicationEventPublisher events;
  @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
  @org.springframework.boot.test.web.server.LocalServerPort int port;
  @MockitoBean JwtDecoder decoder;

  @BeforeEach
  void rejectDeviceTokensAsUserJwt() {
    when(decoder.decode(anyString()))
        .thenThrow(new BadJwtException("Device token is not a user JWT"));
  }

  private RequestPostProcessor adult(String actor) {
    return jwt()
        .jwt(
            t ->
                t.subject(actor)
                    .claim("auth_time", clock.instant().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }

  private JsonNode json(String text) throws Exception {
    return mapper.readTree(text);
  }

  private String create(String route, String owner, Object value) throws Exception {
    return json(mvc.perform(
                post(route)
                    .with(adult(owner))
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(mapper.writeValueAsString(value)))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString())
        .get("id")
        .asText();
  }

  private Scope scope() throws Exception {
    return scope(false);
  }

  private Scope scope(boolean ownerNameCollides) throws Exception {
    String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
    String owner =
        ownerNameCollides ? "device:" + registration : "submission-owner-" + UUID.randomUUID();
    String tenant =
        create("/api/v1/tenants", owner, Map.of("name", "家庭", "kind", "FAMILY", "timeZone", "UTC"));
    String prefix = "/api/v1/tenants/" + tenant;
    String subject =
        create(prefix + "/subjects", owner, Map.of("nickname", "孩子", "ageBand", "AGE_7_12"));
    long now = clock.millis();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'设备','ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        device,
        subject,
        registration,
        now);
    String credential = UUID.randomUUID().toString(), token = SecretMaterial.token();
    db.update(
        "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
            + " VALUES(?,?,?,true)",
        tenant,
        registration,
        device);
    db.update(
        "INSERT INTO"
            + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
            + " VALUES(?,?,?,?,?,true,?,?)",
        credential,
        tenant,
        device,
        registration,
        SecretMaterial.hash(token),
        now,
        now + 3600000);
    String app =
        create(
            prefix + "/applications",
            owner,
            Map.of(
                "displayName",
                "阅读",
                "platform",
                "ANDROID",
                "packageName",
                "org.example.submission",
                "profile",
                "PRIMARY",
                "signingDigests",
                List.of("a".repeat(64))));
    String policy =
        create(
            prefix + "/policies",
            owner,
            Map.of(
                "name",
                "阅读规则",
                "kind",
                "POLICY",
                "rules",
                List.of(
                    Map.of(
                        "id",
                        "reading",
                        "kind",
                        "APP_LAUNCH",
                        "effect",
                        "DENY",
                        "applicationId",
                        app,
                        "required",
                        true))));
    var s =
        new Scope(
            owner, tenant, subject, device, registration, credential, token, app, policy, null);
    return new Scope(
        owner, tenant, subject, device, registration, credential, token, app, policy, publish(s));
  }

  private String publish(Scope s) throws Exception {
    String p = "/api/v1/tenants/" + s.tenant() + "/policies/" + s.policy();
    var preview =
        json(
            mvc.perform(
                    post(p + "/previews")
                        .with(adult(s.owner()))
                        .header("If-Match", "\"0\"")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(
                            mapper.writeValueAsString(Map.of("deviceIds", List.of(s.device())))))
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString());
    return json(mvc.perform(
                post(p + "/publications")
                    .with(adult(s.owner()))
                    .header("If-Match", "\"0\"")
                    .header("Idempotency-Key", UUID.randomUUID())
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(
                        mapper.writeValueAsString(
                            Map.of(
                                "previewId",
                                preview.get("id").asText(),
                                "previewHash",
                                preview.get("hash").asText(),
                                "mode",
                                "CONFIGURE_ONLY"))))
            .andExpect(status().isCreated())
            .andReturn()
            .getResponse()
            .getContentAsString())
        .get("versionId")
        .asText();
  }

  private Map<String, Object> input(Scope s) {
    return Map.of(
        "policyId",
        s.policy(),
        "baseVersionId",
        s.version(),
        "applicationId",
        s.application(),
        "ruleIds",
        List.of("reading"),
        "requestedWindowSeconds",
        600,
        "reason",
        "想继续阅读");
  }

  private JsonNode submit(Scope s, String key) throws Exception {
    return json(
        mvc.perform(
                post(ROUTE)
                    .header("Authorization", "Bearer " + s.token())
                    .header("Idempotency-Key", key)
                    .contentType(MediaType.APPLICATION_JSON)
                    .content(mapper.writeValueAsString(input(s))))
            .andExpect(status().isCreated())
            .andExpect(header().string("ETag", "\"0\""))
            .andExpect(header().string("Cache-Control", "no-store"))
            .andReturn()
            .getResponse()
            .getContentAsString());
  }

  private String management(Scope s) {
    return "/api/v1/tenants/" + s.tenant() + "/access-requests";
  }

  @Test
  void deviceWithoutChildMemberCanSubmitAndAdultCanApproveForExistingDelivery() throws Exception {
    var s = scope();
    mvc.perform(get(ROUTE + "/options").header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].applications[0].id").value(s.application()));
    var r = submit(s, "initial");
    String id = r.get("id").asText();
    assertThat(r.get("subjectId").asText()).isEqualTo(s.subject());
    assertThat(r.get("deviceId").asText()).isEqualTo(s.device());
    assertThat(r.get("state").asText()).isEqualTo("PENDING");
    assertThat(r.toString()).doesNotContain(s.token(), s.credential(), s.owner());
    assertThat(
            db.queryForObject(
                "SELECT requester_kind FROM access_requests WHERE tenant_id=? AND id=?",
                String.class,
                s.tenant(),
                id))
        .isEqualTo("DEVICE");
    mvc.perform(get(management(s)).with(adult(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].id").value(id));
    mvc.perform(
            post(management(s) + "/" + id + "/decisions")
                .with(adult(s.owner()))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "approve")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":300}"))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("APPROVED_PENDING_DELIVERY"));
    mvc.perform(get(ROUTE + "/" + id).header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.executionState").value("NOT_ENFORCED"));
    mvc.perform(
            get("/api/v1/device-api/access-requests")
                .header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].requestId").value(id));
  }

  @Test
  void cancelRequiresStrongVersionAndReplaysCurrentCreationState() throws Exception {
    var s = scope();
    var r = submit(s, "create");
    String p = ROUTE + "/" + r.get("id").asText() + "/cancel";
    mvc.perform(
            post(p)
                .header("Authorization", "Bearer " + s.token())
                .header("Idempotency-Key", "cancel"))
        .andExpect(status().isPreconditionRequired());
    mvc.perform(
            post(p)
                .header("Authorization", "Bearer " + s.token())
                .header("If-Match", "\"99\"")
                .header("Idempotency-Key", "cancel"))
        .andExpect(status().isPreconditionFailed());
    for (int i = 0; i < 2; i++)
      mvc.perform(
              post(p)
                  .header("Authorization", "Bearer " + s.token())
                  .header("If-Match", "\"0\"")
                  .header("Idempotency-Key", "cancel"))
          .andExpect(status().isOk())
          .andExpect(jsonPath("$.state").value("CANCELLED"));
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + s.token())
                .header("Idempotency-Key", "create")
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(input(s))))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.state").value("CANCELLED"))
        .andExpect(header().string("ETag", "\"1\""));
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + s.token())
                .header("Idempotency-Key", "another")
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(input(s))))
        .andExpect(status().isTooManyRequests())
        .andExpect(jsonPath("$.errorCode").value("ACCESS_REQUEST_COOLDOWN"));
  }

  @Test
  void deviceCredentialCannotApproveOrChooseAnotherTarget() throws Exception {
    var s = scope();
    var other = scope();
    var r = submit(s, "create");
    mvc.perform(
            get(ROUTE + "/" + r.get("id").asText())
                .header("Authorization", "Bearer " + other.token()))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(ROUTE + "/" + r.get("id").asText() + "/cancel")
                .header("Authorization", "Bearer " + other.token())
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "foreign"))
        .andExpect(status().isForbidden());
    var injected = new HashMap<>(input(s));
    injected.put("deviceId", other.device());
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + s.token())
                .header("Idempotency-Key", "inject")
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(injected)))
        .andExpect(status().isBadRequest());
    mvc.perform(
            post(management(s) + "/" + r.get("id").asText() + "/decisions")
                .header("Authorization", "Bearer " + s.token())
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":60}"))
        .andExpect(status().isUnauthorized());
    mvc.perform(get(ROUTE).with(adult(s.owner()))).andExpect(status().isForbidden());
  }

  @Test
  void rotationKeepsRequestOwnershipAndOriginalIdempotencyKey() throws Exception {
    var s = scope();
    var r = submit(s, "stable");
    var next =
        credentials.rotate(
            new DeviceContext(s.tenant(), s.device(), s.registration(), s.credential()));
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + next.credential()))
        .andExpect(status().isForbidden());
    mvc.perform(
            post("/api/v1/device-api/credentials/activate")
                .header("Authorization", "Bearer " + next.credential()))
        .andExpect(status().isNoContent());
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isUnauthorized());
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + next.credential())
                .header("Idempotency-Key", "stable")
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(input(s))))
        .andExpect(status().isCreated())
        .andExpect(jsonPath("$.id").value(r.get("id").asText()));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM access_requests WHERE tenant_id=?",
                Integer.class,
                s.tenant()))
        .isEqualTo(1);
  }

  @Test
  void memberWithSameTextNameCannotCancelDeviceSubmissionOrInvalidateItOnRevocation()
      throws Exception {
    var s = scope();
    var r = submit(s, "create");
    String collision = "device:" + s.registration();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        s.tenant(),
        collision,
        ActorKeys.key(collision),
        s.subject());
    mvc.perform(
            post(management(s) + "/" + r.get("id").asText() + "/cancel")
                .with(adult(collision))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "collision"))
        .andExpect(status().isForbidden());
    mvc.perform(
            delete("/api/v1/tenants/" + s.tenant() + "/members/" + collision)
                .with(adult(s.owner())))
        .andExpect(status().isNoContent());
    mvc.perform(
            get(ROUTE + "/" + r.get("id").asText()).header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("PENDING"));
  }

  @Test
  void ownerNameMatchingDeviceAuditNameIsNotDeviceSelfApproval() throws Exception {
    var s = scope(true);
    var r = submit(s, "create");
    mvc.perform(
            post(management(s) + "/" + r.get("id").asText() + "/decisions")
                .with(adult(s.owner()))
                .header("If-Match", "\"0\"")
                .header("Idempotency-Key", "approve")
                .contentType(MediaType.APPLICATION_JSON)
                .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":60}"))
        .andExpect(status().isOk());
  }

  @Test
  void newBaselineInvalidatesPendingSubmissionAndExpiredCredentialCannotReplay() throws Exception {
    var s = scope();
    var r = submit(s, "create");
    publish(s);
    mvc.perform(
            get(ROUTE + "/" + r.get("id").asText()).header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("INVALIDATED"));
    db.update("UPDATE device_credentials SET expires_at=1 WHERE id=?", s.credential());
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + s.token())
                .header("Idempotency-Key", "create")
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(input(s))))
        .andExpect(status().isUnauthorized());
  }

  @Test
  void rejectsUnknownAuthorityFieldsMissingKeyAndChangedIdempotentPayload() throws Exception {
    var s = scope();
    mvc.perform(get(ROUTE)).andExpect(status().isUnauthorized());
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + s.token())
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(input(s))))
        .andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_REQUIRED"));
    submit(s, "create");
    var changed = new HashMap<>(input(s));
    changed.put("requestedWindowSeconds", 60);
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + s.token())
                .header("Idempotency-Key", "create")
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(changed)))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    for (String field :
        List.of(
            "tenantId",
            "subjectId",
            "registrationId",
            "state",
            "absoluteNotAfter",
            "requesterKind",
            "role")) {
      var injected = new HashMap<>(input(s));
      injected.put(field, "injected");
      mvc.perform(
              post(ROUTE)
                  .header("Authorization", "Bearer " + s.token())
                  .header("Idempotency-Key", field)
                  .contentType(MediaType.APPLICATION_JSON)
                  .content(mapper.writeValueAsString(injected)))
          .andExpect(status().isBadRequest());
    }
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + s.token()).param("limit", "101"))
        .andExpect(status().isBadRequest());
    mvc.perform(get(ROUTE + "/not-a-uuid").header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isBadRequest());
  }

  @Test
  void duplicateNewKeyDoesNotCreateSecondPendingRequestAndListsOnlyThisDevice() throws Exception {
    var s = scope();
    var r = submit(s, "create");
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + s.token())
                .header("Idempotency-Key", "duplicate")
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(input(s))))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("ACCESS_REQUEST_PENDING"));
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1))
        .andExpect(jsonPath("$.items[0].id").value(r.get("id").asText()));
    String otherDevice = UUID.randomUUID().toString(),
        otherRegistration = UUID.randomUUID().toString(),
        otherCredential = UUID.randomUUID().toString(),
        otherToken = SecretMaterial.token();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'另一设备','ANDROID','14','ACTIVE','{}','fixture',?)",
        s.tenant(),
        otherDevice,
        s.subject(),
        otherRegistration,
        clock.millis());
    db.update(
        "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
            + " VALUES(?,?,?,true)",
        s.tenant(),
        otherRegistration,
        otherDevice);
    db.update(
        "INSERT INTO"
            + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
            + " VALUES(?,?,?,?,?,true,?,?)",
        otherCredential,
        s.tenant(),
        otherDevice,
        otherRegistration,
        SecretMaterial.hash(otherToken),
        clock.millis(),
        clock.millis() + 3600000);
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + otherToken))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(0));
    mvc.perform(
            get(ROUTE + "/" + r.get("id").asText()).header("Authorization", "Bearer " + otherToken))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(ROUTE)
                .header("Authorization", "Bearer " + otherToken)
                .header("Idempotency-Key", "foreign-baseline")
                .contentType(MediaType.APPLICATION_JSON)
                .content(mapper.writeValueAsString(input(s))))
        .andExpect(status().isForbidden());
  }

  @Test
  void subjectReassignmentAndInactiveRegistrationStopReadsAndMutations() throws Exception {
    var s = scope();
    var r = submit(s, "create");
    String replacement = UUID.randomUUID().toString();
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'新孩子','AGE_7_12',?)",
        s.tenant(),
        replacement,
        clock.millis());
    db.update(
        "UPDATE devices SET subject_id=? WHERE tenant_id=? AND id=?",
        replacement,
        s.tenant(),
        s.device());
    mvc.perform(
            get(ROUTE + "/" + r.get("id").asText()).header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isForbidden());
    db.update(
        "UPDATE device_credential_scopes SET active=false,revoked_at=? WHERE tenant_id=? AND"
            + " registration_id=?",
        clock.millis(),
        s.tenant(),
        s.registration());
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + s.token()))
        .andExpect(status().isUnauthorized());
  }

  @Test
  @org.junit.jupiter.api.condition.EnabledIfSystemProperty(
      named = "device.access.package",
      matches = ".+")
  void actualDartSubmissionAdultDecisionAndExistingDeviceDeliveryReference() throws Exception {
    var s = scope();
    java.nio.file.Files.createDirectories(java.nio.file.Path.of(".local"));
    var directory =
        java.nio.file.Files.createTempDirectory(
            java.nio.file.Path.of(".local").toAbsolutePath(), "submission-http-");
    var fixtureFile = directory.resolve("fixture.json");
    var resultFile = directory.resolve("result.json");
    var fixture = new HashMap<String, Object>();
    fixture.put("apiRoot", "http://127.0.0.1:" + port + "/api/v1");
    fixture.put("credential", s.token());
    fixture.put("tenantId", s.tenant());
    fixture.put("subjectId", s.subject());
    fixture.put("deviceId", s.device());
    fixture.put("registrationId", s.registration());
    fixture.put("policyId", s.policy());
    fixture.put("baseVersionId", s.version());
    fixture.put("applicationId", s.application());
    fixture.put("resultFile", resultFile.toString());
    try {
      runDart(fixtureFile, fixture, directory, "submit");
      assertThat(java.nio.file.Files.exists(directory.resolve("submissions.db")))
          .as("The first Dart process must leave its original operation durable")
          .isTrue();
      String id = mapper.readTree(resultFile.toFile()).get("requestId").asText();
      var approved =
          json(
              mvc.perform(
                      post(management(s) + "/" + id + "/decisions")
                          .with(adult(s.owner()))
                          .header("If-Match", "\"0\"")
                          .header("Idempotency-Key", "approve")
                          .contentType(MediaType.APPLICATION_JSON)
                          .content("{\"decision\":\"APPROVE\",\"grantedWindowSeconds\":300}"))
                  .andExpect(status().isOk())
                  .andReturn()
                  .getResponse()
                  .getContentAsString());
      fixture.put("absoluteNotAfter", approved.get("absoluteNotAfter").asLong());
      runDart(fixtureFile, fixture, directory, "approved");
      mvc.perform(
              post(management(s) + "/" + id + "/revoke")
                  .with(adult(s.owner()))
                  .header("If-Match", "\"1\"")
                  .header("Idempotency-Key", "revoke"))
          .andExpect(status().isOk());
      runDart(fixtureFile, fixture, directory, "revoked");
    } finally {
      java.nio.file.Files.deleteIfExists(fixtureFile);
      java.nio.file.Files.deleteIfExists(resultFile);
      java.nio.file.Files.deleteIfExists(directory.resolve("submissions.db"));
      // Per-phase logs contain only safe status markers and remain local for diagnostics.
    }
  }

  private void runDart(
      java.nio.file.Path file,
      Map<String, Object> fixture,
      java.nio.file.Path directory,
      String phase)
      throws Exception {
    mapper.writeValue(file.toFile(), fixture);
    var output = directory.resolve("dart-" + phase + ".log");
    var process =
        new ProcessBuilder(
                System.getProperty("device.dart.command"),
                "run",
                "tool/verify_submission_http.dart",
                file.toString(),
                phase)
            .directory(java.nio.file.Path.of(System.getProperty("device.access.package")).toFile())
            .redirectErrorStream(true)
            .redirectOutput(output.toFile())
            .start();
    if (!process.waitFor(45, java.util.concurrent.TimeUnit.SECONDS)) {
      process.destroyForcibly();
      process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS);
      throw new AssertionError("Dart submission exceeded bounded deadline");
    }
    assertThat(process.exitValue()).as("Dart diagnostics: %s", output).isZero();
    assertThat(java.nio.file.Files.readString(output))
        .contains("Device access submission HTTP " + phase + ": PASS");
  }

  @Test
  void deviceNotificationsReachAdultsButNotMemberWithSameTextIdentity() throws Exception {
    var s = scope();
    submit(s, "device-request");
    String collision = "device:" + s.registration();
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,'CHILD',?)",
        s.tenant(),
        collision,
        ActorKeys.key(collision),
        s.subject());
    String route = "/api/v1/tenants/" + s.tenant() + "/notifications";
    mvc.perform(get(route).with(adult(collision)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(0));
    mvc.perform(get(route).with(adult(s.owner())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
    mvc.perform(get(route + "/unread-count").with(adult(collision)))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.count").value(0));
    String notice =
        db.queryForObject(
            "SELECT id FROM notification_events WHERE tenant_id=?", String.class, s.tenant());
    mvc.perform(put(route + "/" + notice + "/read").with(adult(collision)))
        .andExpect(status().isForbidden());
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM notification_reads WHERE tenant_id=?",
                Integer.class,
                s.tenant()))
        .isZero();
    assertThat(
            db.queryForObject(
                "SELECT requester_kind FROM notification_events WHERE tenant_id=?",
                String.class,
                s.tenant()))
        .isEqualTo("DEVICE");
  }

  @Test
  void repeatedNotificationCannotChangeDeviceOriginIntoMemberOrigin() throws Exception {
    var s = scope();
    String id = submit(s, "notification-replay").get("id").asText();
    var event =
        new com.aimanager.approval.AccessRequestChanged(
            s.tenant(),
            id,
            s.subject(),
            s.device(),
            ActorKeys.key("device:" + s.registration()),
            0,
            com.aimanager.approval.AccessRequest.State.PENDING,
            clock.millis(),
            com.aimanager.approval.AccessRequestChanged.RequesterKind.DEVICE);
    var tx = new org.springframework.transaction.support.TransactionTemplate(transactions);
    tx.executeWithoutResult(
        status -> {
          events.publishEvent(event);
          events.publishEvent(event);
        });
    var collision =
        new com.aimanager.approval.AccessRequestChanged(
            s.tenant(),
            id,
            s.subject(),
            s.device(),
            event.requesterKey(),
            0,
            event.state(),
            event.occurredAt());
    org.assertj.core.api.Assertions.assertThatThrownBy(
            () -> tx.executeWithoutResult(status -> events.publishEvent(collision)))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Conflicting notification version");
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM notification_events WHERE tenant_id=?",
                Integer.class,
                s.tenant()))
        .isEqualTo(1);
    assertThat(
            db.queryForObject(
                "SELECT requester_kind FROM notification_events WHERE tenant_id=?",
                String.class,
                s.tenant()))
        .isEqualTo("DEVICE");
  }

  private record Scope(
      String owner,
      String tenant,
      String subject,
      String device,
      String registration,
      String credential,
      String token,
      String application,
      String policy,
      String version) {}
}

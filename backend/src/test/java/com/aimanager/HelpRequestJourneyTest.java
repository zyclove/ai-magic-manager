package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.web.servlet.*;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;

/** Real routes, opaque credentials, domain transactions and SQL; JWT issuance/OS are fixtures. */
@SpringBootTest(
    properties = {
      "spring.datasource.url=${HELP_TEST_DATABASE_URL:jdbc:h2:mem:help-journey;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
      "spring.datasource.username=${HELP_TEST_DATABASE_USERNAME:sa}",
      "spring.datasource.password=${HELP_TEST_DATABASE_PASSWORD:}",
      "manager.approval.expiry-job.enabled=false",
      "manager.quota.materialization-job.enabled=false",
      "manager.lifecycle.expiry-job.enabled=false"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class HelpRequestJourneyTest {
  private static final String DEVICE_ROUTE = "/api/v1/device-api/help-requests";
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper json;
  @MockitoBean JwtDecoder decoder;
  @MockitoSpyBean AuditService audit;

  @BeforeEach
  void identityBoundary() {
    when(decoder.decode(anyString())).thenThrow(new BadJwtException("Not a user credential"));
  }

  record Binding(
      String tenant,
      String subject,
      String device,
      String registration,
      String credential,
      String token,
      String owner) {
    String route() {
      return "/api/v1/tenants/" + tenant + "/help-requests";
    }
  }

  String uuid() {
    return UUID.randomUUID().toString();
  }

  Binding binding(String kind) {
    String tenant = uuid(),
        subject = uuid(),
        device = uuid(),
        registration = uuid(),
        credential = uuid(),
        owner = uuid();
    String token = SecretMaterial.token();
    long now = System.currentTimeMillis();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'fixture',?,'UTC',?)",
        tenant,
        kind,
        now);
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'current"
            + " child','AGE_7_12',?)",
        tenant,
        subject,
        now);
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'device','ANDROID','14','ACTIVE','{}','fixture',?)",
        tenant,
        device,
        subject,
        registration,
        now);
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
    member(tenant, owner, "OWNER", null);
    return new Binding(tenant, subject, device, registration, credential, token, owner);
  }

  Binding sibling(Binding b) {
    String device = uuid(),
        registration = uuid(),
        credential = uuid(),
        token = SecretMaterial.token();
    long now = System.currentTimeMillis();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'sibling','ANDROID','14','ACTIVE','{}','fixture',?)",
        b.tenant(),
        device,
        b.subject(),
        registration,
        now);
    db.update(
        "INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active)"
            + " VALUES(?,?,?,true)",
        b.tenant(),
        registration,
        device);
    db.update(
        "INSERT INTO"
            + " device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at)"
            + " VALUES(?,?,?,?,?,true,?,?)",
        credential,
        b.tenant(),
        device,
        registration,
        SecretMaterial.hash(token),
        now,
        now + 3600000);
    return new Binding(b.tenant(), b.subject(), device, registration, credential, token, b.owner());
  }

  void member(String tenant, String actor, String role, String subject) {
    db.update(
        "INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id)"
            + " VALUES(?,?,?,?,?)",
        tenant,
        actor,
        ActorKeys.key(actor),
        role,
        subject);
  }

  ResultActions submit(Binding b, String request, String reason) throws Exception {
    return mvc.perform(
        post(DEVICE_ROUTE)
            .header("Authorization", "Bearer " + b.token())
            .contentType(MediaType.APPLICATION_JSON)
            .content(
                json.writeValueAsBytes(Map.of("clientRequestId", request, "reasonCode", reason))));
  }

  JsonNode body(ResultActions action) throws Exception {
    return json.readTree(action.andReturn().getResponse().getContentAsString());
  }

  JsonNode create(Binding b) throws Exception {
    return body(submit(b, uuid(), "NEED_HELP").andExpect(status().isCreated()));
  }

  ResultActions adult(MockHttpServletRequestBuilder request, String actor) throws Exception {
    return mvc.perform(request.with(jwt().jwt(t -> t.subject(actor))));
  }

  ResultActions ack(Binding b, String actor, String id, String version) throws Exception {
    var request = post(b.route() + "/" + id + "/acknowledge");
    if (version != null) request.header("If-Match", version);
    return adult(request, actor);
  }

  long events(Binding b, String action) {
    return db.queryForObject(
        "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action=?",
        Long.class,
        b.tenant(),
        action);
  }

  @ParameterizedTest
  @ValueSource(strings = {"NEED_HELP", "UNCOMFORTABLE_CONTENT", "DEVICE_PROBLEM"})
  void creationReplayAndReasonConflict(String reason) throws Exception {
    var b = binding("FAMILY");
    String request = uuid();
    var created =
        body(
            submit(b, request, reason)
                .andExpect(status().isCreated())
                .andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(header().string("ETag", "\"0\""))
                .andExpect(header().string("Location", DEVICE_ROUTE + "/" + request)));
    assertThat(created.path("subjectId").asText()).isEqualTo(b.subject());
    assertThat(created.path("deviceId").asText()).isEqualTo(b.device());
    assertThat(created.path("subjectNickname").isNull()).isTrue();
    assertThat(body(submit(b, request, reason).andExpect(status().isOk()))).isEqualTo(created);
    submit(b, request, reason.equals("NEED_HELP") ? "DEVICE_PROBLEM" : "NEED_HELP")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("HELP_REQUEST_ID_REUSED"));
    assertThat(events(b, "CHILD_HELP_REQUESTED")).isEqualTo(1);
  }

  @Test
  void originalReplayDoesNotConsumeRateLimitAndOldRecordsExpireFromWindow() throws Exception {
    var b = binding("FAMILY");
    String first = uuid();
    submit(b, first, "NEED_HELP").andExpect(status().isCreated());
    for (int i = 1; i < 10; i++) create(b);
    submit(b, first, "NEED_HELP").andExpect(status().isOk());
    submit(b, uuid(), "NEED_HELP").andExpect(status().isTooManyRequests());
    assertThat(events(b, "CHILD_HELP_REQUESTED")).isEqualTo(10);
    db.update(
        "UPDATE child_help_requests SET created_at=? WHERE tenant_id=?",
        System.currentTimeMillis() - 61000,
        b.tenant());
    create(b);
  }

  @Test
  void concurrentIdenticalCreatesProduceOneRecordAndAudit() throws Exception {
    var b = binding("FAMILY");
    String request = uuid();
    var statuses =
        concurrently(() -> submit(b, request, "NEED_HELP").andReturn().getResponse().getStatus());
    assertThat(statuses).containsExactlyInAnyOrder(200, 201);
    assertThat(events(b, "CHILD_HELP_REQUESTED")).isEqualTo(1);
  }

  @Test
  void concurrentLastRateSlotOnlyAllowsOneNewRecord() throws Exception {
    var b = binding("FAMILY");
    for (int i = 0; i < 9; i++) create(b);
    var statuses =
        concurrently(() -> submit(b, uuid(), "NEED_HELP").andReturn().getResponse().getStatus());
    assertThat(statuses).containsExactlyInAnyOrder(201, 429);
    assertThat(events(b, "CHILD_HELP_REQUESTED")).isEqualTo(10);
  }

  @Test
  void deviceLookupIsReadOnlyAndCannotReadAnotherTenantOrRegistration() throws Exception {
    var b = binding("FAMILY");
    var other = binding("FAMILY");
    String request = uuid();
    submit(b, request, "NEED_HELP").andExpect(status().isCreated());
    mvc.perform(
            get(DEVICE_ROUTE + "/" + request).header("Authorization", "Bearer " + other.token()))
        .andExpect(status().isNotFound());
    mvc.perform(get(DEVICE_ROUTE + "/" + uuid()).header("Authorization", "Bearer " + b.token()))
        .andExpect(status().isNotFound());
    var sibling = sibling(b);
    mvc.perform(
            get(DEVICE_ROUTE + "/" + request).header("Authorization", "Bearer " + sibling.token()))
        .andExpect(status().isNotFound());
    submit(sibling, request, "NEED_HELP").andExpect(status().isCreated());
    assertThat(
            body(submit(b, request, "NEED_HELP").andExpect(status().isOk()))
                .path("deviceId")
                .asText())
        .isEqualTo(b.device());
    assertThat(events(b, "CHILD_HELP_REQUESTED")).isEqualTo(2);
  }

  @ParameterizedTest
  @ValueSource(strings = {"credential", "scope", "device", "subject"})
  void currentRevocationBlocksDeviceReadsAndWrites(String kind) throws Exception {
    var b = binding("FAMILY");
    var value = create(b);
    switch (kind) {
      case "credential" ->
          db.update("UPDATE device_credentials SET active=false WHERE id=?", b.credential());
      case "scope" ->
          db.update(
              "UPDATE device_credential_scopes SET active=false WHERE tenant_id=? AND"
                  + " registration_id=?",
              b.tenant(),
              b.registration());
      case "device" ->
          db.update(
              "UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?",
              b.tenant(),
              b.device());
      default ->
          db.update(
              "UPDATE subjects SET archived_at=1 WHERE tenant_id=? AND id=?",
              b.tenant(),
              b.subject());
    }
    assertThat(submit(b, uuid(), "NEED_HELP").andReturn().getResponse().getStatus()).isIn(401, 403);
    assertThat(
            mvc.perform(
                    get(DEVICE_ROUTE + "/" + value.path("clientRequestId").asText())
                        .header("Authorization", "Bearer " + b.token()))
                .andReturn()
                .getResponse()
                .getStatus())
        .isIn(401, 403);
    assertThat(events(b, "CHILD_HELP_REQUESTED")).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(strings = {"OWNER", "GUARDIAN", "ORG_ADMIN"})
  void adultsSeeCurrentNicknameAndStrongVersionAcknowledgement(String role) throws Exception {
    var b = binding("FAMILY");
    String actor = uuid();
    member(b.tenant(), actor, role, null);
    var value = create(b);
    String id = value.path("id").asText();
    db.update(
        "UPDATE subjects SET nickname='renamed' WHERE tenant_id=? AND id=?",
        b.tenant(),
        b.subject());
    adult(get(b.route()), actor)
        .andExpect(status().isOk())
        .andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(jsonPath("$.items[0].subjectNickname").value("renamed"));
    ack(b, actor, id, null).andExpect(status().isPreconditionRequired());
    ack(b, actor, id, "W/\"0\"").andExpect(status().isBadRequest());
    ack(b, actor, id, "\"0\"")
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"1\""))
        .andExpect(jsonPath("$.state").value("ACKNOWLEDGED"));
    ack(b, actor, id, "\"0\"").andExpect(status().isPreconditionFailed());
    ack(b, actor, id, "\"1\"").andExpect(status().isOk());
    assertThat(events(b, "CHILD_HELP_ACKNOWLEDGED")).isEqualTo(1);
    adult(get(b.route() + "/open-count"), actor).andExpect(jsonPath("$.count").value(0));
    mvc.perform(
            get(DEVICE_ROUTE + "/" + value.path("clientRequestId").asText())
                .header("Authorization", "Bearer " + b.token()))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("ACKNOWLEDGED"))
        .andExpect(jsonPath("$.subjectNickname").isEmpty());
  }

  @ParameterizedTest
  @ValueSource(strings = {"CHILD", "AUDITOR", "TEACHER"})
  void familyRolesWithoutAttentionAccessCannotListCountOrAcknowledge(String role) throws Exception {
    var b = binding("FAMILY");
    String actor = uuid();
    member(b.tenant(), actor, role, b.subject());
    var value = create(b);
    adult(get(b.route()), actor).andExpect(status().isForbidden());
    adult(get(b.route() + "/open-count"), actor).andExpect(status().isForbidden());
    ack(b, actor, value.path("id").asText(), "\"0\"").andExpect(status().isForbidden());
  }

  @Test
  void crossTenantAndRevokedMembersCannotUsePreviouslyVisibleRequest() throws Exception {
    var b = binding("FAMILY");
    var other = binding("FAMILY");
    String id = create(b).path("id").asText();
    adult(get(b.route() + "/" + id), other.owner()).andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", b.tenant());
    adult(get(b.route()), b.owner()).andExpect(status().isForbidden());
    ack(b, b.owner(), id, "\"0\"").andExpect(status().isForbidden());
  }

  @ParameterizedTest
  @ValueSource(strings = {"class", "roster", "epoch", "scope", "subject"})
  void teacherClassAccessIsRecheckedAfterCurrentScopeChanges(String changed) throws Exception {
    var b = binding("ORGANIZATION");
    String teacher = uuid(), classId = uuid();
    member(b.tenant(), teacher, "TEACHER", null);
    db.update(
        "INSERT INTO organization_classes(tenant_id,id,name,created_at,updated_at)"
            + " VALUES(?,?,'class',1,1)",
        b.tenant(),
        classId);
    db.update(
        "INSERT INTO organization_class_students(tenant_id,class_id,subject_id,added_at)"
            + " VALUES(?,?,?,1)",
        b.tenant(),
        classId,
        b.subject());
    db.update(
        "INSERT INTO tenant_member_class_scopes(tenant_id,actor_key,class_id,member_version)"
            + " VALUES(?,?,?,0)",
        b.tenant(),
        ActorKeys.key(teacher),
        classId);
    String id = create(b).path("id").asText();
    adult(get(b.route()), teacher)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
    adult(get(b.route() + "/open-count"), teacher).andExpect(jsonPath("$.count").value(1));
    switch (changed) {
      case "class" ->
          db.update("UPDATE organization_classes SET archived_at=1 WHERE tenant_id=?", b.tenant());
      case "roster" ->
          db.update("DELETE FROM organization_class_students WHERE tenant_id=?", b.tenant());
      case "epoch" ->
          db.update(
              "UPDATE tenant_members SET version=version+1 WHERE tenant_id=? AND actor_key=?",
              b.tenant(),
              ActorKeys.key(teacher));
      case "scope" ->
          db.update("DELETE FROM tenant_member_class_scopes WHERE tenant_id=?", b.tenant());
      default -> db.update("UPDATE subjects SET archived_at=1 WHERE tenant_id=?", b.tenant());
    }
    adult(get(b.route()), teacher)
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(0));
    adult(get(b.route() + "/open-count"), teacher).andExpect(jsonPath("$.count").value(0));
    adult(get(b.route() + "/" + id), teacher).andExpect(status().isNotFound());
    ack(b, teacher, id, "\"0\"").andExpect(status().isNotFound());
    adult(get(b.route()).param("cursor", id), teacher).andExpect(status().isBadRequest());
    assertThat(events(b, "CHILD_HELP_ACKNOWLEDGED")).isZero();
  }

  @Test
  void directTeacherAssignmentAllowsOnlyItsCurrentSubject() throws Exception {
    var b = binding("ORGANIZATION");
    String teacher = uuid();
    member(b.tenant(), teacher, "TEACHER", b.subject());
    String id = create(b).path("id").asText();
    ack(b, teacher, id, "\"0\"").andExpect(status().isOk());
    db.update(
        "UPDATE tenant_members SET subject_id=NULL WHERE tenant_id=? AND actor_key=?",
        b.tenant(),
        ActorKeys.key(teacher));
    adult(get(b.route() + "/" + id), teacher).andExpect(status().isNotFound());
    ack(b, teacher, id, "\"1\"").andExpect(status().isNotFound());
  }

  @Test
  void pagingAnchorRemainsValidAfterAcknowledgementAndUsesStableTieBreak() throws Exception {
    var b = binding("FAMILY");
    var ids = new ArrayList<String>();
    for (int i = 0; i < 3; i++) ids.add(create(b).path("id").asText());
    db.update("UPDATE child_help_requests SET created_at=100 WHERE tenant_id=?", b.tenant());
    ids.sort(Comparator.reverseOrder());
    var first =
        body(
            adult(get(b.route()).param("state", "OPEN").param("limit", "1"), b.owner())
                .andExpect(status().isOk()));
    assertThat(first.path("items").get(0).path("id").asText()).isEqualTo(ids.get(0));
    ack(b, b.owner(), ids.get(0), "\"0\"").andExpect(status().isOk());
    var second =
        body(
            adult(
                    get(b.route())
                        .param("state", "OPEN")
                        .param("limit", "1")
                        .param("cursor", ids.get(0)),
                    b.owner())
                .andExpect(status().isOk()));
    assertThat(second.path("items").get(0).path("id").asText()).isEqualTo(ids.get(1));
    adult(get(b.route()).param("cursor", uuid()), b.owner()).andExpect(status().isBadRequest());
    adult(get(b.route()).param("limit", "101"), b.owner()).andExpect(status().isBadRequest());
  }

  @Test
  void concurrentAcknowledgementsEmitExactlyOneAudit() throws Exception {
    var b = binding("FAMILY");
    String id = create(b).path("id").asText();
    var statuses =
        concurrently(() -> ack(b, b.owner(), id, "\"0\"").andReturn().getResponse().getStatus());
    assertThat(statuses).containsExactlyInAnyOrder(200, 412);
    assertThat(events(b, "CHILD_HELP_ACKNOWLEDGED")).isEqualTo(1);
  }

  @Test
  void failedAuditRollsBackTheHelpMutation() throws Exception {
    var b = binding("FAMILY");
    String id = create(b).path("id").asText();
    doThrow(new IllegalStateException("fixture audit unavailable"))
        .when(
            org.springframework.test.util.AopTestUtils.<AuditService>getUltimateTargetObject(audit))
        .record(eq(b.tenant()), anyString(), eq("CHILD_HELP_ACKNOWLEDGED"), eq(id));
    try {
      ack(b, b.owner(), id, "\"0\"").andExpect(status().is5xxServerError());
    } catch (jakarta.servlet.ServletException expected) {
      /* transaction failure */
    }
    assertThat(
            db.queryForObject(
                "SELECT state FROM child_help_requests WHERE tenant_id=? AND id=?",
                String.class,
                b.tenant(),
                id))
        .isEqualTo("OPEN");
    assertThat(events(b, "CHILD_HELP_ACKNOWLEDGED")).isZero();
  }

  @Test
  void malformedInputAndAdultTokensCannotCreateDeviceRequests() throws Exception {
    var b = binding("FAMILY");
    submit(b, "not-a-uuid", "NEED_HELP").andExpect(status().isBadRequest());
    submit(b, uuid(), "FREE_TEXT").andExpect(status().isBadRequest());
    mvc.perform(
            post(DEVICE_ROUTE).with(jwt()).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isForbidden());
    mvc.perform(get(DEVICE_ROUTE + "/" + uuid())).andExpect(status().isUnauthorized());
    assertThat(events(b, "CHILD_HELP_REQUESTED")).isZero();
  }

  List<Integer> concurrently(Callable<Integer> action) throws Exception {
    var pool = Executors.newFixedThreadPool(2);
    var ready = new CountDownLatch(2);
    var go = new CountDownLatch(1);
    Callable<Integer> task =
        () -> {
          ready.countDown();
          if (!go.await(10, TimeUnit.SECONDS)) throw new IllegalStateException("barrier timeout");
          return action.call();
        };
    try {
      var a = pool.submit(task);
      var b = pool.submit(task);
      assertThat(ready.await(10, TimeUnit.SECONDS)).isTrue();
      go.countDown();
      return List.of(a.get(20, TimeUnit.SECONDS), b.get(20, TimeUnit.SECONDS));
    } finally {
      go.countDown();
      pool.shutdownNow();
      assertThat(pool.awaitTermination(10, TimeUnit.SECONDS)).isTrue();
    }
  }
}

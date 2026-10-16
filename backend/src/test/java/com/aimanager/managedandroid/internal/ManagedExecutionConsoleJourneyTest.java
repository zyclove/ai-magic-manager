package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Set;
import javax.sql.DataSource;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Real MVC/security/SQL; binding and publication admission are explicit local fixtures. */
@SpringBootTest(
    properties = {
      "spring.datasource.url=jdbc:h2:mem:execution-console;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "springdoc.api-docs.enabled=true"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ManagedExecutionConsoleJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired DataSource source;
  @Autowired JdbcTemplate db;
  @Autowired ManagedPolicyExecutionJournal journal;
  @Autowired ManagedAndroidGateway gateway;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean ManagedAgentBindingStore bindings;
  @MockitoBean ManagedExecutionPublicationAccess publications;
  ManagedExecutionTestData data;
  ManagedExecutionTestData.Fixture f;
  ManagedPolicyExecutionJournal.View task;

  @TestConfiguration
  static class Provider {
    @Bean
    @Primary
    ManagedAndroidGateway consoleTestGateway() {
      var gateway = mock(ManagedAndroidGateway.class);
      when(gateway.providerCode()).thenReturn("LOCAL_TEST");
      return gateway;
    }
  }

  @BeforeEach
  void setup() {
    data = new ManagedExecutionTestData(source);
    f = data.fixture();
    task = enqueue(f);
    clearInvocations(gateway);
  }

  @AfterEach
  void removeOwnedTasks() {
    // claimDue is provider-wide. Remove only this case's tasks so subsequent cases never lease
    // them.
    if (f != null)
      db.update("DELETE FROM managed_policy_execution_tasks WHERE tenant_id=?", f.tenant());
  }

  @Test
  void administratorCanReadARealExecutionWithoutReceivingInternalMaterial() throws Exception {
    var page =
        body(
            mvc.perform(get(root()).with(actor(f.actor())))
                .andExpect(status().isOk())
                .andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(
                    header()
                        .stringValues(
                            "Vary",
                            org.hamcrest.Matchers.hasItem(
                                org.hamcrest.Matchers.containsString("Authorization"))))
                .andExpect(header().doesNotExist("ETag"))
                .andReturn()
                .getResponse()
                .getContentAsString());
    assertThat(page.path("items").size()).isEqualTo(1);
    assertThat(page.path("items").get(0).path("id").asText()).isEqualTo(task.id());
    var detail =
        body(
            mvc.perform(get(path()).with(actor(f.actor())))
                .andExpect(status().isOk())
                .andExpect(header().string("ETag", "\"1\""))
                .andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(
                    header()
                        .stringValues(
                            "Vary",
                            org.hamcrest.Matchers.hasItem(
                                org.hamcrest.Matchers.containsString("Authorization"))))
                .andReturn()
                .getResponse()
                .getContentAsString());
    assertThat(fields(detail))
        .containsExactlyInAnyOrder(
            "id",
            "publicationId",
            "deviceId",
            "registrationId",
            "state",
            "reason",
            "revision",
            "createdAt",
            "updatedAt",
            "cancellationRequested");
    assertThat(detail.path("state").asText()).isEqualTo("READY_TO_WRITE");
    assertThat(detail.toString())
        .doesNotContain(f.enterprise(), f.providerDevice(), "documentJson", "leaseToken");
  }

  @ParameterizedTest
  @ValueSource(strings = {"OWNER", "ORG_ADMIN", "AUDITOR"})
  void readRolesCanReadListDetailAndEvents(String role) throws Exception {
    role(role);
    for (String endpoint : List.of(root(), path(), path() + "/events")) {
      mvc.perform(get(endpoint).with(actor(f.actor()))).andExpect(status().isOk());
    }
  }

  @ParameterizedTest
  @ValueSource(strings = {"GUARDIAN", "TEACHER", "CHILD"})
  void otherRolesCannotInspectOrCancelExecutions(String role) throws Exception {
    role(role);
    for (String endpoint : List.of(root(), path(), path() + "/events")) {
      mvc.perform(get(endpoint).with(actor(f.actor()))).andExpect(status().isForbidden());
    }
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isForbidden());
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void anonymousRequestsCannotReachTheConsole() throws Exception {
    for (String endpoint : List.of(root(), path(), path() + "/events")) {
      mvc.perform(get(endpoint)).andExpect(status().isUnauthorized());
    }
    mvc.perform(post(path() + "/cancel").header("If-Match", "\"1\""))
        .andExpect(status().isUnauthorized());
  }

  @Test
  void auditorCannotCancelAndRevokedMembershipCannotRead() throws Exception {
    role("AUDITOR");
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    mvc.perform(get(path()).with(actor(f.actor()))).andExpect(status().isForbidden());
    mvc.perform(get(path() + "/events").with(actor(f.actor()))).andExpect(status().isForbidden());
  }

  @Test
  void anotherTenantCannotReadTaskOrUseItsCursor() throws Exception {
    var other = data.fixture();
    String otherRoot = "/api/v1/tenants/" + other.tenant() + "/managed-android/executions";
    mvc.perform(get(path()).with(actor(other.actor()))).andExpect(status().isForbidden());
    mvc.perform(get(otherRoot + "/" + task.id()).with(actor(other.actor())))
        .andExpect(status().isForbidden());
    mvc.perform(get(otherRoot + "/" + task.id() + "/events").with(actor(other.actor())))
        .andExpect(status().isForbidden());
    mvc.perform(get(otherRoot).param("cursor", task.id()).with(actor(other.actor())))
        .andExpect(status().isBadRequest());
    mvc.perform(
            post(otherRoot + "/" + task.id() + "/cancel")
                .with(actor(other.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isForbidden());
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void listSupportsEmptyFiltersAndStableTimeTiePagination() throws Exception {
    var rows = new ArrayList<ManagedPolicyExecutionJournal.View>();
    rows.add(task);
    for (int i = 0; i < 2; i++) {
      // Historical fixture setup only; cancellation behavior is exercised through HTTP below.
      db.update(
          "UPDATE managed_policy_execution_tasks SET state='CANCELLED',active_device_id=NULL"
              + " WHERE tenant_id=? AND id=?",
          f.tenant(),
          rows.get(rows.size() - 1).id());
      rows.add(enqueue(data.publication(f, "ENFORCE")));
    }
    db.update(
        "UPDATE managed_policy_execution_tasks SET created_at=100 WHERE tenant_id=?", f.tenant());
    var expected =
        rows.stream()
            .map(ManagedPolicyExecutionJournal.View::id)
            .sorted(Comparator.reverseOrder())
            .toList();
    var actual = new ArrayList<String>();
    String cursor = null;
    do {
      var request =
          get(root()).param("limit", "1").param("deviceId", f.device()).with(actor(f.actor()));
      if (cursor != null) request.param("cursor", cursor);
      var page =
          body(
              mvc.perform(request)
                  .andExpect(status().isOk())
                  .andReturn()
                  .getResponse()
                  .getContentAsString());
      assertThat(page.path("items").size()).isEqualTo(1);
      actual.add(page.path("items").get(0).path("id").asText());
      cursor = page.path("nextCursor").isNull() ? null : page.path("nextCursor").asText();
      assertThat(actual.size()).isLessThanOrEqualTo(3);
    } while (cursor != null);
    assertThat(actual).containsExactlyElementsOf(expected);
    // Oppose ID order to prove creation time, not UUID spelling, is the primary sort key.
    var byTime = rows.stream().map(ManagedPolicyExecutionJournal.View::id).sorted().toList();
    for (int i = 0; i < byTime.size(); i++) {
      db.update(
          "UPDATE managed_policy_execution_tasks SET created_at=? WHERE tenant_id=? AND id=?",
          103 - i,
          f.tenant(),
          byTime.get(i));
    }
    var timed =
        body(
            mvc.perform(get(root()).param("limit", "2").with(actor(f.actor())))
                .andExpect(status().isOk())
                .andReturn()
                .getResponse()
                .getContentAsString());
    assertThat(timed.path("items").get(0).path("id").asText()).isEqualTo(byTime.get(0));
    assertThat(timed.path("items").get(1).path("id").asText()).isEqualTo(byTime.get(1));
    mvc.perform(
            get(root()).param("cursor", timed.path("nextCursor").asText()).with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].id").value(byTime.get(2)))
        .andExpect(jsonPath("$.items.length()").value(1));
    mvc.perform(get(root()).param("publicationId", task.publicationId()).with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(1));
    mvc.perform(get(root()).param("state", "CANCELLED").with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(2));
    mvc.perform(get(root()).param("deviceId", ManagedExecutionTestData.id()).with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.items.length()").value(0));
  }

  @ParameterizedTest
  @ValueSource(strings = {"0", "101", "-1", "not-a-number"})
  void invalidPageSizesAreRejected(String limit) throws Exception {
    mvc.perform(get(root()).param("limit", limit).with(actor(f.actor())))
        .andExpect(status().isBadRequest());
    mvc.perform(get(path() + "/events").param("limit", limit).with(actor(f.actor())))
        .andExpect(status().isBadRequest());
  }

  @Test
  void malformedFiltersAndMissingCursorAnchorAreRejected() throws Exception {
    for (String parameter : List.of("deviceId", "publicationId", "state", "cursor")) {
      mvc.perform(get(root()).param(parameter, "invalid").with(actor(f.actor())))
          .andExpect(status().isBadRequest());
    }
    mvc.perform(get(root()).param("cursor", ManagedExecutionTestData.id()).with(actor(f.actor())))
        .andExpect(status().isBadRequest());
    mvc.perform(
            get(root()).param("cursor", task.id()).param("state", "APPLIED").with(actor(f.actor())))
        .andExpect(status().isBadRequest());
  }

  @Test
  void deletedTaskCannotRemainACursorOrLeakAnEmptyTimeline() throws Exception {
    db.update(
        "DELETE FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?",
        f.tenant(),
        task.id());
    mvc.perform(get(root()).param("cursor", task.id()).with(actor(f.actor())))
        .andExpect(status().isBadRequest());
    mvc.perform(get(path()).with(actor(f.actor()))).andExpect(status().isForbidden());
    mvc.perform(get(path() + "/events").with(actor(f.actor()))).andExpect(status().isForbidden());
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isForbidden());
  }

  @Test
  void aRevokedAdministratorCannotCancelWithAFreshTokenAndVersion() throws Exception {
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isForbidden());
    assertThat(revision()).isEqualTo(1);
    assertThat(events()).isEqualTo(1);
  }

  @Test
  void eventsAreBoundedOrderedAndRedacted() throws Exception {
    var claim = claim();
    assertThat(journal.beforeWrite(claim)).isTrue();
    var first =
        body(
            mvc.perform(get(path() + "/events").param("limit", "1").with(actor(f.actor())))
                .andExpect(status().isOk())
                .andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(
                    header()
                        .stringValues(
                            "Vary",
                            org.hamcrest.Matchers.hasItem(
                                org.hamcrest.Matchers.containsString("Authorization"))))
                .andReturn()
                .getResponse()
                .getContentAsString());
    assertThat(first.path("items").get(0).path("revision").asLong()).isEqualTo(1);
    assertThat(first.path("nextCursor").asText()).isEqualTo("1");
    assertThat(fields(first.path("items").get(0)))
        .containsExactlyInAnyOrder("revision", "state", "reason", "occurredAt");
    var next =
        body(
            mvc.perform(get(path() + "/events").param("cursor", "1").with(actor(f.actor())))
                .andExpect(status().isOk())
                .andReturn()
                .getResponse()
                .getContentAsString());
    assertThat(next.path("items").size()).isEqualTo(2);
    assertThat(next.path("items").get(0).path("revision").asLong()).isEqualTo(2);
    assertThat(next.path("items").get(1).path("revision").asLong()).isEqualTo(3);
    assertThat(next.path("nextCursor").isNull()).isTrue();
    assertThat(next.toString()).doesNotContain(claim.token(), f.enterprise(), f.providerDevice());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {"0", "-1", "01", "1.0", "9007199254740991", "9223372036854775808", "invalid"})
  void eventCursorMustBeACanonicalPositiveRevision(String cursor) throws Exception {
    mvc.perform(get(path() + "/events").param("cursor", cursor).with(actor(f.actor())))
        .andExpect(status().isBadRequest());
  }

  @ParameterizedTest
  @NullSource
  @ValueSource(strings = {"*", "W/\"1\"", "\"1\",\"2\"", "bad", "\"-1\""})
  void cancellationRequiresASingleStrongVersion(String tag) throws Exception {
    var request = post(path() + "/cancel").with(actor(f.actor()));
    if (tag != null) request.header("If-Match", tag);
    mvc.perform(request).andExpect(status().is(tag == null ? 428 : 400));
    assertThat(revision()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(strings = {"missing", "old", "future", "password-only"})
  void cancellationRequiresRecentMultifactorAuthentication(String kind) throws Exception {
    var authentication =
        jwt()
            .jwt(
                token -> {
                  token.subject(f.actor());
                  if (!kind.equals("missing"))
                    token.claim(
                        "auth_time",
                        Instant.now().getEpochSecond()
                            + (kind.equals("old") ? -3600 : kind.equals("future") ? 3600 : 0));
                  token.claim(
                      "amr", kind.equals("password-only") ? List.of("pwd") : List.of("pwd", "otp"));
                });
    mvc.perform(post(path() + "/cancel").with(authentication).header("If-Match", "\"1\""))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void staleCancellationCannotOverwriteWorkerProgress() throws Exception {
    claim();
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isPreconditionFailed())
        .andExpect(jsonPath("$.errorCode").value("RESOURCE_VERSION_CONFLICT"));
    assertThat(revision()).isEqualTo(2);
    assertThat(events()).isEqualTo(2);
  }

  @ParameterizedTest
  @ValueSource(strings = {"OWNER", "ORG_ADMIN"})
  void cancellationIsVersionedAuditedAndDoesNotCallTheProvider(String role) throws Exception {
    role(role);
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"2\""))
        .andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(jsonPath("$.state").value("CANCELLED"));
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isPreconditionFailed());
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"2\""))
        .andExpect(status().isOk())
        .andExpect(header().string("ETag", "\"2\""));
    assertThat(events()).isEqualTo(2);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND resource_id=?"
                    + " AND action='MANAGED_EXECUTION_CANCEL_REQUESTED'",
                Long.class,
                f.tenant(),
                task.id()))
        .isEqualTo(1);
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  @Test
  void unknownWriteCancellationRetainsReviewAndRejectsALateReceipt() throws Exception {
    var claim = claim();
    journal.beforeWrite(claim);
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"3\""))
        .andExpect(status().isOk())
        .andExpect(jsonPath("$.state").value("NEEDS_REVIEW"))
        .andExpect(jsonPath("$.cancellationRequested").value(true));
    assertThat(
            db.queryForObject(
                "SELECT active_device_id FROM managed_policy_execution_tasks WHERE tenant_id=? AND"
                    + " id=?",
                String.class,
                f.tenant(),
                task.id()))
        .isEqualTo(f.device());
    assertThat(
            journal.policyWritten(
                claim,
                new ManagedAndroidGateway.PolicyReceipt(
                    "enterprises/" + claim.enterpriseId() + "/policies/" + claim.policyId(), 7L)))
        .isFalse();
  }

  @Test
  void appliedTaskCannotBeUndoneByCancel() throws Exception {
    // This fixture selects the established APPLIED state; journal lifecycle tests prove its
    // admission.
    db.update(
        "UPDATE managed_policy_execution_tasks SET"
            + " state='APPLIED',provider_version=7,active_device_id=NULL WHERE tenant_id=? AND"
            + " id=?",
        f.tenant(),
        task.id());
    mvc.perform(post(path() + "/cancel").with(actor(f.actor())).header("If-Match", "\"1\""))
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_ALREADY_APPLIED_USE_NEW_POLICY"));
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void openApiPublishesTheFourConsoleOperations() throws Exception {
    var schema =
        body(
            mvc.perform(get("/v3/api-docs").with(actor(f.actor())))
                .andExpect(status().isOk())
                .andReturn()
                .getResponse()
                .getContentAsString());
    var paths = schema.path("paths");
    String root = "/api/v1/tenants/{tenant}/managed-android/executions";
    assertThat(paths.path(root).has("get")).isTrue();
    assertThat(paths.path(root + "/{id}").has("get")).isTrue();
    assertThat(paths.path(root + "/{id}/events").has("get")).isTrue();
    assertThat(paths.path(root + "/{id}/cancel").has("post")).isTrue();
  }

  private ManagedPolicyExecutionJournal.View enqueue(ManagedExecutionTestData.Fixture fixture) {
    var context =
        new ManagedAgentBindingStore.VerifiedBindingContext(
            fixture.tenant(),
            fixture.actor(),
            0,
            fixture.subject(),
            fixture.device(),
            fixture.registration(),
            "a".repeat(64),
            fixture.binding(),
            2,
            fixture.enrollment(),
            1,
            "LOCAL_TEST",
            fixture.enterprise(),
            1,
            fixture.providerDevice(),
            "DEVICE_OWNER",
            2,
            "com.aimanager.child",
            "b".repeat(64),
            Device.Platform.ANDROID,
            1);
    when(bindings.requireVerifiedContext(fixture.tenant(), fixture.actor(), fixture.binding(), 2))
        .thenReturn(context);
    when(publications.requireTarget(
            fixture.tenant(),
            fixture.actor(),
            fixture.publication(),
            fixture.device(),
            fixture.registration()))
        .thenReturn(
            new ManagedExecutionPublicationAccess.Publication(
                fixture.version(), "c".repeat(64), 1));
    return journal.enqueue(
        fixture.tenant(),
        fixture.actor(),
        fixture.publication(),
        fixture.binding(),
        2,
        "{\"schemaVersion\":1,\"adapterRevision\":\"local-v1\",\"policy\":{\"applications\":[]}}",
        System.currentTimeMillis() + 600_000);
  }

  private ManagedPolicyExecutionJournal.Claim claim() {
    return journal.claimDue("LOCAL_TEST", 25).stream()
        .filter(c -> c.taskId().equals(task.id()))
        .findFirst()
        .orElseThrow();
  }

  private String root() {
    return "/api/v1/tenants/" + f.tenant() + "/managed-android/executions";
  }

  private String path() {
    return root() + "/" + task.id();
  }

  private JsonNode body(String text) throws Exception {
    return json.readTree(text);
  }

  private Set<String> fields(JsonNode value) {
    var fields = new java.util.HashSet<String>();
    value.fieldNames().forEachRemaining(fields::add);
    return fields;
  }

  private void role(String role) {
    db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
  }

  private long revision() {
    return db.queryForObject(
        "SELECT revision FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?",
        Long.class,
        f.tenant(),
        task.id());
  }

  private long events() {
    return db.queryForObject(
        "SELECT COUNT(*) FROM managed_policy_execution_events WHERE tenant_id=? AND task_id=?",
        Long.class,
        f.tenant(),
        task.id());
  }

  private RequestPostProcessor actor(String actor) {
    return jwt()
        .jwt(
            token ->
                token
                    .subject(actor)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")));
  }
}

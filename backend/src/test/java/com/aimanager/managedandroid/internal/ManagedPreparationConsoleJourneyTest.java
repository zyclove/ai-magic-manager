package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
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
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import javax.sql.DataSource;
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
import org.springframework.test.web.servlet.ResultActions;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/**
 * Real MVC/security/SQL projections and cancellation. Seeded rows are not EMM qualification proof.
 */
@SpringBootTest(
    properties = {
      "spring.datasource.url=jdbc:h2:mem:preparation-console;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "springdoc.api-docs.enabled=true"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ManagedPreparationConsoleJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired DataSource source;
  @Autowired ObjectMapper json;
  @Autowired ManagedPolicyExecutionJournal executions;
  @Autowired ManagedAndroidGateway gateway;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean ManagedAgentBindingStore bindings;
  @MockitoBean ManagedExecutionPublicationAccess publications;
  ManagedExecutionTestData data;
  ManagedExecutionTestData.Fixture f;
  String request;

  @TestConfiguration
  static class Provider {
    @Bean
    @Primary
    ManagedAndroidGateway preparationConsoleGateway() {
      var provider = mock(ManagedAndroidGateway.class);
      when(provider.providerCode()).thenReturn("LOCAL_TEST");
      return provider;
    }
  }

  @BeforeEach
  void setup() {
    data = new ManagedExecutionTestData(source);
    f = data.fixture();
    request = seed(f, "PENDING");
    clearInvocations(gateway, bindings, publications);
  }

  @Test
  void listAndDetailExposeOnlySafeProgressWithPrivateCacheHeaders() throws Exception {
    var page = read(list()).andExpect(header().doesNotExist("ETag"));
    var item = body(page).path("items").get(0);
    assertThat(item.path("id").asText()).isEqualTo(request);
    var detail = body(read(get(path())).andExpect(header().string("ETag", "\"1\"")));
    assertThat(fields(detail))
        .containsExactlyInAnyOrder(
            "id",
            "publicationId",
            "versionId",
            "deviceId",
            "registrationId",
            "state",
            "reasonCode",
            "revision",
            "executionTaskId",
            "expiresAt",
            "createdAt",
            "updatedAt");
    assertThat(detail).isEqualTo(item);
    assertThat(detail.path("state").asText()).isEqualTo("PENDING");
    assertThat(detail.path("executionTaskId").isNull()).isTrue();
    assertThat(detail.toString())
        .doesNotContain(
            f.actor(), f.enterprise(), f.providerDevice(), "leaseToken", "contextSha256");
    verifyNoInteractions(gateway, bindings, publications);
  }

  @ParameterizedTest
  @ValueSource(strings = {"OWNER", "ORG_ADMIN", "AUDITOR"})
  void currentReadRolesCanSeeListDetailAndSummary(String role) throws Exception {
    role(role);
    read(list());
    read(get(path()));
    read(summary());
  }

  @ParameterizedTest
  @ValueSource(strings = {"GUARDIAN", "TEACHER", "CHILD"})
  void otherRolesCannotReadOrCancel(String role) throws Exception {
    role(role);
    for (var query : List.of(list(), get(path()), summary()))
      mvc.perform(query.with(actor(f.actor()))).andExpect(status().isForbidden());
    cancel("\"1\"").andExpect(status().isForbidden());
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void anonymousRequestsAreRejectedBeforeRouting() throws Exception {
    for (var query : List.of(list(), get(path()), summary()))
      mvc.perform(query).andExpect(status().isUnauthorized());
    mvc.perform(post(path() + "/cancel").header("If-Match", "\"1\""))
        .andExpect(status().isUnauthorized());
  }

  @Test
  void auditorCannotCancelAndRevokedMembershipCannotRead() throws Exception {
    role("AUDITOR");
    cancel("\"1\"").andExpect(status().isForbidden());
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    for (var query : List.of(list(), get(path()), summary()))
      mvc.perform(query.with(actor(f.actor()))).andExpect(status().isForbidden());
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void tenantAndPublicationScopeCannotBeBorrowedFromAnotherMembership() throws Exception {
    var other = data.fixture();
    mvc.perform(list().with(actor(other.actor()))).andExpect(status().isForbidden());
    String otherRoot = root(other.tenant());
    mvc.perform(get(otherRoot + "/" + request).with(actor(other.actor())))
        .andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("PREPARATION_REQUEST_NOT_FOUND"));
    mvc.perform(get(otherRoot).param("publicationId", f.publication()).with(actor(other.actor())))
        .andExpect(status().isForbidden());
    mvc.perform(
            get(otherRoot + "/summary")
                .param("publicationId", f.publication())
                .with(actor(other.actor())))
        .andExpect(status().isForbidden());
    mvc.perform(
            post(otherRoot + "/" + request + "/cancel")
                .header("If-Match", "\"1\"")
                .with(actor(other.actor())))
        .andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("PREPARATION_REQUEST_NOT_FOUND"));
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void unknownResourcesDoNotMasqueradeAsAnEmptySuccessfulPublication() throws Exception {
    String missing = ManagedExecutionTestData.id();
    mvc.perform(get(root()).param("publicationId", missing).with(actor(f.actor())))
        .andExpect(status().isForbidden());
    mvc.perform(get(root() + "/summary").param("publicationId", missing).with(actor(f.actor())))
        .andExpect(status().isForbidden());
    mvc.perform(get(root() + "/" + missing).with(actor(f.actor())))
        .andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("PREPARATION_REQUEST_NOT_FOUND"));
  }

  @ParameterizedTest
  @ValueSource(strings = {"0", "51", "-1", "not-a-number"})
  void pageSizesAreBoundedAtFifty(String limit) throws Exception {
    mvc.perform(list().param("limit", limit).with(actor(f.actor())))
        .andExpect(status().isBadRequest());
  }

  @Test
  void publicationFilterIsRequiredAndCanonical() throws Exception {
    for (String endpoint : List.of(root(), root() + "/summary")) {
      mvc.perform(get(endpoint).with(actor(f.actor()))).andExpect(status().isBadRequest());
      for (String invalid : List.of("", "not-a-uuid", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"))
        mvc.perform(get(endpoint).param("publicationId", invalid).with(actor(f.actor())))
            .andExpect(status().isBadRequest());
    }
  }

  @ParameterizedTest
  @ValueSource(strings = {"", "not-a-uuid", "1-1-1-1-1", "../../other"})
  void malformedCursorsAreRejected(String cursor) throws Exception {
    mvc.perform(list().param("cursor", cursor).with(actor(f.actor())))
        .andExpect(status().isBadRequest());
  }

  @Test
  void cursorMustExistInTheSameTenantAndPublication() throws Exception {
    var second = data.publication(f, "ENFORCE");
    String sibling = seed(second, "CANCELLED");
    String foreign = seed(data.fixture(), "CANCELLED");
    for (String cursor : List.of(ManagedExecutionTestData.id(), sibling, foreign))
      mvc.perform(list().param("cursor", cursor).with(actor(f.actor())))
          .andExpect(status().isBadRequest())
          .andExpect(jsonPath("$.errorCode").value("INVALID_CURSOR"));
  }

  @Test
  void allFiftyTargetsHaveStableIdPaginationWithoutDuplicateOrMissingRows() throws Exception {
    var expected = new ArrayList<String>();
    expected.add(request);
    for (int i = 1; i < 50; i++) expected.add(seed(addDevice(), "CANCELLED"));
    expected.sort(String::compareTo);
    var first = body(read(list().param("limit", "49")));
    assertThat(first.path("items").size()).isEqualTo(49);
    var actual = new ArrayList<String>();
    first.path("items").forEach(row -> actual.add(row.path("id").asText()));
    String cursor = first.path("nextCursor").asText();
    assertThat(cursor).isEqualTo(actual.get(48));
    // Mutating state does not invalidate an anchor; pagination is not filtered on mutable state.
    db.update(
        "UPDATE managed_policy_preparation_requests SET state='CANCELLED',active_device_id=NULL"
            + " WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    var second = body(read(list().param("limit", "49").param("cursor", cursor)));
    second.path("items").forEach(row -> actual.add(row.path("id").asText()));
    assertThat(second.path("nextCursor").isNull()).isTrue();
    assertThat(actual).containsExactlyElementsOf(expected);
    assertThat(body(read(list())).path("items").size()).isEqualTo(50);
  }

  @Test
  void emptyExistingPublicationHasZeroCountsAndNoSuccessOrAppliedFlag() throws Exception {
    var empty = data.publication(f, "CONFIGURE_ONLY");
    var list = body(read(get(root()).param("publicationId", empty.publication())));
    assertThat(list.path("items").isEmpty()).isTrue();
    assertThat(list.path("nextCursor").isNull()).isTrue();
    var summary = body(read(get(root() + "/summary").param("publicationId", empty.publication())));
    assertThat(fields(summary))
        .containsExactlyInAnyOrder("total", "pending", "admitted", "rejected", "cancelled");
    summary.elements().forEachRemaining(value -> assertThat(value.asLong()).isZero());
  }

  @Test
  void aggregateCountsAreScopedAndAdmittedStillDoesNotMeanDeviceApplied() throws Exception {
    seed(addDevice(), "REJECTED");
    seed(addDevice(), "CANCELLED");
    var target = addDevice();
    var task = enqueue(target);
    seedAdmitted(target, task.id());
    seed(data.publication(f, "ENFORCE"), "REJECTED");
    seed(data.fixture(), "REJECTED");
    var counts = body(read(summary()));
    assertThat(counts.path("total").asInt()).isEqualTo(4);
    for (String state : List.of("pending", "admitted", "rejected", "cancelled"))
      assertThat(counts.path(state).asInt()).isEqualTo(1);
    assertThat(fields(counts))
        .containsExactlyInAnyOrder("total", "pending", "admitted", "rejected", "cancelled");
    assertThat(
            db.queryForObject(
                "SELECT state FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?",
                String.class,
                f.tenant(),
                task.id()))
        .isEqualTo("READY_TO_WRITE");
  }

  @ParameterizedTest
  @ValueSource(strings = {"OWNER", "ORG_ADMIN"})
  void currentAdministratorsCanCancelWithStrongVersionAndRepeatCurrentResult(String role)
      throws Exception {
    role(role);
    var result =
        body(
            cancel("\"1\"")
                .andExpect(status().isOk())
                .andExpect(header().string("ETag", "\"2\""))
                .andExpect(header().string("Cache-Control", "no-store")));
    assertThat(result.path("state").asText()).isEqualTo("CANCELLED");
    assertThat(result.path("reasonCode").asText()).isEqualTo("CANCELLED_BY_ADMINISTRATOR");
    cancel("\"2\"").andExpect(status().isOk()).andExpect(header().string("ETag", "\"2\""));
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND"
                    + " action='PREPARATION_CANCELLED'",
                Integer.class,
                f.tenant()))
        .isEqualTo(1);
    assertThat(
            db.queryForMap(
                    "SELECT active_device_id,lease_token,lease_until FROM"
                        + " managed_policy_preparation_requests WHERE tenant_id=? AND id=?",
                    f.tenant(),
                    request)
                .values())
        .containsOnlyNulls();
    verifyNoInteractions(gateway, bindings, publications);
  }

  @ParameterizedTest
  @ValueSource(strings = {"missing", "old", "future", "password-only"})
  void cancellationRequiresRecentMultiFactorFacts(String kind) throws Exception {
    var token =
        jwt()
            .jwt(
                builder -> {
                  builder.subject(f.actor());
                  if (!kind.equals("missing"))
                    builder.claim(
                        "auth_time",
                        Instant.now()
                            .plusSeconds(
                                kind.equals("future") ? 3600 : kind.equals("old") ? -3600 : 0)
                            .getEpochSecond());
                  builder.claim(
                      "amr", kind.equals("password-only") ? List.of("pwd") : List.of("pwd", "otp"));
                });
    mvc.perform(post(path() + "/cancel").header("If-Match", "\"1\"").with(token))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    assertThat(revision()).isEqualTo(1);
  }

  @ParameterizedTest
  @NullSource
  @ValueSource(strings = {"*", "W/\"1\"", "1", "\"1\",\"2\"", "\"0\""})
  void cancellationRequiresOneStrongIfMatch(String version) throws Exception {
    cancel(version)
        .andExpect(status().is(version == null ? 428 : version.equals("\"0\"") ? 412 : 400));
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void staleVersionCannotCancelALaterAttempt() throws Exception {
    db.update(
        "UPDATE managed_policy_preparation_requests SET revision=2 WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    cancel("\"1\"").andExpect(status().isPreconditionFailed());
    assertThat(revision()).isEqualTo(2);
  }

  @Test
  void cancellationInvalidatesAnInFlightReadLease() throws Exception {
    db.update(
        "UPDATE managed_policy_preparation_requests SET"
            + " generation=1,attempts=1,lease_token=?,lease_until=?,revision=2 WHERE tenant_id=?"
            + " AND id=?",
        ManagedExecutionTestData.id(),
        System.currentTimeMillis() + 20000,
        f.tenant(),
        request);
    cancel("\"2\"").andExpect(status().isOk()).andExpect(jsonPath("$.state").value("CANCELLED"));
    assertThat(
            db.queryForObject(
                "SELECT lease_token FROM managed_policy_preparation_requests WHERE tenant_id=? AND"
                    + " id=?",
                String.class,
                f.tenant(),
                request))
        .isNull();
  }

  @Test
  void admittedConflictRequiresExplicitExecutionActionAndNeverCancelsTheTask() throws Exception {
    db.update(
        "UPDATE managed_policy_preparation_requests SET state='CANCELLED',active_device_id=NULL"
            + " WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    var task = enqueue(f);
    db.update(
        "UPDATE managed_policy_preparation_requests SET state='ADMITTED',execution_task_id=? WHERE"
            + " tenant_id=? AND id=?",
        task.id(),
        f.tenant(),
        request);
    cancel("\"1\"")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("PREPARATION_ALREADY_ADMITTED"));
    var detail = body(read(get(path())));
    assertThat(detail.path("executionTaskId").asText()).isEqualTo(task.id());
    assertThat(executions.get(f.tenant(), f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.READY_TO_WRITE);
  }

  @Test
  void rejectedRequestCannotBeReopenedByCancellation() throws Exception {
    db.update(
        "UPDATE managed_policy_preparation_requests SET state='REJECTED',active_device_id=NULL"
            + " WHERE tenant_id=? AND id=?",
        f.tenant(),
        request);
    cancel("\"1\"")
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("PREPARATION_ALREADY_TERMINAL"));
    assertThat(revision()).isEqualTo(1);
  }

  @Test
  void openApiDescribesOnlyReadSummaryDetailAndLocalCancellation() throws Exception {
    var paths =
        body(mvc.perform(get("/v3/api-docs").with(actor(f.actor()))).andExpect(status().isOk()))
            .path("paths");
    String root = "/api/v1/tenants/{tenant}/managed-android/preparation-requests";
    assertThat(paths.path(root).has("get")).isTrue();
    assertThat(paths.path(root + "/summary").has("get")).isTrue();
    assertThat(paths.path(root + "/{id}").has("get")).isTrue();
    assertThat(paths.path(root + "/{id}/cancel").has("post")).isTrue();
    assertThat(paths.path(root).has("post")).isFalse();
  }

  private String seed(ManagedExecutionTestData.Fixture target, String state) {
    String id = ManagedExecutionTestData.id();
    long now = System.currentTimeMillis();
    db.update(
        "INSERT INTO"
            + " managed_policy_preparation_requests(tenant_id,id,publication_id,policy_version_id,subject_id,device_id,registration_id,binding_id,binding_version,actor_id,authority_version,context_sha256,state,revision,reason_code,active_device_id,generation,attempts,next_attempt_at,expires_at,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,?,?,?,2,?,0,?,?,1,'QUEUED',?,0,0,?,?,?,?)",
        target.tenant(),
        id,
        target.publication(),
        target.version(),
        target.subject(),
        target.device(),
        target.registration(),
        target.binding(),
        target.actor(),
        "c".repeat(64),
        state,
        state.equals("PENDING") ? target.device() : null,
        now,
        now + 600000,
        now,
        now);
    return id;
  }

  private void seedAdmitted(ManagedExecutionTestData.Fixture target, String task) {
    String id = seed(target, "CANCELLED");
    db.update(
        "UPDATE managed_policy_preparation_requests SET state='ADMITTED',execution_task_id=? WHERE"
            + " tenant_id=? AND id=?",
        task,
        target.tenant(),
        id);
  }

  /**
   * Read projection fixture: rows satisfy SQL references; no assertion of binding qualification.
   */
  private ManagedExecutionTestData.Fixture addDevice() {
    String device = ManagedExecutionTestData.id(), registration = ManagedExecutionTestData.id();
    db.update(
        "INSERT INTO"
            + " devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at)"
            + " VALUES(?,?,?,?,'fixture','ANDROID','14','ACTIVE','{}',?,1)",
        f.tenant(),
        device,
        f.subject(),
        registration,
        "a".repeat(64));
    return new ManagedExecutionTestData.Fixture(
        f.tenant(),
        f.actor(),
        f.subject(),
        device,
        registration,
        f.binding(),
        f.enrollment(),
        f.enterprise(),
        f.providerDevice(),
        f.publication(),
        f.version());
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
    return executions.enqueue(
        fixture.tenant(),
        fixture.actor(),
        fixture.publication(),
        fixture.binding(),
        2,
        "{\"schemaVersion\":1,\"adapterRevision\":\"local-v1\",\"policy\":{\"applications\":[]}}",
        System.currentTimeMillis() + 600_000);
  }

  private String root() {
    return root(f.tenant());
  }

  private String root(String tenant) {
    return "/api/v1/tenants/" + tenant + "/managed-android/preparation-requests";
  }

  private String path() {
    return root() + "/" + request;
  }

  private MockHttpServletRequestBuilder list() {
    return get(root()).param("publicationId", f.publication());
  }

  private MockHttpServletRequestBuilder summary() {
    return get(root() + "/summary").param("publicationId", f.publication());
  }

  private RequestPostProcessor actor(String who) {
    return jwt()
        .jwt(
            token ->
                token
                    .subject(who)
                    .claim("auth_time", Instant.now().getEpochSecond())
                    .claim("amr", List.of("pwd", "otp")));
  }

  private ResultActions read(MockHttpServletRequestBuilder query) throws Exception {
    return mvc.perform(query.with(actor(f.actor())))
        .andExpect(status().isOk())
        .andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(
            header()
                .stringValues(
                    "Vary",
                    org.hamcrest.Matchers.hasItem(
                        org.hamcrest.Matchers.containsString("Authorization"))));
  }

  private ResultActions cancel(String version) throws Exception {
    var query = post(path() + "/cancel").with(actor(f.actor()));
    if (version != null) query.header("If-Match", version);
    return mvc.perform(query);
  }

  private JsonNode body(ResultActions result) throws Exception {
    return json.readTree(result.andReturn().getResponse().getContentAsString());
  }

  private Set<String> fields(JsonNode node) {
    var names = new HashSet<String>();
    node.fieldNames().forEachRemaining(names::add);
    return names;
  }

  private void role(String role) {
    db.update("UPDATE tenant_members SET role=? WHERE tenant_id=?", role, f.tenant());
  }

  private long revision() {
    return db.queryForObject(
        "SELECT revision FROM managed_policy_preparation_requests WHERE tenant_id=? AND id=?",
        Long.class,
        f.tenant(),
        request);
  }
}

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
      "spring.datasource.url=jdbc:h2:mem:execution-recheck;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "springdoc.api-docs.enabled=true",
      "manager.emm.execution.manual-review.enabled=true",
      "manager.emm.execution.device-recovery.enabled=true"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ManagedExecutionRecheckJourneyTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired DataSource source;
  @Autowired JdbcTemplate db;
  @Autowired ManagedPolicyExecutionJournal journal;
  @Autowired ManagedAndroidGateway gateway;
  @MockitoBean JwtDecoder decoder;
  @MockitoBean ManagedExecutionRecoveryJob recoveryJob;
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
    when(gateway.available()).thenReturn(true);
    when(gateway.providerCode()).thenReturn("LOCAL_TEST");
    clearInvocations(gateway);
  }

  @AfterEach
  void removeOwnedTasks() {
    // claimDue is provider-wide. Remove only this case's tasks so subsequent cases never lease
    // them.
    if (f != null)
      db.update("DELETE FROM managed_policy_execution_tasks WHERE tenant_id=?", f.tenant());
  }

  @ParameterizedTest
  @ValueSource(strings = {"OWNER", "ORG_ADMIN"})
  void administratorQueuesOnlyAReadAndRetainsOriginalDeadline(String memberRole) throws Exception {
    review();
    role(memberRole);
    long before = revision(), expiry = number("expires_at");
    long eventCount = events();
    request(before)
        .andExpect(status().isOk())
        .andExpect(header().string("Cache-Control", "no-store"))
        .andExpect(header().string("ETag", "\"" + (before + 1) + "\""))
        .andExpect(jsonPath("$.state").value("WAITING_DEVICE"))
        .andExpect(jsonPath("$.reason").value("MANUAL_DEVICE_RECHECK_REQUESTED"))
        .andExpect(jsonPath("$.cancellationRequested").value(false));
    assertThat(number("expires_at")).isEqualTo(expiry);
    assertThat(number("attempts")).isZero();
    assertThat(events()).isEqualTo(eventCount + 1);
    assertThat(slot()).isEqualTo(f.device());
    assertThat(journal.claimWriteActions("LOCAL_TEST", 1)).isEmpty();
    var next = journal.claimDeviceObservations("LOCAL_TEST", 1).get(0);
    assertThat(next.action()).isEqualTo(ManagedPolicyExecutionJournal.Action.READ_DEVICE);
    assertThat(next.policyVersion()).isEqualTo(7L);
    assertThat(next.leaseUntil()).isLessThanOrEqualTo(expiry);
    assertThat(
            db.queryForObject(
                "SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND resource_id=?"
                    + " AND actor_id=? AND action='MANAGED_EXECUTION_DEVICE_RECHECK_REQUESTED'",
                Long.class,
                f.tenant(),
                task.id(),
                f.actor()))
        .isEqualTo(1);
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    verify(gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
  }

  @Test
  void sameConsentCannotResetTheReadBudgetTwice() throws Exception {
    review();
    long before = revision();
    request(before).andExpect(status().isOk());
    request(before).andExpect(status().isPreconditionFailed());
    assertThat(revision()).isEqualTo(before + 1);
    request(revision()).andExpect(status().isConflict());
    assertThat(revision()).isEqualTo(before + 1);
  }

  @ParameterizedTest
  @ValueSource(strings = {"AUDITOR", "TEACHER", "CHILD", "GUARDIAN"})
  void nonAdministratorsCannotRecheck(String memberRole) throws Exception {
    review();
    role(memberRole);
    long before = revision();
    request(before).andExpect(status().isForbidden());
    unchanged(before);
  }

  @Test
  void revokedAdministratorCannotRecheck() throws Exception {
    review();
    long before = revision();
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    request(before).andExpect(status().isForbidden());
    unchanged(before);
  }

  @ParameterizedTest
  @ValueSource(strings = {"missing", "old", "future", "password-only"})
  void freshMultifactorAuthenticationIsRequired(String kind) throws Exception {
    review();
    long before = revision();
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
    mvc.perform(
            post(path() + "/recheck-device")
                .with(authentication)
                .header("If-Match", "\"" + before + "\""))
        .andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    unchanged(before);
  }

  @ParameterizedTest
  @NullSource
  @ValueSource(strings = {"*", "W/\"1\"", "\"1\",\"2\"", "bad"})
  void oneStrongVersionIsRequired(String tag) throws Exception {
    review();
    long before = revision();
    var req = post(path() + "/recheck-device").with(actor(f.actor()));
    if (tag != null) req.header("If-Match", tag);
    mvc.perform(req).andExpect(status().is(tag == null ? 428 : 400));
    unchanged(before);
  }

  @Test
  void anotherTenantCannotRecheck() throws Exception {
    review();
    long before = revision();
    var other = data.fixture();
    mvc.perform(
            post(path() + "/recheck-device")
                .with(actor(other.actor()))
                .header("If-Match", "\"" + before + "\""))
        .andExpect(status().isForbidden());
    unchanged(before);
  }

  @Test
  void missingTaskCannotBeRechecked() throws Exception {
    mvc.perform(
            post(root() + "/" + ManagedExecutionTestData.id() + "/recheck-device")
                .with(actor(f.actor()))
                .header("If-Match", "\"1\""))
        .andExpect(status().isForbidden());
  }

  @Test
  void cancellationCannotBeUndoneByAReadRequest() throws Exception {
    review();
    journal.cancel(f.tenant(), f.actor(), task.id(), revision());
    long before = revision();
    request(before)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_RECHECK_CANCELLED"));
    unchanged(before);
    assertThat(number("cancel_requested")).isEqualTo(1);
  }

  @Test
  void expiryIsNeverExtendedByManualReview() throws Exception {
    review();
    db.update(
        "UPDATE managed_policy_execution_tasks SET created_at=1,expires_at=2 WHERE id=?",
        task.id());
    long before = revision();
    request(before)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_RECHECK_WINDOW_CLOSED"));
    unchanged(before);
    assertThat(number("expires_at")).isEqualTo(2);
  }

  @Test
  void unknownPolicyWriteCannotBecomeAnAssignment() throws Exception {
    var claim = claim();
    journal.beforeWrite(journal.writePreparationTarget(claim), claim.leaseUntil());
    db.update("UPDATE managed_policy_execution_tasks SET attempts=24 WHERE id=?", task.id());
    journal.failed(claim);
    long before = revision();
    request(before)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_RECHECK_REQUIRES_POLICY_RECEIPT"));
    unchanged(before);
    assertThat(journal.claimWriteActions("LOCAL_TEST", 1)).isEmpty();
  }

  @Test
  void runningTaskCannotBeRequeued() throws Exception {
    long before = revision();
    request(before)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_RECHECK_REQUIRES_REVIEW"));
    assertThat(revision()).isEqualTo(before);
  }

  @Test
  void unavailableProviderDoesNotConsumeConsent() throws Exception {
    review();
    when(gateway.available()).thenReturn(false);
    long before = revision();
    request(before)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_RECHECK_UNAVAILABLE"));
    unchanged(before);
  }

  @Test
  void changedBindingCannotBeReobserved() throws Exception {
    review();
    long before = revision();
    when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
        .thenThrow(com.aimanager.shared.DomainException.denied());
    request(before).andExpect(status().isForbidden());
    unchanged(before);
  }

  @Test
  void changedPublicationCannotReuseAnOldPolicyReceipt() throws Exception {
    review();
    long before = revision();
    when(publications.requireTarget(
            f.tenant(), f.actor(), f.publication(), f.device(), f.registration()))
        .thenReturn(
            new ManagedExecutionPublicationAccess.Publication(
                ManagedExecutionTestData.id(), "c".repeat(64), 1));
    request(before)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_CONTEXT_CHANGED"));
    unchanged(before);
  }

  @Test
  void providerMismatchCannotQueueARead() throws Exception {
    review();
    when(gateway.providerCode()).thenReturn("OTHER_TEST");
    long before = revision();
    request(before).andExpect(status().isConflict());
    unchanged(before);
  }

  @Test
  void liveLeaseIsNotTakenOver() throws Exception {
    review();
    db.update(
        "UPDATE managed_policy_execution_tasks SET"
            + " lease_token='local-review-lease',action='READ_DEVICE',lease_until=? WHERE id=?",
        System.currentTimeMillis() + 60000,
        task.id());
    long before = revision();
    request(before)
        .andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("EXECUTION_RECHECK_LEASE_ACTIVE"));
    unchanged(before);
  }

  @Test
  void unauthenticatedCallerIsRejectedBeforeRouting() throws Exception {
    mvc.perform(post(path() + "/recheck-device").header("If-Match", "\"1\""))
        .andExpect(status().isUnauthorized());
    assertThat(revision()).isEqualTo(1);
  }

  @ParameterizedTest
  @ValueSource(longs = {7, 8})
  void onlyExactIndependentDeviceEvidenceCanFinishTheRecheck(long observedVersion)
      throws Exception {
    review();
    request(revision()).andExpect(status().isOk());
    var next = journal.claimDeviceObservations("LOCAL_TEST", 1).get(0);
    String policy = "enterprises/" + next.enterpriseId() + "/policies/" + next.policyId();
    assertThat(
            journal.deviceObserved(
                next,
                new ManagedAndroidGateway.ManagedDeviceState(
                    "enterprises/" + next.enterpriseId() + "/devices/" + next.deviceId(),
                    "DEVICE_OWNER",
                    policy,
                    policy,
                    observedVersion,
                    ManagedAndroidGateway.ApplyState.APPLIED,
                    List.of(),
                    null)))
        .isTrue();
    assertThat(journal.get(f.tenant(), f.actor(), task.id()).state())
        .isEqualTo(
            observedVersion == 7
                ? ManagedPolicyExecutionJournal.State.APPLIED
                : ManagedPolicyExecutionJournal.State.WAITING_DEVICE);
    if (observedVersion == 7) assertThat(slot()).isNull();
    else assertThat(slot()).isEqualTo(f.device());
  }

  private void review() {
    var write = claim();
    assertThat(journal.beforeWrite(journal.writePreparationTarget(write), write.leaseUntil()))
        .isTrue();
    assertThat(
            journal.policyWritten(
                write,
                new ManagedAndroidGateway.PolicyReceipt(
                    "enterprises/" + write.enterpriseId() + "/policies/" + write.policyId(), 7L)))
        .isTrue();
    var assign = claim();
    assertThat(journal.beforeWrite(journal.writePreparationTarget(assign), assign.leaseUntil()))
        .isTrue();
    db.update("UPDATE managed_policy_execution_tasks SET attempts=24 WHERE id=?", task.id());
    assertThat(journal.failed(assign)).isTrue();
    assertThat(journal.get(f.tenant(), f.actor(), task.id()).state())
        .isEqualTo(ManagedPolicyExecutionJournal.State.NEEDS_REVIEW);
    clearInvocations(gateway);
  }

  private org.springframework.test.web.servlet.ResultActions request(long revision)
      throws Exception {
    return mvc.perform(
        post(path() + "/recheck-device")
            .with(actor(f.actor()))
            .header("If-Match", "\"" + revision + "\""));
  }

  private long number(String column) {
    return db.queryForObject(
        "SELECT " + column + " FROM managed_policy_execution_tasks WHERE id=?",
        Long.class,
        task.id());
  }

  private String slot() {
    return db.queryForObject(
        "SELECT active_device_id FROM managed_policy_execution_tasks WHERE id=?",
        String.class,
        task.id());
  }

  private void unchanged(long before) {
    assertThat(revision()).isEqualTo(before);
    assertThat(slot()).isEqualTo(f.device());
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
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

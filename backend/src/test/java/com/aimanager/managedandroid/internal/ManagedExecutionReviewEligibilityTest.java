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
      "spring.datasource.url=jdbc:h2:mem:execution-review-eligibility;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
      "spring.datasource.username=sa",
      "spring.datasource.password=",
      "springdoc.api-docs.enabled=true",
      "manager.emm.execution.manual-review.enabled=true",
      "manager.emm.execution.device-recovery.enabled=true"
    })
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class ManagedExecutionReviewEligibilityTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper json;
  @Autowired DataSource source;
  @Autowired JdbcTemplate db;
  @Autowired ManagedPolicyExecutionJournal journal;
  @Autowired com.aimanager.subject.SubjectAccess subjects;
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

  @Test
  void eligibleProjectionIsBoundedAndDoesNotRequireFreshAuthentication() throws Exception {
    review();
    var before = row();
    long auditBefore = audits(), eventsBefore = events();
    var response =
        mvc.perform(get(path() + "/review-eligibility").with(jwt().jwt(t -> t.subject(f.actor()))))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(header().doesNotExist("ETag"))
            .andExpect(
                header()
                    .stringValues(
                        "Vary",
                        org.hamcrest.Matchers.hasItem(
                            org.hamcrest.Matchers.containsString("Authorization"))))
            .andExpect(jsonPath("$.allowed").value(true))
            .andExpect(jsonPath("$.reason").value("ELIGIBLE"))
            .andExpect(jsonPath("$.revision").value(revision()))
            .andExpect(jsonPath("$.id").value(task.id()))
            .andExpect(jsonPath("$.publicationId").value(f.publication()))
            .andExpect(jsonPath("$.deviceId").value(f.device()))
            .andExpect(jsonPath("$.registrationId").value(f.registration()))
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertThat(fields(body(response)))
        .containsExactlyInAnyOrder(
            "id", "publicationId", "deviceId", "registrationId", "revision", "allowed", "reason");
    eligibility("ELIGIBLE", true);
    assertThat(row()).isEqualTo(before);
    assertThat(audits()).isEqualTo(auditBefore);
    assertThat(events()).isEqualTo(eventsBefore);
    noRemoteIo();
  }

  @Test
  void auditorCanUnderstandWhyTheActionIsUnavailable() throws Exception {
    review();
    role("AUDITOR");
    var before = row();
    eligibility("ADMINISTRATOR_REQUIRED", false);
    assertThat(row()).isEqualTo(before);
    noRemoteIo();
  }

  @ParameterizedTest
  @ValueSource(strings = {"TEACHER", "CHILD", "GUARDIAN"})
  void otherRolesCannotReadEligibility(String memberRole) throws Exception {
    role(memberRole);
    mvc.perform(get(path() + "/review-eligibility").with(actor(f.actor())))
        .andExpect(status().isForbidden());
    noRemoteIo();
  }

  @Test
  void crossTenantAndMissingTasksAreDenied() throws Exception {
    var other = data.fixture();
    mvc.perform(get(path() + "/review-eligibility").with(actor(other.actor())))
        .andExpect(status().isForbidden());
    mvc.perform(
            get(root() + "/" + ManagedExecutionTestData.id() + "/review-eligibility")
                .with(actor(f.actor())))
        .andExpect(status().isForbidden());
    noRemoteIo();
  }

  @Test
  void revokedAdministratorCannotReadEligibility() throws Exception {
    db.update(
        "UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=?", f.tenant());
    mvc.perform(get(path() + "/review-eligibility").with(actor(f.actor())))
        .andExpect(status().isForbidden());
  }

  @Test
  void runningTaskExplainsItsCurrentState() throws Exception {
    eligibility("EXECUTION_RECHECK_REQUIRES_REVIEW", false);
    assertThat(revision()).isEqualTo(1);
    noRemoteIo();
  }

  @Test
  void cancelledTaskDoesNotBecomeEligible() throws Exception {
    review();
    journal.cancel(f.tenant(), f.actor(), task.id(), revision());
    var before = row();
    eligibility("EXECUTION_RECHECK_CANCELLED", false);
    assertThat(row()).isEqualTo(before);
    noRemoteIo();
  }

  @Test
  void unknownWriteExplainsMissingReceiptWithoutLeakingProviderData() throws Exception {
    var claim = claim();
    journal.beforeWrite(journal.writePreparationTarget(claim), claim.leaseUntil());
    db.update("UPDATE managed_policy_execution_tasks SET attempts=24 WHERE id=?", task.id());
    journal.failed(claim);
    var before = row();
    eligibility("EXECUTION_RECHECK_REQUIRES_POLICY_RECEIPT", false);
    assertThat(row()).isEqualTo(before);
    noRemoteIo();
  }

  @ParameterizedTest
  @ValueSource(longs = {-1000, 1000})
  void expiredOrTooShortWindowsCannotBeExtended(long remaining) throws Exception {
    review();
    db.update(
        "UPDATE managed_policy_execution_tasks SET created_at=1,expires_at=? WHERE id=?",
        System.currentTimeMillis() + remaining,
        task.id());
    var before = row();
    eligibility("EXECUTION_RECHECK_WINDOW_CLOSED", false);
    assertThat(row()).isEqualTo(before);
    noRemoteIo();
  }

  @Test
  void aLiveLeaseIsExplainedWithoutTakingItOver() throws Exception {
    review();
    db.update(
        "UPDATE managed_policy_execution_tasks SET"
            + " lease_token='local-review-lease',action='READ_DEVICE',lease_until=? WHERE id=?",
        System.currentTimeMillis() + 60000,
        task.id());
    var before = row();
    eligibility("EXECUTION_RECHECK_LEASE_ACTIVE", false);
    assertThat(row()).isEqualTo(before);
    noRemoteIo();
  }

  @Test
  void providerAvailabilityMayChangeAtTheSameTaskRevision() throws Exception {
    review();
    long before = revision();
    eligibility("ELIGIBLE", true);
    when(gateway.available()).thenReturn(false);
    eligibility("EXECUTION_RECHECK_UNAVAILABLE", false);
    assertThat(revision()).isEqualTo(before);
    noRemoteIo();
  }

  @Test
  void anotherProviderIsNotAReplacementForTheOriginal() throws Exception {
    review();
    when(gateway.providerCode()).thenReturn("OTHER_TEST");
    eligibility("EXECUTION_RECHECK_UNAVAILABLE", false);
    noRemoteIo();
  }

  @Test
  void aRevokedBindingProducesAStableNonSensitiveReason() throws Exception {
    review();
    when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
        .thenThrow(com.aimanager.shared.DomainException.denied());
    eligibility("EXECUTION_CONTEXT_CHANGED", false);
    noRemoteIo();
  }

  @Test
  void aDifferentFrozenPublicationIsNotEligible() throws Exception {
    review();
    when(publications.requireTarget(
            f.tenant(), f.actor(), f.publication(), f.device(), f.registration()))
        .thenReturn(
            new ManagedExecutionPublicationAccess.Publication(
                ManagedExecutionTestData.id(), "c".repeat(64), 1));
    eligibility("EXECUTION_CONTEXT_CHANGED", false);
    noRemoteIo();
  }

  @ParameterizedTest
  @ValueSource(strings = {"revision", "generation"})
  void exhaustedVersionSpaceCannotQueueMoreWork(String column) throws Exception {
    review();
    db.update(
        "UPDATE managed_policy_execution_tasks SET " + column + "=9007199254740990 WHERE id=?",
        task.id());
    var before = row();
    eligibility("EXECUTION_VERSION_EXHAUSTED", false);
    assertThat(row()).isEqualTo(before);
    noRemoteIo();
  }

  @Test
  void internalFailureIsNotMisrepresentedAsAValidProjection() throws Exception {
    review();
    when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
        .thenThrow(new IllegalStateException("private-provider-resource"));
    var response =
        mvc.perform(get(path() + "/review-eligibility").with(actor(f.actor())))
            .andExpect(status().isInternalServerError())
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertThat(response)
        .doesNotContain("private-provider-resource", f.enterprise(), f.providerDevice());
    noRemoteIo();
  }

  @Test
  void unauthenticatedCallerIsRejectedBeforeRouting() throws Exception {
    mvc.perform(get(path() + "/review-eligibility")).andExpect(status().isUnauthorized());
    noRemoteIo();
  }

  @Test
  void nestedDomainRejectionDoesNotTurnAReadProjectionIntoServerFailure() throws Exception {
    review();
    var before = row();
    long auditBefore = audits(), eventsBefore = events();
    when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
        .thenAnswer(
            invocation -> {
              // Actual REQUIRED/MANDATORY Spring advice marks the shared transaction rollback-only.
              // This is a real domain read rejection, not a manually fabricated JDBC error.
              subjects.lockForDevice(f.tenant(), ManagedExecutionTestData.id());
              throw new AssertionError("Missing subject must be denied");
            });
    eligibility("EXECUTION_CONTEXT_CHANGED", false);
    assertThat(row()).isEqualTo(before);
    assertThat(audits()).isEqualTo(auditBefore);
    assertThat(events()).isEqualTo(eventsBefore);
    noRemoteIo();
  }

  private void eligibility(String reason, boolean allowed) throws Exception {
    var text =
        mvc.perform(get(path() + "/review-eligibility").with(actor(f.actor())))
            .andExpect(status().isOk())
            .andExpect(header().string("Cache-Control", "no-store"))
            .andExpect(header().doesNotExist("ETag"))
            .andExpect(jsonPath("$.allowed").value(allowed))
            .andExpect(jsonPath("$.reason").value(reason))
            .andReturn()
            .getResponse()
            .getContentAsString();
    assertThat(fields(body(text)))
        .containsExactlyInAnyOrder(
            "id", "publicationId", "deviceId", "registrationId", "revision", "allowed", "reason");
    assertThat(text)
        .doesNotContain(
            f.enterprise(), f.providerDevice(), "lease_token", "providerVersion", "documentJson");
  }

  private java.util.Map<String, Object> row() {
    return db.queryForMap(
        "SELECT * FROM managed_policy_execution_tasks WHERE tenant_id=? AND id=?",
        f.tenant(),
        task.id());
  }

  private long audits() {
    return db.queryForObject(
        "SELECT COUNT(*) FROM audit_events WHERE tenant_id=?", Long.class, f.tenant());
  }

  private void noRemoteIo() {
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
    verify(gateway, never()).readDeviceState(anyString(), anyString(), anyString(), anyLong());
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

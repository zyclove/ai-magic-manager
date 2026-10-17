package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.*;
import com.aimanager.policy.PolicySnapshot;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.context.annotation.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.annotation.EnableTransactionManagement;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Real publication SQL and tenant authorization; device binding/provider remain explicit fixtures.
 */
class GooglePolicyPreparationPublicationTest {
  @Configuration(proxyBeanMethods = false)
  @EnableTransactionManagement
  @ComponentScan(
      basePackageClasses = PolicySnapshot.class,
      useDefaultFilters = false,
      includeFilters =
          @ComponentScan.Filter(
              type = FilterType.ASSIGNABLE_TYPE,
              classes = ManagedExecutionPublicationAccess.class))
  static class ReaderConfiguration {}

  @ParameterizedTest
  @ValueSource(booleans = {false, true})
  void realPublicationAndAuthorityAreReloadedAfterProviderReads(boolean revokeDuringRead)
      throws Exception {
    try (var data = new ManagedExecutionTestData()) {
      var f = data.fixture();
      var json = new ObjectMapper();
      var now = Instant.parse("2026-10-16T12:00:00Z");
      var clock = Clock.fixed(now, ZoneOffset.UTC);
      String app = ManagedExecutionTestData.id();
      var snapshot =
          Map.of(
              "schemaVersion",
              1,
              "name",
              "Published",
              "sourceRules",
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
                      app)),
              "applications",
              List.of(
                  Map.of(
                      "id",
                      app,
                      "displayName",
                      "Lesson",
                      "platform",
                      "ANDROID",
                      "packageName",
                      "com.example.lesson",
                      "profile",
                      "PRIMARY",
                      "signingDigests",
                      List.of("a".repeat(64)),
                      "evidenceStatus",
                      "DECLARED")),
              "schedules",
              List.of(),
              "protectedPackageExemptions",
              List.of(),
              "targets",
              List.of(
                  Map.of(
                      "deviceId",
                      f.device(),
                      "registrationId",
                      f.registration(),
                      "platform",
                      "ANDROID",
                      "state",
                      "ACTIVE",
                      "managementMode",
                      "FULLY_MANAGED",
                      "rules",
                      List.of(
                          Map.of(
                              "sourceRuleIds",
                              List.of("launch"),
                              "kind",
                              "APP_LAUNCH",
                              "applicationId",
                              app,
                              "required",
                              true,
                              "predictedEffect",
                              "DENY",
                              "status",
                              "UNVERIFIED",
                              "reasonCode",
                              "APPLICATION_PROFILE_NOT_VERIFIED")))));
      data.db.update(
          "UPDATE policy_versions SET snapshot_json=? WHERE tenant_id=?",
          json.writeValueAsString(snapshot),
          f.tenant());
      var bindings = mock(ManagedAgentBindingStore.class);
      var enrollments = mock(ManagedEnrollmentStore.class);
      var gateway = mock(ManagedAndroidGateway.class);
      var binding =
          new ManagedAgentBindingStore.VerifiedBindingContext(
              f.tenant(),
              f.actor(),
              1,
              f.subject(),
              f.device(),
              f.registration(),
              "a".repeat(43),
              f.binding(),
              2,
              f.enrollment(),
              1,
              "GOOGLE_AMAPI",
              f.enterprise(),
              1,
              f.providerDevice(),
              "DEVICE_OWNER",
              now.minusSeconds(100).toEpochMilli(),
              "com.aimanager.child",
              "trust-v1",
              Device.Platform.ANDROID,
              now.minusSeconds(120).toEpochMilli());
      var intent =
          new ManagedEnrollmentStore.Intent(
              f.tenant(),
              f.enrollment(),
              f.subject(),
              "GOOGLE_AMAPI",
              f.enterprise(),
              1,
              "base",
              1,
              "token",
              SecretMaterial.hash("nonce"),
              f.providerDevice(),
              "DEVICE_OWNER",
              "VERIFIED",
              1,
              f.actor(),
              1,
              now.minusSeconds(190).toEpochMilli(),
              now.plusSeconds(300).toEpochMilli(),
              now.minusSeconds(150).toEpochMilli(),
              1);
      when(bindings.requireVerifiedContext(f.tenant(), f.actor(), f.binding(), 2))
          .thenReturn(binding);
      when(enrollments.forProviderStatus(f.tenant(), f.enrollment(), f.actor())).thenReturn(intent);
      when(gateway.available()).thenReturn(true);
      when(gateway.providerCode()).thenReturn("GOOGLE_AMAPI");
      when(gateway.supportsExecutionProfiles()).thenReturn(true);
      when(gateway.supportsCompletePolicyDocuments()).thenReturn(true);
      String deviceName = "enterprises/" + f.enterprise() + "/devices/" + f.providerDevice();
      var reads = new AtomicInteger();
      when(gateway.readEnrollmentIdentity(f.enterprise(), f.providerDevice()))
          .thenAnswer(
              call -> {
                assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
                if (reads.incrementAndGet() == 2 && revokeDuringRead)
                  data.db.update(
                      "DELETE FROM tenant_members WHERE tenant_id=? AND actor_id=?",
                      f.tenant(),
                      f.actor());
                return new ManagedAndroidGateway.ManagedEnrollmentIdentity(
                    deviceName, "DEVICE_OWNER", now.minusSeconds(180).toString(), "token", "nonce");
              });
      when(gateway.readExecutionProfile(f.enterprise(), f.providerDevice()))
          .thenReturn(
              Optional.of(
                  new ManagedDeviceExecutionProfile(
                      deviceName, "DEVICE_OWNER", 30, "ACTIVE", "ACTIVE", now.toString())));
      new ApplicationContextRunner()
          .withUserConfiguration(ReaderConfiguration.class)
          .withBean(JdbcTemplate.class, () -> data.db)
          .withBean(ObjectMapper.class, () -> json)
          .withBean(TenantAccess.class, () -> new TenantAccess(data.db))
          .withBean(PlatformTransactionManager.class, () -> data.transactions)
          .run(
              context -> {
                assertThat(context).hasNotFailed();
                var service =
                    new ManagedPolicyPreparationService(
                        bindings,
                        enrollments,
                        context.getBean(ManagedExecutionPublicationAccess.class),
                        gateway,
                        new ManagedPolicyDocumentCompilers(
                            List.of(new GoogleManagedPolicyDocumentCompiler())),
                        new ManagedDeviceProfileSettings(clock, 600, 120, 15),
                        clock,
                        data.transactions,
                        "");
                if (revokeDuringRead) {
                  assertThatThrownBy(
                          () ->
                              service.prepare(
                                  f.tenant(), f.actor(), f.publication(), f.binding(), 2))
                      .isInstanceOf(DomainException.class);
                } else {
                  var prepared =
                      service.prepare(f.tenant(), f.actor(), f.publication(), f.binding(), 2);
                  assertThat(prepared.desired().publication().versionId()).isEqualTo(f.version());
                  assertThat(prepared.desired().rules())
                      .singleElement()
                      .satisfies(rule -> assertThat(rule.status()).isEqualTo("UNVERIFIED"));
                  assertThat(
                          GooglePolicyPreparationServiceTest.googlePolicy(prepared.document())
                              .getApplications())
                      .anySatisfy(
                          a -> {
                            assertThat(a.getPackageName()).isEqualTo("com.example.lesson");
                            assertThat(a.getDisabled()).isTrue();
                          });
                }
                assertThat(reads.get()).isEqualTo(2);
                verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
                verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
              });
    }
  }
}

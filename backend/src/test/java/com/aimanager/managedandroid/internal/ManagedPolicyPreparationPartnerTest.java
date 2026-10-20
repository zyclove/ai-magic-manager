package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.fleet.Device;
import com.aimanager.managedandroid.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import java.time.*;
import java.util.*;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

class ManagedPolicyPreparationPartnerTest {
  final ManagedProviderCalls calls =
      new ManagedProviderCalls(1, java.time.Duration.ofSeconds(20), System::nanoTime);

  int compilations;
  final Instant now = Instant.parse("2026-10-16T12:00:00Z");
  final Clock clock = Clock.fixed(now, ZoneOffset.UTC);
  final ManagedAgentBindingStore bindings = mock(ManagedAgentBindingStore.class);
  final ManagedEnrollmentStore enrollments = mock(ManagedEnrollmentStore.class);
  final ManagedExecutionPublicationAccess publications =
      mock(ManagedExecutionPublicationAccess.class);
  final ManagedAndroidGateway gateway = mock(ManagedAndroidGateway.class);
  final List<String> steps = new ArrayList<>();
  final DataSourceTransactionManager transactions =
      new DataSourceTransactionManager(
          new DriverManagerDataSource("jdbc:h2:mem:preparation-" + UUID.randomUUID(), "sa", ""));
  final ManagedAgentBindingStore.VerifiedBindingContext binding = binding(1);
  final ManagedEnrollmentStore.Intent intent =
      new ManagedEnrollmentStore.Intent(
          "tenant",
          "enrollment",
          "subject",
          "LOCAL_PARTNER",
          "e1",
          1,
          "base",
          1,
          "enterprises/e1/enrollmentTokens/t1",
          SecretMaterial.hash("nonce"),
          "d1",
          "DEVICE_OWNER",
          "VERIFIED",
          1,
          "actor",
          now.minusSeconds(200).toEpochMilli(),
          now.minusSeconds(190).toEpochMilli(),
          now.plusSeconds(300).toEpochMilli(),
          now.minusSeconds(150).toEpochMilli(),
          now.toEpochMilli());
  final ManagedDesiredPolicy desired = desired("v1");
  ManagedPolicyPreparationService service;

  @BeforeEach
  void setup() {
    when(gateway.providerCode()).thenReturn("LOCAL_PARTNER");
    when(gateway.available()).thenReturn(true);
    when(gateway.supportsExecutionProfiles()).thenReturn(true);
    when(gateway.supportsCompletePolicyDocuments()).thenReturn(true);
    when(bindings.requireVerifiedContext("tenant", "actor", "binding", 1))
        .thenAnswer(
            call -> {
              insideTransaction();
              steps.add("binding");
              return binding;
            });
    when(enrollments.forProviderStatus("tenant", "enrollment", "actor"))
        .thenAnswer(
            call -> {
              insideTransaction();
              steps.add("enrollment");
              return intent;
            });
    when(publications.requireDesiredTarget(
            "tenant", "actor", "publication", "device", "registration"))
        .thenAnswer(
            call -> {
              insideTransaction();
              steps.add("publication");
              return desired;
            });
    when(gateway.readEnrollmentIdentity("e1", "d1"))
        .thenAnswer(
            call -> {
              outsideTransaction();
              steps.add("identity");
              return identity("nonce");
            });
    when(gateway.readExecutionProfile("e1", "d1"))
        .thenAnswer(
            call -> {
              outsideTransaction();
              steps.add("profile");
              return Optional.of(
                  new ManagedDeviceExecutionProfile(
                      "enterprises/e1/devices/d1",
                      "DEVICE_OWNER",
                      30,
                      "ACTIVE",
                      "ACTIVE",
                      now.minusSeconds(10).toString()));
            });
    service =
        new ManagedPolicyPreparationService(
            bindings,
            enrollments,
            publications,
            gateway,
            new ManagedPolicyDocumentCompilers(List.of(new LocalCompiler())),
            new ManagedDeviceProfileSettings(clock, 600, 120, 15),
            ManagedPreparationTestQualifications.allow(),
            clock,
            transactions,
            "com.example.safe",
            calls);
  }

  @Test
  void partnerUsesTheSharedPreparationFlowAndItsOwnDocumentFormat() {
    var prepared = prepare();
    assertThat(prepared.binding().provider()).isEqualTo("LOCAL_PARTNER");
    assertThat(prepared.document().documentJson())
        .contains("local-partner-v1", "partnerRules", "com.example.lesson", "com.example.safe");
    assertThat(prepared.document().sha256())
        .isEqualTo(SecretMaterial.hash(prepared.document().documentJson()));
    assertThat(compilations).isEqualTo(1);
    assertThat(steps)
        .containsExactly(
            "binding",
            "enrollment",
            "publication",
            "identity",
            "profile",
            "identity",
            "binding",
            "enrollment",
            "publication");
  }

  @Test
  void missingPartnerCompilerFailsBeforeAnyProviderRead() {
    service =
        new ManagedPolicyPreparationService(
            bindings,
            enrollments,
            publications,
            gateway,
            new ManagedPolicyDocumentCompilers(List.of(new GoogleManagedPolicyDocumentCompiler())),
            new ManagedDeviceProfileSettings(clock, 600, 120, 15),
            ManagedPreparationTestQualifications.allow(),
            clock,
            transactions,
            "",
            calls);
    assertThatThrownBy(this::prepare)
        .isInstanceOfSatisfying(
            DomainException.class,
            e -> assertThat(e.errorCode()).isEqualTo("MANAGED_PREPARATION_CONNECTOR_UNAVAILABLE"));
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
    verify(gateway, never()).readExecutionProfile(anyString(), anyString());
    assertThat(compilations).isZero();
  }

  @Test
  void currentBindingAuthorityMustRemainUnchangedForThePartner() {
    int[] reads = {0};
    doAnswer(
            call -> {
              insideTransaction();
              return reads[0]++ == 0 ? binding : binding(2);
            })
        .when(bindings)
        .requireVerifiedContext("tenant", "actor", "binding", 1);
    assertThatThrownBy(this::prepare)
        .isInstanceOfSatisfying(
            DomainException.class,
            e -> assertThat(e.errorCode()).isEqualTo("MANAGED_PREPARATION_CONTEXT_CHANGED"));
    assertThat(compilations).isZero();
  }

  @Test
  void changedEnrollmentIdentityCannotReachPartnerCompilation() {
    when(gateway.readEnrollmentIdentity("e1", "d1"))
        .thenReturn(identity("nonce"), identity("other-nonce"));
    assertThatThrownBy(this::prepare).isInstanceOf(DomainException.class);
    assertThat(compilations).isZero();
  }

  @Test
  void partnerCannotBypassTheSupportedDeviceProfileBoundary() {
    when(gateway.readExecutionProfile("e1", "d1"))
        .thenReturn(
            Optional.of(
                new ManagedDeviceExecutionProfile(
                    "enterprises/e1/devices/d1",
                    "DEVICE_OWNER",
                    29,
                    "ACTIVE",
                    "ACTIVE",
                    now.minusSeconds(10).toString())));
    assertThatThrownBy(this::prepare)
        .isInstanceOfSatisfying(
            DomainException.class,
            e -> assertThat(e.errorCode()).isEqualTo("MANAGED_DEVICE_PROFILE_API_UNSUPPORTED"));
    assertThat(compilations).isZero();
  }

  @Test
  void outerTransactionIsRejectedBeforePartnerReads() {
    assertThatThrownBy(() -> new TransactionTemplate(transactions).execute(s -> prepare()))
        .isInstanceOf(IllegalStateException.class);
    verify(gateway, never()).readEnrollmentIdentity(anyString(), anyString());
    assertThat(compilations).isZero();
  }

  @Test
  void providerSwapDuringReadDoesNotUseThePreviouslyChosenCompiler() {
    when(gateway.readExecutionProfile("e1", "d1"))
        .thenAnswer(
            call -> {
              when(gateway.providerCode()).thenReturn("OTHER_PARTNER");
              return Optional.of(
                  new ManagedDeviceExecutionProfile(
                      "enterprises/e1/devices/d1",
                      "DEVICE_OWNER",
                      30,
                      "ACTIVE",
                      "ACTIVE",
                      now.minusSeconds(10).toString()));
            });
    assertThatThrownBy(this::prepare).isInstanceOf(DomainException.class);
    assertThat(compilations).isZero();
  }

  @AfterEach
  void preparationNeverWritesToTheProvider() {
    calls.close();
    verify(gateway, never()).writePolicyCandidate(anyString(), anyString(), any());
    verify(gateway, never()).assignPolicy(anyString(), anyString(), anyString());
  }

  /** Test-only example format; deliberately contains no Google SDK policy object. */
  final class LocalCompiler implements ManagedPolicyDocumentCompiler {
    public String providerCode() {
      return "LOCAL_PARTNER";
    }

    public String adapterRevision() {
      return "local-partner-v1";
    }

    public ManagedAndroidGateway.PolicyDocument compile(
        ManagedDesiredPolicy desired,
        String agent,
        ManagedDeviceExecutionVerifier.Verified profile,
        Set<String> protections) {
      insideTransaction();
      compilations++;
      var rules =
          desired.applications().stream()
              .map(
                  app ->
                      Map.of(
                          "package",
                          app.packageName(),
                          "control",
                          app.control().name(),
                          "permissions",
                          app.permissions(),
                          "sourceRuleIds",
                          app.sourceRuleIds()))
              .toList();
      try {
        var json =
            new com.fasterxml.jackson.databind.ObjectMapper()
                .enable(
                    com.fasterxml.jackson.databind.SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS);
        String raw =
            json.writeValueAsString(
                Map.of(
                    "schemaVersion",
                    1,
                    "adapterRevision",
                    adapterRevision(),
                    "policy",
                    Map.of(
                        "partnerRules", rules, "protectedPackages", new TreeSet<>(protections))));
        String document = json.writeValueAsString(json.readValue(raw, Map.class));
        return new ManagedAndroidGateway.PolicyDocument(
            document,
            SecretMaterial.hash(document),
            agent,
            profile.apiLevel(),
            profile.managementMode());
      } catch (java.io.IOException invalid) {
        throw new IllegalArgumentException();
      }
    }
  }

  ManagedPolicyPreparationService.Prepared prepare() {
    return service.prepare("tenant", "actor", "publication", "binding", 1);
  }

  ManagedAgentBindingStore.VerifiedBindingContext binding(long authority) {
    return new ManagedAgentBindingStore.VerifiedBindingContext(
        "tenant",
        "actor",
        authority,
        "subject",
        "device",
        "registration",
        "a".repeat(43),
        "binding",
        1,
        "enrollment",
        1,
        "LOCAL_PARTNER",
        "e1",
        1,
        "d1",
        "DEVICE_OWNER",
        now.minusSeconds(100).toEpochMilli(),
        "com.aimanager.child",
        "trust-v1",
        Device.Platform.ANDROID,
        now.minusSeconds(120).toEpochMilli());
  }

  ManagedDesiredPolicy desired(String version) {
    return new ManagedDesiredPolicy(
        new ManagedExecutionPublicationAccess.Publication(version, "hash", now.toEpochMilli()),
        "device",
        "registration",
        List.of(
            new ManagedDesiredPolicy.ApplicationIntent(
                "app",
                "com.example.lesson",
                "PRIMARY",
                List.of("a".repeat(64)),
                ManagedAndroidGateway.AppControl.BLOCK_LAUNCH,
                List.of(
                    new ManagedAndroidGateway.RuntimePermissionDecision(
                        "android.permission.CAMERA",
                        ManagedAndroidGateway.PermissionDecision.DENY)),
                List.of("launch", "camera"),
                ManagedPreparationTestQualifications.launchAndCamera())),
        List.of(),
        List.of());
  }

  ManagedAndroidGateway.ManagedEnrollmentIdentity identity(String nonce) {
    return new ManagedAndroidGateway.ManagedEnrollmentIdentity(
        "enterprises/e1/devices/d1",
        "DEVICE_OWNER",
        now.minusSeconds(180).toString(),
        "enterprises/e1/enrollmentTokens/t1",
        nonce);
  }

  void insideTransaction() {
    assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isTrue();
    assertThat(TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())
        .isEqualTo(TransactionDefinition.ISOLATION_READ_COMMITTED);
  }

  void outsideTransaction() {
    assertThat(TransactionSynchronizationManager.isActualTransactionActive()).isFalse();
  }
}

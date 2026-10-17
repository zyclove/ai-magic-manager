package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.aimanager.managedandroid.ManagedAndroidGateway.PolicyDocument;
import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.managedandroid.ManagedDeviceExecutionVerifier;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.managedandroid.ManagedPolicyDocumentCompiler;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import java.time.Instant;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

/** Provider-neutral document selection, without cloud credentials or a running device. */
class ManagedPolicyDocumentCompilersTest {
  static final String DOCUMENT =
      "{\"adapterRevision\":\"local-partner-v1\",\"policy\":{\"example\":true},\"schemaVersion\":1}";
  final ManagedDeviceExecutionVerifier.Verified profile =
      new ManagedDeviceExecutionVerifier.Verified(
          "enterprises/e1/devices/d1",
          "DEVICE_OWNER",
          30,
          Instant.EPOCH,
          Instant.EPOCH,
          Instant.EPOCH.plusSeconds(120));
  final ManagedDesiredPolicy desired =
      new ManagedDesiredPolicy(
          new ManagedExecutionPublicationAccess.Publication("v1", "a".repeat(64), 1),
          "device",
          "registration",
          List.of(),
          List.of(),
          List.of());

  @Test
  void registeredPartnerCompilesThroughTheSameDocumentBoundary() {
    var compiler = compiler();
    var registry = new ManagedPolicyDocumentCompilers(List.of(compiler));
    var result = compile(registry);
    assertThat(result.documentJson()).isEqualTo(DOCUMENT);
    assertThat(result.sha256()).isEqualTo(SecretMaterial.hash(DOCUMENT));
    verify(compiler).compile(eq(desired), eq("com.aimanager.child"), eq(profile), eq(Set.of()));
  }

  @Test
  void duplicateProviderCannotSilentlyReplaceTheRegisteredCompiler() {
    assertThatThrownBy(() -> new ManagedPolicyDocumentCompilers(List.of(compiler(), compiler())))
        .isInstanceOf(IllegalArgumentException.class)
        .hasNoCause();
  }

  @Test
  void absentCompilerIsUnavailableAndCannotFallBackToGoogle() {
    var google = new GoogleManagedPolicyDocumentCompiler();
    var registry = new ManagedPolicyDocumentCompilers(List.of(google));
    assertThat(registry.supports("LOCAL_PARTNER")).isFalse();
    assertThat(registry.supports(null)).isFalse();
    assertThatThrownBy(() -> compile(registry))
        .isInstanceOfSatisfying(
            DomainException.class,
            e -> assertThat(e.errorCode()).isEqualTo("MANAGED_PREPARATION_COMPILER_UNAVAILABLE"));
  }

  @ParameterizedTest
  @ValueSource(
      strings = {"", "aa", "lower_case", "GOOGLE AMAPI", "A1234567890123456789012345678901234"})
  void malformedProviderRegistrationFails(String provider) {
    var compiler = compiler();
    when(compiler.providerCode()).thenReturn(provider);
    assertThatThrownBy(() -> new ManagedPolicyDocumentCompilers(List.of(compiler)))
        .isInstanceOf(IllegalArgumentException.class)
        .hasNoCause();
  }

  @ParameterizedTest
  @ValueSource(strings = {"", "with space", "with/slash"})
  void malformedRevisionRegistrationFails(String revision) {
    var compiler = compiler();
    when(compiler.adapterRevision()).thenReturn(revision);
    assertThatThrownBy(() -> new ManagedPolicyDocumentCompilers(List.of(compiler)))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void registrationCopiesTheProvidedList() {
    var values = new java.util.ArrayList<ManagedPolicyDocumentCompiler>();
    values.add(compiler());
    var registry = new ManagedPolicyDocumentCompilers(values);
    values.clear();
    assertThat(compile(registry).documentJson()).isEqualTo(DOCUMENT);
  }

  @ParameterizedTest
  @ValueSource(strings = {"hash", "agent", "api", "mode", "null"})
  void outputMustMatchTheExactVerifiedContext(String mismatch) {
    var compiler = compiler();
    var document =
        switch (mismatch) {
          case "hash" ->
              new PolicyDocument(
                  DOCUMENT, "0".repeat(64), "com.aimanager.child", 30, "DEVICE_OWNER");
          case "agent" ->
              new PolicyDocument(
                  DOCUMENT, SecretMaterial.hash(DOCUMENT), "com.other.agent", 30, "DEVICE_OWNER");
          case "api" ->
              new PolicyDocument(
                  DOCUMENT,
                  SecretMaterial.hash(DOCUMENT),
                  "com.aimanager.child",
                  31,
                  "DEVICE_OWNER");
          case "mode" ->
              new PolicyDocument(
                  DOCUMENT,
                  SecretMaterial.hash(DOCUMENT),
                  "com.aimanager.child",
                  30,
                  "PROFILE_OWNER");
          default -> null;
        };
    when(compiler.compile(any(), anyString(), any(), anySet())).thenReturn(document);
    rejects(compiler);
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "null",
        "[]",
        "{}",
        "{\"adapterRevision\":\"other-v1\",\"policy\":{},\"schemaVersion\":1}",
        "{\"adapterRevision\":\"local-partner-v1\",\"policy\":[],\"schemaVersion\":1}",
        "{\"adapterRevision\":\"local-partner-v1\",\"policy\":{},\"schemaVersion\":1.0}",
        "{\"adapterRevision\":\"local-partner-v1\",\"policy\":{},\"schemaVersion\":1,\"schemaVersion\":1}",
        "{\"adapterRevision\":\"local-partner-v1\",\"extra\":true,\"policy\":{},\"schemaVersion\":1}",
        "{\"adapterRevision\":\"local-partner-v1\",\"policy\":{},\"schemaVersion\":1} {}",
        "{\"schemaVersion\":1,\"adapterRevision\":\"local-partner-v1\",\"policy\":{}}"
      })
  void rejectsMalformedOrNonCanonicalEnvelopes(String document) {
    var compiler = compiler();
    when(compiler.compile(any(), anyString(), any(), anySet())).thenReturn(document(document));
    rejects(compiler);
  }

  @Test
  void utf8ByteLimitIsEnforcedBeforeParsing() {
    var compiler = compiler();
    String document =
        "{\"adapterRevision\":\"local-partner-v1\",\"policy\":{\"text\":\""
            + "界".repeat(25000)
            + "\"},\"schemaVersion\":1}";
    assertThat(document.length()).isLessThan(65536);
    when(compiler.compile(any(), anyString(), any(), anySet())).thenReturn(document(document));
    rejects(compiler);
  }

  @Test
  void mutableMetadataCannotChangeProviderAfterRegistration() {
    var compiler = compiler();
    var registry = new ManagedPolicyDocumentCompilers(List.of(compiler));
    when(compiler.providerCode()).thenReturn("OTHER_PROVIDER");
    assertThatThrownBy(() -> compile(registry)).isInstanceOf(IllegalArgumentException.class);
    verify(compiler, never()).compile(any(), anyString(), any(), anySet());
  }

  @Test
  void mutableMetadataCannotChangeRevisionDuringCompilation() {
    var compiler = compiler();
    when(compiler.compile(any(), anyString(), any(), anySet()))
        .thenAnswer(
            call -> {
              when(compiler.adapterRevision()).thenReturn("changed-v2");
              return document(DOCUMENT);
            });
    rejects(compiler);
  }

  @Test
  void protectedPackagesCannotBeMutatedByTheCompiler() {
    var compiler = compiler();
    when(compiler.compile(any(), anyString(), any(), anySet()))
        .thenAnswer(
            call -> {
              Set<String> protections = call.getArgument(3);
              assertThatThrownBy(() -> protections.add("com.example.extra"))
                  .isInstanceOf(UnsupportedOperationException.class);
              return document(DOCUMENT);
            });
    assertThat(compile(new ManagedPolicyDocumentCompilers(List.of(compiler)))).isNotNull();
  }

  @Test
  void pluginExceptionBodyAndCauseAreNotPropagated() {
    var compiler = compiler();
    when(compiler.compile(any(), anyString(), any(), anySet()))
        .thenThrow(new IllegalStateException("secret-provider-body"));
    rejects(compiler);
  }

  @Test
  void springRegistersGoogleFormatWithoutEnablingAnyGateway() {
    new org.springframework.boot.test.context.runner.ApplicationContextRunner()
        .withUserConfiguration(
            ManagedPolicyDocumentCompilers.class, GoogleManagedPolicyDocumentCompiler.class)
        .run(
            context -> {
              assertThat(context).hasNotFailed();
              assertThat(
                      context
                          .getBean(ManagedPolicyDocumentCompilers.class)
                          .supports("GOOGLE_AMAPI"))
                  .isTrue();
              assertThat(context)
                  .doesNotHaveBean(com.aimanager.managedandroid.ManagedAndroidGateway.class);
            });
  }

  ManagedPolicyDocumentCompiler compiler() {
    var compiler = mock(ManagedPolicyDocumentCompiler.class);
    when(compiler.providerCode()).thenReturn("LOCAL_PARTNER");
    when(compiler.adapterRevision()).thenReturn("local-partner-v1");
    when(compiler.compile(any(), anyString(), any(), anySet())).thenReturn(document(DOCUMENT));
    return compiler;
  }

  PolicyDocument compile(ManagedPolicyDocumentCompilers registry) {
    return registry.compile("LOCAL_PARTNER", "com.aimanager.child", profile, desired, Set.of());
  }

  PolicyDocument document(String json) {
    return new PolicyDocument(
        json, SecretMaterial.hash(json), "com.aimanager.child", 30, "DEVICE_OWNER");
  }

  void rejects(ManagedPolicyDocumentCompiler compiler) {
    var registry = new ManagedPolicyDocumentCompilers(List.of(compiler));
    assertThatThrownBy(() -> compile(registry))
        .isInstanceOf(IllegalArgumentException.class)
        .hasMessage("Invalid managed policy compiler output")
        .hasNoCause();
  }
}

package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

/** 证明当前上下文、完整签名集合和有效期；不以目录状态替代设备事实。 */
class ManagedApplicationIdentityBoundaryTest {
  private static final Instant NOW = Instant.parse("2026-10-16T08:00:00Z");
  private static final String CERT = "ab".repeat(32);
  private static final String OTHER = "ef".repeat(32);
  private final ManagedApplicationIdentityVerifier verifier = verifier(NOW);
  private final ManagedApplicationIdentityVerifier.Context context = context("");

  @ParameterizedTest
  @ValueSource(strings = {"tenant", "device", "registration", "key", "binding", "binding-version",
      "provider", "provider-device", "enterprise-version", "connector", "application", "definition",
      "package", "trust", "mode", "not-before"})
  void changedCurrentContextCannotInheritCapturedEvidence(String field) {
    rejects("MANAGED_APPLICATION_CONTEXT_CHANGED", context, context(field), report(), NOW);
  }

  @ParameterizedTest
  @ValueSource(strings = {"inactive", "empty-trust", "bad-trust", "many-trust", "bad-definition", "future-start"})
  void unusableContextCannotCertifyItself(String field) {
    var invalid = context(field);
    rejects("MANAGED_APPLICATION_CONTEXT_INVALID", invalid, invalid, report(), NOW);
  }

  @Test
  void nullContextAndScopeAreRejectedWithoutDetails() {
    rejects("MANAGED_APPLICATION_CONTEXT_INVALID", null, context, report(), NOW);
    rejects("MANAGED_APPLICATION_CONTEXT_INVALID", context, null, report(), NOW);
    var invalid = new ManagedApplicationIdentityVerifier.Context(null, context.applicationId(),
        context.definitionRevision(), context.packageName(), Set.of(CERT), "DEVICE_OWNER",
        context.evidenceNotBefore(), true);
    rejects("MANAGED_APPLICATION_CONTEXT_INVALID", invalid, invalid, report(), NOW);
  }

  @Test
  void absentReportIsDistinctFromAnUninstalledApplication() {
    rejects("MANAGED_APPLICATION_REPORT_MISSING", context, context, null, NOW);
  }

  @ParameterizedTest
  @ValueSource(strings = {"device", "package", "mode"})
  void reportMustMatchExactProviderResourcePackageAndManagementMode(String field) {
    var raw = report();
    var changed = new ManagedApplicationReport(
        field.equals("device") ? "enterprises/other/devices/d1" : raw.deviceName(),
        field.equals("mode") ? "PROFILE_OWNER" : raw.managementMode(),
        field.equals("package") ? "example.other" : raw.packageName(), raw.applicationState(),
        raw.signingCertificateSha256(), raw.deviceReportedAt());
    rejects("MANAGED_APPLICATION_REPORT_INVALID", context, context, changed, NOW);
  }

  @ParameterizedTest
  @NullAndEmptySource
  @ValueSource(strings = {"REMOVED", "APPLICATION_STATE_UNSPECIFIED", "FUTURE_STATE"})
  void onlyExplicitInstalledStateCanBeVerified(String state) {
    var raw = report();
    rejects("MANAGED_APPLICATION_INSTALLATION_NOT_CONFIRMED", context, context,
        new ManagedApplicationReport(raw.deviceName(), raw.managementMode(), raw.packageName(), state,
            raw.signingCertificateSha256(), raw.deviceReportedAt()), NOW);
  }

  @ParameterizedTest
  @ValueSource(strings = {"empty", "unknown", "mixed", "duplicate", "malformed"})
  void everyReportedSignerMustBeUniqueCanonicalAndTrusted(String change) {
    List<String> digests = switch (change) {
      case "empty" -> List.of();
      case "unknown" -> List.of(OTHER);
      case "mixed" -> List.of(CERT, OTHER);
      case "duplicate" -> List.of(CERT, CERT);
      case "malformed" -> List.of("AB".repeat(32));
      default -> throw new AssertionError(change);
    };
    var raw = report();
    rejects("MANAGED_APPLICATION_SIGNER_UNTRUSTED", context, context,
        new ManagedApplicationReport(raw.deviceName(), raw.managementMode(), raw.packageName(),
            "INSTALLED", digests, raw.deviceReportedAt()), NOW);
  }

  @ParameterizedTest
  @NullAndEmptySource
  @ValueSource(strings = {"not-a-date", "2026-10-16", "2026-10-16T08:00:31Z"})
  void invalidOrExcessivelyFutureReportTimeIsRejected(String time) {
    rejects("MANAGED_APPLICATION_REPORT_INVALID", context, context, reportAt(time), NOW);
  }

  @ParameterizedTest
  @ValueSource(ints = {600, 601, 3600})
  void reportsAtOrBeyondMaximumAgeCannotBeRenewed(int ageSeconds) {
    rejects("MANAGED_APPLICATION_REPORT_STALE", context, context,
        reportAt(NOW.minusSeconds(ageSeconds).toString()), NOW);
  }

  @Test
  void reportPredatingCurrentBindingIsRejectedEvenWithinMaximumAge() {
    var current = context("not-before");
    rejects("MANAGED_APPLICATION_REPORT_STALE", current, current,
        reportAt(NOW.minusSeconds(60).toString()), NOW);
  }

  @Test
  void serverRetrievalTimeCannotBeMissingFutureOrExpired() {
    rejects("MANAGED_APPLICATION_REPORT_INVALID", context, context, report(), null);
    rejects("MANAGED_APPLICATION_REPORT_INVALID", context, context, report(), NOW.plusSeconds(1));
    rejects("MANAGED_APPLICATION_REPORT_STALE", context, context,
        reportAt(NOW.minusSeconds(150).toString()), NOW.minusSeconds(120));
  }

  @Test
  void reportRetrievedBeforeCurrentBindingCannotBecomeCurrentEvidence() {
    var current = context("not-before");
    rejects("MANAGED_APPLICATION_REPORT_STALE", current, current,
        reportAt(NOW.minusSeconds(5).toString()), NOW.minusSeconds(20));
  }

  @Test
  void eightDistinctTrustedSignersAreAcceptedAtTheCatalogLimit() {
    var trust = java.util.stream.IntStream.range(0, 8).mapToObj(index -> String.format("%064x", index))
        .collect(java.util.stream.Collectors.toUnmodifiableSet());
    var current = ManagedApplicationIdentityVerifierTest.context(trust);
    var result = verifier.verify(current, current,
        new ManagedApplicationReport(current.scope().providerDeviceName(), current.managementMode(),
            current.packageName(), "INSTALLED", List.copyOf(trust), NOW.minusSeconds(30).toString()), NOW);
    assertThat(result.signingCertificates()).containsExactlyInAnyOrderElementsOf(trust);
  }

  @Test
  void futureReportMustAlsoStayWithinSkewOfRetrievalTime() {
    rejects("MANAGED_APPLICATION_REPORT_INVALID", context, context,
        reportAt(NOW.plusSeconds(1).toString()), NOW.minusSeconds(30));
  }

  @Test
  void reportAgeBoundsExpiryEvenWhenTheSameReportIsRefetched() {
    var raw = reportAt(NOW.minusSeconds(550).toString());
    var first = verifier.verify(context, context, raw, NOW);
    var second = verifier(NOW.plusSeconds(20)).verify(context, context, raw, NOW.plusSeconds(20));
    assertThat(first.expiresAt()).isEqualTo(NOW.plusSeconds(50));
    assertThat(second.expiresAt()).isEqualTo(first.expiresAt());
    assertThatThrownBy(() -> verifier(NOW.plusSeconds(50)).verify(context, context, raw, NOW.plusSeconds(50)))
        .isInstanceOf(DomainException.class).hasMessage("MANAGED_APPLICATION_REPORT_STALE");
  }

  @Test
  void maximumAcceptedClockSkewDoesNotExtendRetrievalLifetime() {
    var result = verifier.verify(context, context, reportAt(NOW.plusSeconds(30).toString()), NOW);
    assertThat(result.expiresAt()).isEqualTo(NOW.plusSeconds(120));
  }

  @Test
  void explicitTrustedRotationAndProfileOwnerRemainDistinctFromLocalProfileProof() {
    var current = context("trust");
    var result = verifier.verify(current, current,
        new ManagedApplicationReport(current.scope().providerDeviceName(), current.managementMode(),
            current.packageName(), "INSTALLED", List.of(CERT, OTHER), NOW.minusSeconds(30).toString()), NOW);
    assertThat(result.signingCertificates()).containsExactlyInAnyOrder(CERT, OTHER);
    assertThatThrownBy(() -> result.signingCertificates().clear()).isInstanceOf(UnsupportedOperationException.class);
    var profileOwner = context("mode");
    var profileResult = verifier.verify(profileOwner, profileOwner,
        new ManagedApplicationReport(profileOwner.scope().providerDeviceName(), "PROFILE_OWNER",
            profileOwner.packageName(), "INSTALLED", List.of(CERT), NOW.minusSeconds(30).toString()), NOW);
    assertThat(profileResult.profileScope()).isEqualTo(ManagedApplicationIdentityVerifier.ProfileScope.UNKNOWN);
  }

  @ParameterizedTest
  @ValueSource(strings = {"report-zero", "report-large", "reuse-zero", "reuse-large", "skew-negative", "skew-large"})
  void invalidFreshnessConfigurationFailsAtConstruction(String field) {
    var reportAge = field.equals("report-zero") ? Duration.ZERO
        : field.equals("report-large") ? Duration.ofHours(2) : Duration.ofMinutes(10);
    var reuseAge = field.equals("reuse-zero") ? Duration.ZERO
        : field.equals("reuse-large") ? Duration.ofMinutes(6) : Duration.ofMinutes(2);
    var skew = field.equals("skew-negative") ? Duration.ofSeconds(-1)
        : field.equals("skew-large") ? Duration.ofSeconds(31) : Duration.ofSeconds(30);
    assertThatThrownBy(() -> new ManagedApplicationIdentityVerifier(
        Clock.fixed(NOW, ZoneOffset.UTC), reportAge, reuseAge, skew)).isInstanceOf(IllegalArgumentException.class);
  }

  private void rejects(String code, ManagedApplicationIdentityVerifier.Context captured,
      ManagedApplicationIdentityVerifier.Context current, ManagedApplicationReport report, Instant retrievedAt) {
    assertThatThrownBy(() -> verifier.verify(captured, current, report, retrievedAt))
        .isExactlyInstanceOf(DomainException.class).hasMessage(code).hasNoCause();
  }

  private static ManagedApplicationIdentityVerifier verifier(Instant now) {
    return new ManagedApplicationIdentityVerifier(Clock.fixed(now, ZoneOffset.UTC),
        Duration.ofMinutes(10), Duration.ofMinutes(2), Duration.ofSeconds(30));
  }

  private ManagedApplicationReport report() { return reportAt(NOW.minusSeconds(30).toString()); }

  private ManagedApplicationReport reportAt(String time) {
    return new ManagedApplicationReport(context.scope().providerDeviceName(), "DEVICE_OWNER",
        context.packageName(), "INSTALLED", List.of(CERT), time);
  }

  private static ManagedApplicationIdentityVerifier.Context context(String field) {
    var base = ManagedApplicationIdentityVerifierTest.context(Set.of(CERT));
    var scope = base.scope();
    var changed = new ManagedApplicationIdentityVerifier.Scope(
        field.equals("tenant") ? "tenant-2" : scope.tenantId(),
        field.equals("device") ? "device-2" : scope.deviceId(),
        field.equals("registration") ? "registration-2" : scope.registrationId(),
        field.equals("key") ? "B".repeat(43) : scope.keyThumbprint(),
        field.equals("binding") ? "binding-2" : scope.bindingId(),
        field.equals("binding-version") ? 3 : scope.bindingVersion(),
        field.equals("provider") ? "OTHER_EMM" : scope.provider(),
        field.equals("provider-device") ? "enterprises/e1/devices/d2" : scope.providerDeviceName(),
        field.equals("enterprise-version") ? 4 : scope.enterpriseBindingVersion(),
        field.equals("connector") ? "sdk-v2" : scope.connectorRevision());
    return new ManagedApplicationIdentityVerifier.Context(changed,
        field.equals("application") ? "app-2" : base.applicationId(),
        field.equals("definition") ? "ef".repeat(32) : field.equals("bad-definition") ? "bad" : base.definitionRevision(),
        field.equals("package") ? "example.other" : base.packageName(),
        field.equals("many-trust") ? java.util.stream.IntStream.range(0, 9)
            .mapToObj(index -> String.format("%064x", index)).collect(java.util.stream.Collectors.toUnmodifiableSet())
            : field.equals("trust") ? Set.of(CERT, OTHER) : field.equals("empty-trust") ? Set.of()
            : field.equals("bad-trust") ? Set.of("bad") : base.trustedSigningCertificates(),
        field.equals("mode") ? "PROFILE_OWNER" : base.managementMode(),
        field.equals("not-before") ? NOW.minusSeconds(10)
            : field.equals("future-start") ? NOW.plusSeconds(1) : base.evidenceNotBefore(),
        !field.equals("inactive"));
  }
}

package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

class ManagedDeviceExecutionVerifierTest {
  static final Instant NOW = Instant.parse("2026-10-16T10:00:00Z");
  static final String NAME = "enterprises/e1/devices/d1";

  @Test
  void boundsProfileReuseByBothProviderReportAndRetrievalTime() {
    Instant now = Instant.parse("2026-10-16T10:00:00Z");
    var verifier =
        new ManagedDeviceExecutionVerifier(
            Clock.fixed(now, ZoneOffset.UTC),
            Duration.ofMinutes(10),
            Duration.ofMinutes(2),
            Duration.ofSeconds(15));
    var profile =
        new ManagedDeviceExecutionProfile(
            "enterprises/e1/devices/d1",
            "DEVICE_OWNER",
            30,
            "ACTIVE",
            "ACTIVE",
            now.minusSeconds(540).toString());
    var result = verifier.verify(profile.deviceName(), now.minusSeconds(600), profile, now);
    assertThat(result).as("device profile freshness must be bounded").isNotNull();
    assertThat(result.deviceName()).isEqualTo(profile.deviceName());
    assertThat(result.apiLevel()).isEqualTo(30);
    assertThat(result.reportedAt()).isEqualTo(now.minusSeconds(540));
    assertThat(result.retrievedAt()).isEqualTo(now);
    assertThat(result.expiresAt()).isEqualTo(now.plusSeconds(60));
  }

  @Test
  void retrievalWindowIsIndependentOfTheReportHardDeadline() {
    var result =
        verifier()
            .verify(
                NAME, NOW.minusSeconds(600), profile(NOW.minusSeconds(40)), NOW.minusSeconds(30));
    assertThat(result.expiresAt()).isEqualTo(NOW.plusSeconds(90));
    assertThat(result.toString()).doesNotContain(NAME, NOW.toString());
  }

  @Test
  void repeatedFetchCannotExtendTheProviderReportHardDeadline() {
    var report = profile(NOW.minusSeconds(540));
    var first = verifier().verify(NAME, NOW.minusSeconds(600), report, NOW.minusSeconds(30));
    var second = verifier().verify(NAME, NOW.minusSeconds(600), report, NOW);
    assertThat(first.expiresAt()).isEqualTo(NOW.plusSeconds(60));
    assertThat(second.expiresAt()).isEqualTo(first.expiresAt());
  }

  @Test
  void exactClockSkewAndEvidenceLowerBoundsAreAccepted() {
    var result = verifier().verify(NAME, NOW, profile(NOW.plusSeconds(15)), NOW);
    assertThat(result.expiresAt()).isEqualTo(NOW.plusSeconds(120));
  }

  @ParameterizedTest
  @CsvSource({
    "missing,MANAGED_DEVICE_PROFILE_MISSING",
    "foreign,MANAGED_DEVICE_PROFILE_INVALID",
    "profileOwner,MANAGED_DEVICE_PROFILE_MODE_UNSUPPORTED",
    "unknownMode,MANAGED_DEVICE_PROFILE_MODE_UNSUPPORTED",
    "nullMode,MANAGED_DEVICE_PROFILE_MODE_UNSUPPORTED",
    "api29,MANAGED_DEVICE_PROFILE_API_UNSUPPORTED",
    "apiZero,MANAGED_DEVICE_PROFILE_API_UNSUPPORTED",
    "desiredDisabled,MANAGED_DEVICE_PROFILE_NOT_ACTIVE",
    "appliedDisabled,MANAGED_DEVICE_PROFILE_NOT_ACTIVE",
    "nullState,MANAGED_DEVICE_PROFILE_NOT_ACTIVE",
    "timeNull,MANAGED_DEVICE_PROFILE_INVALID",
    "timeMalformed,MANAGED_DEVICE_PROFILE_INVALID",
    "timeLong,MANAGED_DEVICE_PROFILE_INVALID",
    "futureReport,MANAGED_DEVICE_PROFILE_INVALID",
    "reportAfterRetrieval,MANAGED_DEVICE_PROFILE_INVALID",
    "futureRetrieval,MANAGED_DEVICE_PROFILE_INVALID",
    "nullRetrieval,MANAGED_DEVICE_PROFILE_INVALID",
    "reportExpired,MANAGED_DEVICE_PROFILE_STALE",
    "retrievalExpired,MANAGED_DEVICE_PROFILE_STALE",
    "reportBeforeAnchor,MANAGED_DEVICE_PROFILE_STALE",
    "retrievalBeforeAnchor,MANAGED_DEVICE_PROFILE_STALE",
    "nullExpected,MANAGED_DEVICE_PROFILE_CONTEXT_INVALID",
    "badExpected,MANAGED_DEVICE_PROFILE_CONTEXT_INVALID",
    "nullAnchor,MANAGED_DEVICE_PROFILE_CONTEXT_INVALID",
    "futureAnchor,MANAGED_DEVICE_PROFILE_CONTEXT_INVALID",
    "negativeAnchor,MANAGED_DEVICE_PROFILE_CONTEXT_INVALID"
  })
  void rejectsUnavailableUnsupportedAndStaleFacts(String variant, String expectedCode) {
    String name = NAME, mode = "DEVICE_OWNER", state = "ACTIVE", applied = "ACTIVE";
    String time = NOW.toString(), expectedName = NAME;
    int api = 30;
    Instant retrieved = NOW, anchor = NOW.minusSeconds(1200);
    switch (variant) {
      case "foreign" -> name = "enterprises/other/devices/d1";
      case "profileOwner" -> mode = "PROFILE_OWNER";
      case "unknownMode" -> mode = "UNKNOWN";
      case "nullMode" -> mode = null;
      case "api29" -> api = 29;
      case "apiZero" -> api = 0;
      case "desiredDisabled" -> state = "DISABLED";
      case "appliedDisabled" -> applied = "DISABLED";
      case "nullState" -> state = null;
      case "timeNull" -> time = null;
      case "timeMalformed" -> time = "invalid-provider-time";
      case "timeLong" -> time = "x".repeat(65);
      case "futureReport" -> time = NOW.plusSeconds(16).toString();
      case "reportAfterRetrieval" -> retrieved = NOW.minusSeconds(16);
      case "futureRetrieval" -> retrieved = NOW.plusNanos(1);
      case "nullRetrieval" -> retrieved = null;
      case "reportExpired" -> time = NOW.minusSeconds(600).toString();
      case "retrievalExpired" -> {
        retrieved = NOW.minusSeconds(120);
        time = NOW.minusSeconds(121).toString();
      }
      case "reportBeforeAnchor" -> {
        anchor = NOW.minusSeconds(60);
        time = NOW.minusSeconds(61).toString();
      }
      case "retrievalBeforeAnchor" -> {
        anchor = NOW.minusSeconds(60);
        retrieved = NOW.minusSeconds(61);
        time = retrieved.toString();
      }
      case "nullExpected" -> expectedName = null;
      case "badExpected" -> expectedName = "invalid resource?";
      case "nullAnchor" -> anchor = null;
      case "futureAnchor" -> anchor = NOW.plusNanos(1);
      case "negativeAnchor" -> anchor = Instant.EPOCH.minusNanos(1);
    }
    var report =
        variant.equals("missing")
            ? null
            : new ManagedDeviceExecutionProfile(name, mode, api, state, applied, time);
    String target = expectedName;
    Instant lowerBound = anchor, obtained = retrieved;
    assertThatThrownBy(() -> verifier().verify(target, lowerBound, report, obtained))
        .isInstanceOfSatisfying(
            DomainException.class, error -> assertThat(error.errorCode()).isEqualTo(expectedCode))
        .hasNoCause()
        .hasMessageNotContaining(NAME)
        .hasMessageNotContaining("invalid-provider-time");
  }

  @ParameterizedTest
  @CsvSource({
    "0,120,15",
    "-1,120,15",
    "3601,120,15",
    "600,0,15",
    "600,-1,15",
    "600,301,15",
    "600,120,-1",
    "600,120,31"
  })
  void freshnessConfigurationCannotDisableBounds(long report, long reuse, long skew) {
    assertThatThrownBy(
            () ->
                new ManagedDeviceExecutionVerifier(
                    Clock.fixed(NOW, ZoneOffset.UTC),
                    Duration.ofSeconds(report),
                    Duration.ofSeconds(reuse),
                    Duration.ofSeconds(skew)))
        .isInstanceOf(IllegalArgumentException.class);
  }

  @Test
  void maximumAllowedConfigurationRemainsFinite() {
    var verifier =
        new ManagedDeviceExecutionVerifier(
            Clock.fixed(NOW, ZoneOffset.UTC),
            Duration.ofHours(1),
            Duration.ofMinutes(5),
            Duration.ZERO);
    assertThat(verifier.verify(NAME, NOW, profile(NOW), NOW).expiresAt())
        .isEqualTo(NOW.plusSeconds(300));
  }

  private ManagedDeviceExecutionVerifier verifier() {
    return new ManagedDeviceExecutionVerifier(
        Clock.fixed(NOW, ZoneOffset.UTC),
        Duration.ofMinutes(10),
        Duration.ofMinutes(2),
        Duration.ofSeconds(15));
  }

  private ManagedDeviceExecutionProfile profile(Instant reportedAt) {
    return new ManagedDeviceExecutionProfile(
        NAME, "DEVICE_OWNER", 30, "ACTIVE", "ACTIVE", reportedAt.toString());
  }
}

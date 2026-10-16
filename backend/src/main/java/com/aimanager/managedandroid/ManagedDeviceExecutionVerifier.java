package com.aimanager.managedandroid;

import com.aimanager.shared.DomainException;
import java.time.Clock;
import java.time.DateTimeException;
import java.time.Duration;
import java.time.Instant;
import java.util.Objects;
import org.springframework.http.HttpStatus;

/**
 * Checks necessary device facts only. API 30 is the compiler's minimum, not proof of a certified
 * device/OS combination. Current tenant, contract, binding and compatibility checks remain
 * required.
 */
public final class ManagedDeviceExecutionVerifier {
  private final Clock clock;
  private final Duration maximumReportAge;
  private final Duration maximumReuseAge;
  private final Duration allowedClockSkew;

  public ManagedDeviceExecutionVerifier(
      Clock clock, Duration maximumReportAge, Duration maximumReuseAge, Duration allowedClockSkew) {
    this.clock = Objects.requireNonNull(clock);
    this.maximumReportAge = Objects.requireNonNull(maximumReportAge);
    this.maximumReuseAge = Objects.requireNonNull(maximumReuseAge);
    this.allowedClockSkew = Objects.requireNonNull(allowedClockSkew);
    if (maximumReportAge.isNegative()
        || maximumReportAge.isZero()
        || maximumReportAge.compareTo(Duration.ofHours(1)) > 0
        || maximumReuseAge.isNegative()
        || maximumReuseAge.isZero()
        || maximumReuseAge.compareTo(Duration.ofMinutes(5)) > 0
        || allowedClockSkew.isNegative()
        || allowedClockSkew.compareTo(Duration.ofSeconds(30)) > 0)
      throw new IllegalArgumentException("Invalid managed device profile freshness configuration");
  }

  /**
   * Caller supplies current authorized binding identity and the registration/evidence lower bound.
   */
  public Verified verify(
      String expectedDeviceName,
      Instant evidenceNotBefore,
      ManagedDeviceExecutionProfile profile,
      Instant retrievedAt) {
    Instant now = clock.instant();
    if (expectedDeviceName == null
        || !expectedDeviceName.matches("[A-Za-z0-9_./:-]{1,512}")
        || evidenceNotBefore == null
        || evidenceNotBefore.isBefore(Instant.EPOCH)
        || evidenceNotBefore.isAfter(now)) throw rejected("MANAGED_DEVICE_PROFILE_CONTEXT_INVALID");
    if (profile == null) throw rejected("MANAGED_DEVICE_PROFILE_MISSING");
    if (!expectedDeviceName.equals(profile.deviceName()))
      throw rejected("MANAGED_DEVICE_PROFILE_INVALID");
    if (!"DEVICE_OWNER".equals(profile.managementMode()))
      throw rejected("MANAGED_DEVICE_PROFILE_MODE_UNSUPPORTED");
    if (profile.apiLevel() < 30) throw rejected("MANAGED_DEVICE_PROFILE_API_UNSUPPORTED");
    if (!"ACTIVE".equals(profile.state()) || !"ACTIVE".equals(profile.appliedState()))
      throw rejected("MANAGED_DEVICE_PROFILE_NOT_ACTIVE");
    if (retrievedAt == null
        || retrievedAt.isAfter(now)
        || profile.lastStatusReportTime() == null
        || profile.lastStatusReportTime().length() > 64)
      throw rejected("MANAGED_DEVICE_PROFILE_INVALID");
    try {
      Instant reportedAt = Instant.parse(profile.lastStatusReportTime());
      if (reportedAt.isAfter(now.plus(allowedClockSkew))
          || reportedAt.isAfter(retrievedAt.plus(allowedClockSkew)))
        throw rejected("MANAGED_DEVICE_PROFILE_INVALID");
      if (reportedAt.isBefore(evidenceNotBefore) || retrievedAt.isBefore(evidenceNotBefore))
        throw rejected("MANAGED_DEVICE_PROFILE_STALE");
      Instant reportDeadline = reportedAt.plus(maximumReportAge);
      Instant reuseDeadline = retrievedAt.plus(maximumReuseAge);
      Instant expiresAt = reportDeadline.isBefore(reuseDeadline) ? reportDeadline : reuseDeadline;
      if (!now.isBefore(expiresAt)) throw rejected("MANAGED_DEVICE_PROFILE_STALE");
      return new Verified(
          profile.deviceName(),
          profile.managementMode(),
          profile.apiLevel(),
          reportedAt,
          retrievedAt,
          expiresAt);
    } catch (DateTimeException | ArithmeticException malformed) {
      throw rejected("MANAGED_DEVICE_PROFILE_INVALID");
    }
  }

  private static DomainException rejected(String code) {
    return new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, code);
  }

  /** Server-side bounded observation. This is not proof that any policy has been applied. */
  public record Verified(
      String deviceName,
      String managementMode,
      int apiLevel,
      Instant reportedAt,
      Instant retrievedAt,
      Instant expiresAt) {
    @Override
    public String toString() {
      return "VerifiedDeviceExecutionProfile[REDACTED]";
    }
  }
}

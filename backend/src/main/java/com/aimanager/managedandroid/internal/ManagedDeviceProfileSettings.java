package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedDeviceExecutionVerifier;
import java.time.Clock;
import java.time.Duration;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Bounded freshness configuration; creating this bean does not enable policy execution. */
@Component
final class ManagedDeviceProfileSettings {
  final ManagedDeviceExecutionVerifier verifier;

  ManagedDeviceProfileSettings(
      Clock clock,
      @Value("${manager.emm.device-profile.max-report-age-seconds:600}") long reportAge,
      @Value("${manager.emm.device-profile.max-reuse-age-seconds:120}") long reuseAge,
      @Value("${manager.emm.device-profile.clock-skew-seconds:15}") long clockSkew) {
    verifier =
        new ManagedDeviceExecutionVerifier(
            clock,
            Duration.ofSeconds(reportAge),
            Duration.ofSeconds(reuseAge),
            Duration.ofSeconds(clockSkew));
  }
}

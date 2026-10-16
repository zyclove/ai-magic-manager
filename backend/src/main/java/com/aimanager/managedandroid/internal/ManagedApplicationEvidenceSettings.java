package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.ManagedApplicationIdentityVerifier;
import java.time.Clock;
import java.time.Duration;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Bounded freshness; a configuration change invalidates previously stored facts. */
@Component
class ManagedApplicationEvidenceSettings {
  static final int MAX_APPLICATIONS = 200;
  static final long ATTEMPT_MILLIS = 120_000;
  static final long COOLDOWN_MILLIS = 30_000;
  final ManagedApplicationIdentityVerifier verifier;
  final String revision;

  ManagedApplicationEvidenceSettings(
      Clock clock,
      @Value("${manager.emm.application-evidence.max-report-age-seconds:600}") long reportAge,
      @Value("${manager.emm.application-evidence.max-reuse-age-seconds:120}") long reuseAge,
      @Value("${manager.emm.application-evidence.clock-skew-seconds:15}") long clockSkew) {
    verifier =
        new ManagedApplicationIdentityVerifier(
            clock,
            Duration.ofSeconds(reportAge),
            Duration.ofSeconds(reuseAge),
            Duration.ofSeconds(clockSkew));
    revision = "application-evidence-v1-" + reportAge + "-" + reuseAge + "-" + clockSkew;
  }
}

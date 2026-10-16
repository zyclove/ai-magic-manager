package com.aimanager.managedandroid.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.managedandroid.ManagedDeviceExecutionProfile;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import org.junit.jupiter.api.Test;

class ManagedDeviceProfileSettingsTest {
  @Test
  void configuredDurationsAreAppliedWithoutEnablingExecution() {
    Instant now = Instant.parse("2026-10-16T10:00:00Z");
    var settings = new ManagedDeviceProfileSettings(Clock.fixed(now, ZoneOffset.UTC), 200, 20, 3);
    var report =
        new ManagedDeviceExecutionProfile(
            "enterprises/e1/devices/d1",
            "DEVICE_OWNER",
            30,
            "ACTIVE",
            "ACTIVE",
            now.minusSeconds(10).toString());
    assertThat(
            settings
                .verifier
                .verify(report.deviceName(), now.minusSeconds(30), report, now)
                .expiresAt())
        .isEqualTo(now.plusSeconds(20));
  }

  @Test
  void invalidDurationsFailConfigurationInsteadOfDisablingFreshness() {
    assertThatThrownBy(() -> new ManagedDeviceProfileSettings(Clock.systemUTC(), 600, 0, 15))
        .isInstanceOf(IllegalArgumentException.class);
  }
}

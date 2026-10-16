package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

/** 服务端纯领域检查：固定时钟，不启动 Spring、数据库或提供方连接。 */
class ManagedApplicationIdentityVerifierTest {
  private static final Instant NOW = Instant.parse("2026-10-16T08:00:00Z");
  private static final String CERT = "ab".repeat(32);
  private static final String APP = "example.learning.app";
  private final ManagedApplicationIdentityVerifier verifier = new ManagedApplicationIdentityVerifier(
      Clock.fixed(NOW, ZoneOffset.UTC), Duration.ofMinutes(10), Duration.ofMinutes(2), Duration.ofSeconds(30));

  @Test
  void currentBoundApplicationProducesExpiringIdentityWithoutInventingProfile() {
    var context = context(Set.of(CERT));
    var report = new ManagedApplicationReport(context.scope().providerDeviceName(), "DEVICE_OWNER",
        APP, "INSTALLED", List.of(CERT), NOW.minusSeconds(30).toString());
    var captured = new AtomicReference<ManagedApplicationIdentityVerifier.Verified>();
    assertThatCode(() -> captured.set(verifier.verify(context, context, report, NOW)))
        .doesNotThrowAnyException();
    var verified = captured.get();
    assertThat(verified.context()).isEqualTo(context);
    assertThat(verified.signingCertificates()).containsExactly(CERT);
    assertThat(verified.reportedAt()).isEqualTo(NOW.minusSeconds(30));
    assertThat(verified.retrievedAt()).isEqualTo(NOW);
    assertThat(verified.expiresAt()).isEqualTo(NOW.plusSeconds(120));
    assertThat(verified.profileScope()).isEqualTo(ManagedApplicationIdentityVerifier.ProfileScope.UNKNOWN);
    assertThat(verified.toString()).doesNotContain(APP, CERT, "tenant-1");
  }

  @Test
  void contextDefensivelyCopiesTrustAndRedactsDiagnosticText() {
    var mutable = new HashSet<>(Set.of(CERT));
    var context = context(mutable);
    mutable.clear();
    assertThat(context.trustedSigningCertificates()).containsExactly(CERT);
    assertThatThrownBy(() -> context.trustedSigningCertificates().clear())
        .isInstanceOf(UnsupportedOperationException.class);
    assertThat(context.toString()).doesNotContain(APP, CERT, "tenant-1");
    assertThat(context.scope().toString()).doesNotContain("tenant-1", "registration-1", "enterprises/");
  }

  static ManagedApplicationIdentityVerifier.Context context(Set<String> trusted) {
    var scope = new ManagedApplicationIdentityVerifier.Scope("tenant-1", "device-1", "registration-1",
        "A".repeat(43), "binding-1", 2, "GOOGLE_AMAPI", "enterprises/e1/devices/d1", 3, "sdk-v1");
    return new ManagedApplicationIdentityVerifier.Context(scope, "app-1", "cd".repeat(32),
        APP, trusted, "DEVICE_OWNER", NOW.minusSeconds(600), true);
  }
}

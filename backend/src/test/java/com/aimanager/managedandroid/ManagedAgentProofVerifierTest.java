package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.shared.DomainException;
import com.nimbusds.jose.JOSEObjectType;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.JWSObject;
import com.nimbusds.jose.Payload;
import com.nimbusds.jose.crypto.ECDSASigner;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.ECKey;
import com.nimbusds.jose.jwk.gen.ECKeyGenerator;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class ManagedAgentProofVerifierTest {
  private static final long NOW = 1_792_080_000_000L;
  private static final String CERT = "ab".repeat(32);
  private static final String DEVICE = "enterprises/e1/devices/d1";
  private static final String APP = "com.aimanager.child";
  private static final String NONCE =
      Base64.getUrlEncoder().withoutPadding().encodeToString(new byte[32]);
  private ECKey key;
  private ManagedAgentProofVerifier.Expected expected;
  private final ManagedAgentProofVerifier verifier =
      new ManagedAgentProofVerifier(Clock.fixed(Instant.ofEpochMilli(NOW), ZoneOffset.UTC));

  @BeforeEach
  void prepare() throws Exception {
    key = new ECKeyGenerator(Curve.P_256).generate();
    expected =
        new ManagedAgentProofVerifier.Expected(
            UUID.randomUUID().toString(),
            NONCE,
            NOW - 60_000,
            NOW + 240_000,
            DEVICE,
            APP,
            key.toPublicJWK().toJSONString(),
            Set.of(CERT));
  }

  private Map<String, Object> claims() {
    var result = new HashMap<String, Object>();
    result.put("sub", expected.challengeId());
    result.put("nonce", NONCE);
    result.put("aud", List.of(ManagedAgentProofVerifier.AUDIENCE));
    result.put("iat", (NOW - 30_000) / 1000);
    result.put("exp", (NOW + 120_000) / 1000);
    result.put("jti", UUID.randomUUID().toString());
    return result;
  }

  private String sign(Map<String, Object> values) throws Exception {
    return sign(
        new Payload(values),
        new JWSHeader.Builder(JWSAlgorithm.ES256).type(JOSEObjectType.JWT).build(),
        key);
  }

  private String sign(Payload values, JWSHeader header, ECKey signingKey) throws Exception {
    var proof = new JWSObject(header, values);
    proof.sign(new ECDSASigner(signingKey));
    return proof.serialize();
  }

  private ManagedAgentEvidence evidence(String proof) {
    return new ManagedAgentEvidence(
        DEVICE,
        "DEVICE_OWNER",
        APP,
        "INSTALLED",
        List.of(CERT),
        ManagedAgentEvidence.FEEDBACK_KEY,
        "INFO",
        proof,
        Instant.ofEpochMilli(NOW - 10_000).toString(),
        Instant.ofEpochMilli(NOW - 5000).toString());
  }

  private void rejects(ManagedAgentProofVerifier.Expected context, ManagedAgentEvidence report) {
    assertThatThrownBy(() -> verifier.verify(context, report))
        .isInstanceOf(DomainException.class)
        .hasMessage("MANAGED_AGENT_PROOF_INVALID")
        .hasNoCause();
  }

  @Test
  void validProviderProofReturnsOnlyBoundedDigestAndRegistrationKeyThumbprint() throws Exception {
    String proof = sign(claims());
    var report = evidence(proof);
    var result = verifier.verify(expected, report);
    assertThat(proof.length()).isLessThanOrEqualTo(1000);
    assertThat(result.proofSha256()).matches("[0-9a-f]{64}");
    assertThat(result.keyThumbprint()).isEqualTo(key.computeThumbprint().toString());
    assertThat(report.toString()).doesNotContain(proof, DEVICE, NONCE);
    assertThat(expected.toString()).doesNotContain(NONCE, DEVICE);
    assertThat(result.toString()).doesNotContain(result.keyThumbprint());
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "sub",
        "nonce",
        "aud",
        "jti",
        "iat",
        "exp",
        "missing",
        "extra",
        "fraction",
        "overflow",
        "future",
        "before",
        "beyond"
      })
  void rejectsClaimsOutsideExactChallengeAndPurpose(String change) throws Exception {
    var values = claims();
    switch (change) {
      case "sub", "nonce", "aud", "jti" -> values.put(change, "different");
      case "iat" -> values.put("iat", "not-a-number");
      case "exp" -> values.put("exp", NOW / 1000);
      case "missing" -> values.remove("nonce");
      case "extra" -> values.put("email", "never-include-identifiers");
      case "fraction" -> values.put("iat", (NOW - 30_000) / 1000.0 + 0.5);
      case "overflow" -> values.put("iat", Long.MAX_VALUE);
      case "future" -> values.put("iat", (NOW + 60_000) / 1000);
      case "before" -> values.put("iat", (NOW - 120_000) / 1000);
      case "beyond" -> values.put("exp", (NOW + 300_000) / 1000);
      default -> throw new AssertionError(change);
    }
    rejects(expected, evidence(sign(values)));
  }

  @ParameterizedTest
  @ValueSource(
      strings = {
        "device",
        "mode",
        "package",
        "state",
        "signer",
        "extra-signer",
        "duplicate-signer",
        "missing-signer",
        "key",
        "severity",
        "old-feedback",
        "future-feedback",
        "old-report",
        "future-report",
        "malformed-time"
      })
  void rejectsWrongProviderSourceAndStaleReports(String change) throws Exception {
    var e = evidence(sign(claims()));
    var report =
        new ManagedAgentEvidence(
            change.equals("device") ? "enterprises/e2/devices/d1" : e.deviceName(),
            change.equals("mode") ? "PROFILE_OWNER" : e.managementMode(),
            change.equals("package") ? "com.example.fake" : e.packageName(),
            change.equals("state") ? "REMOVED" : e.applicationState(),
            switch (change) {
              case "signer" -> List.of("cd".repeat(32));
              case "extra-signer" -> List.of(CERT, "cd".repeat(32));
              case "duplicate-signer" -> List.of(CERT, CERT);
              case "missing-signer" -> List.of();
              default -> e.signingCertificateSha256();
            },
            change.equals("key") ? "other" : e.feedbackKey(),
            change.equals("severity") ? "ERROR" : e.severity(),
            e.proof(),
            switch (change) {
              case "old-feedback" -> Instant.ofEpochMilli(NOW - 61_000).toString();
              case "future-feedback" -> Instant.ofEpochMilli(NOW + 31_000).toString();
              case "malformed-time" -> "invalid";
              default -> e.feedbackUpdatedAt();
            },
            switch (change) {
              case "old-report" -> Instant.ofEpochMilli(NOW - 61_000).toString();
              case "future-report" -> Instant.ofEpochMilli(NOW + 31_000).toString();
              default -> e.deviceReportedAt();
            });
    rejects(expected, report);
  }

  @Test
  void rejectsUntrustedKeyAndPrivateKeyMaterial() throws Exception {
    String proof = sign(claims());
    var other = new ECKeyGenerator(Curve.P_256).generate();
    for (String value :
        List.of(other.toPublicJWK().toJSONString(), key.toJSONString(), "invalid")) {
      rejects(
          new ManagedAgentProofVerifier.Expected(
              expected.challengeId(),
              NONCE,
              expected.createdAt(),
              expected.expiresAt(),
              DEVICE,
              APP,
              value,
              Set.of(CERT)),
          evidence(proof));
    }
  }

  @Test
  void rejectsExpiredContextAndEmptyReleaseTrust() throws Exception {
    String proof = sign(claims());
    rejects(
        new ManagedAgentProofVerifier.Expected(
            expected.challengeId(),
            NONCE,
            NOW - 60_000,
            NOW,
            DEVICE,
            APP,
            key.toPublicJWK().toJSONString(),
            Set.of(CERT)),
        evidence(proof));
    rejects(
        new ManagedAgentProofVerifier.Expected(
            expected.challengeId(),
            NONCE,
            expected.createdAt(),
            expected.expiresAt(),
            DEVICE,
            APP,
            key.toPublicJWK().toJSONString(),
            Set.of()),
        evidence(proof));
  }

  @Test
  void rejectsDuplicateJsonAndUnknownHeaderEvenWhenCorrectlySigned() throws Exception {
    var header = new JWSHeader.Builder(JWSAlgorithm.ES256).type(JOSEObjectType.JWT).build();
    String duplicate = new Payload(claims()).toString().replace("{", "{\"nonce\":\"other\", ");
    rejects(expected, evidence(sign(new Payload(duplicate), header, key)));
    rejects(
        expected,
        evidence(
            sign(
                new Payload(claims()),
                new JWSHeader.Builder(JWSAlgorithm.ES256)
                    .type(JOSEObjectType.JWT)
                    .keyID("untrusted-key-selector")
                    .build(),
                key)));
  }

  @Test
  void rejectsMalformedAndOversizedProofWithoutEchoingInput() throws Exception {
    for (String proof :
        List.of("invalid", "private-marker".repeat(100), sign(claims()) + "=", ".a.b")) {
      rejects(expected, evidence(proof));
    }
    rejects(expected, null);
  }
}

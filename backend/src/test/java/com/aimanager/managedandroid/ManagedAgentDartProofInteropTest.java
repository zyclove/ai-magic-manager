package com.aimanager.managedandroid;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;

/** Real Dart JOSE producer against production Nimbus verifier; no real EMM or native keystore. */
@EnabledIfSystemProperty(named = "device.identity.package", matches = ".+")
class ManagedAgentDartProofInteropTest {
  @Test
  void dartProofMatchesServerProtocolAndCannotBindAnotherChallenge() throws Exception {
    long now = 1792080000000L;
    String id = UUID.randomUUID().toString(), nonce = "A".repeat(43), cert = "ab".repeat(32);
    var mapper = new ObjectMapper();
    var root = Path.of(".local").toAbsolutePath();
    Files.createDirectories(root);
    var directory = Files.createTempDirectory(root, "managed-binding-interop-");
    var input = directory.resolve("input.json");
    var output = directory.resolve("result.json");
    var log = directory.resolve("process.log");
    Process process = null;
    try {
      mapper.writeValue(
          input.toFile(),
          Map.of(
              "nowMillis",
              now,
              "challenge",
              Map.of(
                  "challengeId",
                  id,
                  "nonce",
                  nonce,
                  "audience",
                  ManagedAgentProofVerifier.AUDIENCE,
                  "createdAt",
                  now - 1000,
                  "expiresAt",
                  now + 599000)));
      process =
          new ProcessBuilder(
                  System.getProperty("device.dart.command"),
                  "run",
                  "tool/managed_binding_interop.dart",
                  input.toString(),
                  output.toString())
              .directory(Path.of(System.getProperty("device.identity.package")).toFile())
              .redirectErrorStream(true)
              .redirectOutput(log.toFile())
              .start();
      assertThat(process.waitFor(45, TimeUnit.SECONDS)).as("Dart process deadline").isTrue();
      assertThat(process.exitValue()).as("Dart fixture exit; inspect %s", log).isZero();
      assertThat(Files.size(output)).isLessThan(4096);
      var result = mapper.readTree(output.toFile());
      var expected =
          new ManagedAgentProofVerifier.Expected(
              id,
              nonce,
              now - 1000,
              now + 599000,
              "enterprises/e1/devices/d1",
              "com.aimanager.child",
              result.path("publicKeyJwk").asText(),
              Set.of(cert));
      var evidence =
          new ManagedAgentEvidence(
              "enterprises/e1/devices/d1",
              "DEVICE_OWNER",
              "com.aimanager.child",
              "INSTALLED",
              List.of(cert),
              ManagedAgentEvidence.FEEDBACK_KEY,
              "INFO",
              result.path("proof").asText(),
              Instant.ofEpochMilli(now).toString(),
              Instant.ofEpochMilli(now).toString());
      var verifier =
          new ManagedAgentProofVerifier(Clock.fixed(Instant.ofEpochMilli(now), ZoneOffset.UTC));
      assertThat(verifier.verify(expected, evidence).proofSha256()).hasSize(64);
      var other =
          new ManagedAgentProofVerifier.Expected(
              UUID.randomUUID().toString(),
              nonce,
              expected.createdAt(),
              expected.expiresAt(),
              expected.deviceName(),
              expected.packageName(),
              expected.publicKeyJwk(),
              expected.trustedSigningCertificates());
      assertThatThrownBy(() -> verifier.verify(other, evidence))
          .isInstanceOf(DomainException.class);
    } finally {
      if (process != null && process.isAlive()) {
        process.destroyForcibly();
        process.waitFor(10, TimeUnit.SECONDS);
      }
      Files.deleteIfExists(input);
      Files.deleteIfExists(output);
      Files.deleteIfExists(log);
      Files.deleteIfExists(directory);
    }
  }
}

package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.keycloak.authentication.Authenticator;

class ConsumerRuntimeSnapshotTest {
  private static final String KEY = "CONSUMER_OTP_HMAC_KEY";
  private static final String FIRST_KEY = "first-key-at-least-thirty-two-bytes";
  private static final String SECOND_KEY = "second-key-at-least-thirty-two-bytes";
  // Mirror the fixed public configuration names accepted by ConsumerConfiguration.
  // Only names are used: inherited secret values are neither read nor reported.
  private static final String[] CONFIGURATION_KEYS = {
      "CONSUMER_OTP_HMAC_KEY", "ALIYUN_SMS_ACCESS_KEY_ID", "ALIYUN_SMS_ACCESS_KEY_SECRET",
      "ALIYUN_SMS_SECURITY_TOKEN", "WECHAT_NATIVE_APP_SECRET", "CONSUMER_PHONE_ENABLED",
      "CONSUMER_WECHAT_ENABLED", "CONSUMER_ACCOUNT_SECURITY_ENABLED", "ALIYUN_SMS_SIGN_NAME",
      "ALIYUN_SMS_TEMPLATE_CODE", "WECHAT_NATIVE_APP_ID"
  };
  private static final String[] OBSERVATION_KEYS = {
      "IDENTITY_PROVIDER_ENVIRONMENT_ID", "IDENTITY_PROVIDER_OPERATION_ID",
      "IDENTITY_PROVIDER_VERSION_ID", "IDENTITY_PROVIDER_INSTANCE_ID",
      "IDENTITY_PROVIDER_OBSERVATION_KEY_FILE"
  };

  @TempDir Path directory;

  @Test void runningFactoriesKeepTheSameLoadedSecretsUntilProcessRestart() throws Exception {
    Path secret = directory.resolve("snapshot-key");
    Files.writeString(secret, FIRST_KEY, StandardCharsets.UTF_8);
    runProbe(secret, "same-process");
    assertEquals(SECOND_KEY, Files.readString(secret, StandardCharsets.UTF_8),
        "The first probe must actually replace the fixture file");
    // A second JVM has a fresh ConsumerProviderRuntime holder. Merely comparing
    // two values inside one process cannot establish this restart behavior.
    runProbe(secret, "after-restart");
  }

  @Test void failedProbesCloseStreamsAndOnlyTerminateTheirOwnLiveProcess() throws Exception {
    for (boolean timedOut : new boolean[]{true, false}) {
      Process running = mock(Process.class);
      InputStream stdout = mock(InputStream.class);
      InputStream stderr = mock(InputStream.class);
      OutputStream stdin = mock(OutputStream.class);
      when(running.getInputStream()).thenReturn(stdout);
      when(running.getErrorStream()).thenReturn(stderr);
      when(running.getOutputStream()).thenReturn(stdin);
      when(running.waitFor(30, TimeUnit.SECONDS)).thenReturn(!timedOut);
      when(running.exitValue()).thenReturn(7);
      when(running.isAlive()).thenReturn(timedOut);
      when(running.destroyForcibly()).thenReturn(running);
      when(running.waitFor(5, TimeUnit.SECONDS)).thenReturn(true);

      AssertionError failure = assertThrows(AssertionError.class,
          () -> awaitProbe(running, directory.resolve("controlled-failure.log")));
      assertTrue(failure.getMessage().contains(timedOut ? "timed out" : "Snapshot probe failed"));
      if (timedOut) {
        verify(running).destroyForcibly();
        verify(running).waitFor(5, TimeUnit.SECONDS);
      } else {
        verify(running, never()).destroyForcibly();
        verify(running, never()).waitFor(5, TimeUnit.SECONDS);
      }
      verify(stdin).close();
      verify(stdout).close();
      verify(stderr).close();
    }
  }

  private void runProbe(Path secret, String mode) throws Exception {
    String executable = System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java";
    String java = Path.of(System.getProperty("java.home"), "bin", executable).toString();
    Path output = Files.createTempFile(directory, "snapshot-probe-", ".log");
    ProcessBuilder builder = new ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
        Probe.class.getName(), secret.toString(), mode);
    for (String key : CONFIGURATION_KEYS) {
      builder.environment().remove(key);
      builder.environment().remove(key + "_FILE");
    }
    // The snapshot runtime also has an optional authenticated observation path.
    // A child testing only HMAC loading must never inherit its host file reference.
    for (String key : OBSERVATION_KEYS) builder.environment().remove(key);
    builder.environment().put(KEY + "_FILE", secret.toString());
    // File redirection cannot fill an unread stdout/stderr pipe while waitFor
    // waits. Keep diagnostics inside this test's task-local temporary directory.
    builder.redirectErrorStream(true);
    builder.redirectOutput(output.toFile());
    awaitProbe(builder.start(), output);
  }

  private static void awaitProbe(Process running, Path output) throws Exception {
    try (OutputStream stdin = running.getOutputStream();
         InputStream stdout = running.getInputStream();
         InputStream stderr = running.getErrorStream()) {
      try {
        assertTrue(running.waitFor(30, TimeUnit.SECONDS), "Snapshot probe timed out");
        assertEquals(0, running.exitValue(), "Snapshot probe failed; task log: " + output.getFileName());
      } finally {
        if (running.isAlive()) {
          // This handle was returned by this test's own ProcessBuilder.start().
          // No process enumeration, global process cleanup, or unrelated kill.
          running.destroyForcibly();
          assertTrue(running.waitFor(5, TimeUnit.SECONDS), "Owned snapshot probe did not terminate");
        }
      }
    }
  }

  public static final class Probe {
    public static void main(String[] arguments) throws Exception {
      if (arguments.length != 2) throw new IllegalArgumentException("Invalid snapshot probe arguments");
      ConsumerAuthenticatorFactory factory = new ConsumerAuthenticatorFactory();
      try {
        factory.init(null);
        if ("same-process".equals(arguments[1])) {
          requireKey(factory, FIRST_KEY, "Initial fixture secret was not loaded");
          Files.writeString(Path.of(arguments[0]), SECOND_KEY, StandardCharsets.UTF_8);
          requireKey(factory, FIRST_KEY, "Running process reloaded a changed fixture secret");
        } else if ("after-restart".equals(arguments[1])) {
          requireKey(factory, SECOND_KEY, "Restarted process did not load the new fixture secret");
        } else {
          throw new IllegalArgumentException("Invalid snapshot probe mode");
        }
      } finally {
        factory.close();
      }
    }

    private static void requireKey(ConsumerAuthenticatorFactory factory, String expected, String message)
        throws Exception {
      Authenticator authenticator = factory.create(null);
      try {
        var field = ConsumerAuthenticator.class.getDeclaredField("config");
        field.setAccessible(true);
        Map<?, ?> configuration = (Map<?, ?>) field.get(authenticator);
        if (!expected.equals(configuration.get(KEY))) throw new AssertionError(message);
      } finally {
        authenticator.close();
      }
    }
  }
}

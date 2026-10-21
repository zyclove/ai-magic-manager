package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ConsumerRuntimeSnapshotTest {
  @TempDir Path directory;
  @Test void runningFactoriesKeepTheSameLoadedSecretsUntilProcessRestart() throws Exception {
    Path secret=directory.resolve("snapshot-key");Files.writeString(secret,"first-key-at-least-thirty-two-bytes");
    String java=Path.of(System.getProperty("java.home"),"bin","java").toString();
    var process=new ProcessBuilder(java,"-cp",System.getProperty("java.class.path"),Probe.class.getName(),secret.toString());
    process.environment().put("CONSUMER_OTP_HMAC_KEY_FILE",secret.toString());
    process.redirectErrorStream(true);var running=process.start();
    assertTrue(running.waitFor(30,TimeUnit.SECONDS));
    assertEquals(0,running.exitValue(),new String(running.getInputStream().readAllBytes()));
  }
  public static final class Probe {
    public static void main(String[] arguments) throws Exception {
      var factory=new ConsumerAuthenticatorFactory();factory.init(null);
      var field=ConsumerAuthenticator.class.getDeclaredField("config");field.setAccessible(true);
      var first=(Map<?,?>)field.get(factory.create(null));
      Files.writeString(Path.of(arguments[0]),"second-key-at-least-thirty-two-bytes");
      var second=(Map<?,?>)field.get(factory.create(null));
      if(!Objects.equals(first.get("CONSUMER_OTP_HMAC_KEY"),second.get("CONSUMER_OTP_HMAC_KEY")))throw new AssertionError("A running identity process reloaded one secret without a controlled restart");
    }
  }
}

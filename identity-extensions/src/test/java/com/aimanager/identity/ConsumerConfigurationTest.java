package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.file.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ConsumerConfigurationTest {
  @TempDir Path directory;
  @Test void bothFactoriesCanLoadOnlyKnownBoundedFileBackedSecrets()throws Exception{
    Path secret=directory.resolve("test-key");Files.writeString(secret,"test-secret-at-least-thirty-two-bytes\n");
    var input=new HashMap<String,String>();input.put("CONSUMER_OTP_HMAC_KEY_FILE",secret.toString());input.put("CONSUMER_PHONE_ENABLED","true");input.put("UNRELATED_SECRET_FILE",directory.resolve("does-not-exist").toString());
    var loaded=ConsumerConfiguration.load(input);assertEquals("test-secret-at-least-thirty-two-bytes",loaded.get("CONSUMER_OTP_HMAC_KEY"));assertFalse(loaded.containsKey("UNRELATED_SECRET_FILE"));
  }
  @Test void malformedMissingAndOversizedFileDisableAllConsumerEntrypoints()throws Exception{
    for(String content:List.of("first\nsecond", "x".repeat(8193))){Path secret=directory.resolve(UUID.randomUUID().toString());Files.writeString(secret,content);var loaded=ConsumerConfiguration.load(Map.of("CONSUMER_PHONE_ENABLED","true","CONSUMER_ACCOUNT_SECURITY_ENABLED","true","CONSUMER_OTP_HMAC_KEY_FILE",secret.toString()));assertEquals("false",loaded.get("CONSUMER_PHONE_ENABLED"));assertEquals("false",loaded.get("CONSUMER_ACCOUNT_SECURITY_ENABLED"));assertNull(loaded.get("CONSUMER_OTP_HMAC_KEY"));}
    assertEquals("false",ConsumerConfiguration.load(Map.of("CONSUMER_PHONE_ENABLED","true","CONSUMER_OTP_HMAC_KEY_FILE",directory.resolve("missing").toString())).get("CONSUMER_PHONE_ENABLED"));
  }
  @Test void shortHmacCannotAdvertiseUsablePhoneService(){
    var f=new ConsumerAccountFlowTest.Fixture();f.config.put("CONSUMER_OTP_HMAC_KEY","too-short");assertFalse(ConsumerConfiguration.phoneAvailable(f.config));
  }
}

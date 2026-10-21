package com.aimanager.identity;

import static org.junit.jupiter.api.Assertions.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class ConsumerProviderRuntimeTest {
  @TempDir Path directory;
  static final long NOW=1700000000L;
  static final byte[] KEY=new byte[32];
  static final String OP="7061d3e0-7575-4db6-9843-39157409e13e",VERSION="6dd3ed7e-7828-4eb5-a327-309aef8ad8ae";
  static final String NONCE=Base64.getUrlEncoder().withoutPadding().encodeToString(new byte[32]);
  Map<String,String> environment() throws Exception {
    var e=new HashMap<String,String>();Path key=directory.resolve(UUID.randomUUID()+".key");Files.writeString(key,Base64.getUrlEncoder().withoutPadding().encodeToString(KEY));
    e.put("IDENTITY_PROVIDER_OBSERVATION_KEY_FILE",key.toString());e.put("IDENTITY_PROVIDER_ENVIRONMENT_ID","family-cn-isolated");e.put("IDENTITY_PROVIDER_OPERATION_ID",OP);e.put("IDENTITY_PROVIDER_VERSION_ID",VERSION);e.put("IDENTITY_PROVIDER_INSTANCE_ID","identity-1");
    e.put("ALIYUN_SMS_SIGN_NAME","家庭验证码");e.put("ALIYUN_SMS_TEMPLATE_CODE","SMS_123");e.put("WECHAT_NATIVE_APP_ID","wx0123456789abcdef");
    e.put("CONSUMER_OTP_HMAC_KEY","Q".repeat(40));e.put("ALIYUN_SMS_ACCESS_KEY_ID","LTAI"+"K".repeat(20));e.put("ALIYUN_SMS_ACCESS_KEY_SECRET","S".repeat(32));e.put("ALIYUN_SMS_SECURITY_TOKEN","");e.put("WECHAT_NATIVE_APP_SECRET","a".repeat(32));return e;
  }
  ConsumerProviderRuntime runtime(Map<String,String> e) throws Exception {
    Path jar=directory.resolve(UUID.randomUUID()+".jar");Files.writeString(jar,"actual-loaded-provider-fixture");
    return new ConsumerProviderRuntime(e,jar,Clock.fixed(Instant.ofEpochSecond(NOW),ZoneOffset.UTC));
  }
  ConsumerProviderRuntime.Request request(String env,String op,long time,String nonce) throws Exception {
    return new ConsumerProviderRuntime.Request(env,op,nonce,time,sign("family-identity-runtime-request-v1",env,op,nonce,Long.toString(time)));
  }
  @Test void proofBindsActualSnapshotAndNeverReturnsSecretsOrStableSecretDigests() throws Exception {
    var e=environment();var r=runtime(e);var observed=r.observe(request("family-cn-isolated",OP,NOW,NONCE));
    assertEquals(VERSION,observed.versionId());assertEquals(OP,observed.operationId());assertEquals("identity-1",observed.instanceId());assertEquals(36,observed.bootId().length());assertFalse(observed.phoneEnabled());assertFalse(observed.wechatEnabled());assertFalse(observed.accountSecurityEnabled());
    assertEquals(sign("family-identity-runtime-response-v1",observed.environmentId(),observed.operationId(),observed.versionId(),observed.instanceId(),observed.bootId(),"1700000000","1700000000",observed.providerJarSha256(),"false","false","false",NONCE,e.get("ALIYUN_SMS_SIGN_NAME"),e.get("ALIYUN_SMS_TEMPLATE_CODE"),e.get("WECHAT_NATIVE_APP_ID"),e.get("CONSUMER_OTP_HMAC_KEY"),e.get("ALIYUN_SMS_ACCESS_KEY_ID"),e.get("ALIYUN_SMS_ACCESS_KEY_SECRET"),"",e.get("WECHAT_NATIVE_APP_SECRET")),observed.proof());
    var fields=Arrays.stream(observed.getClass().getRecordComponents()).map(java.lang.reflect.RecordComponent::getName).toList();assertFalse(fields.stream().anyMatch(x->x.toLowerCase().matches(".*(credential|digest|hmac|secret|setting).*")));
    var changed=new HashMap<>(e);changed.put("ALIYUN_SMS_ACCESS_KEY_SECRET","different-secret-value-"+"Z".repeat(20));var other=runtime(changed);var second=other.observe(request("family-cn-isolated",OP,NOW,NONCE));
    assertNotEquals(observed.proof(),second.proof());
  }
  @Test void authenticatedRequestsRejectWrongEnvironmentOperationProofExpiredAndMalformedNonce() throws Exception {
    var r=runtime(environment());
    for(var invalid:List.of(request("family-cn-other",OP,NOW,NONCE),request("family-cn-isolated",VERSION,NOW,NONCE),request("family-cn-isolated",OP,NOW-31,NONCE),request("family-cn-isolated",OP,NOW+31,NONCE),request("family-cn-isolated",OP,NOW,"short"),new ConsumerProviderRuntime.Request("family-cn-isolated",OP,NONCE,NOW,"0".repeat(64))))assertThrows(ConsumerProviderRuntime.Denied.class,()->r.observe(invalid));
  }
  @Test void missingObservationKeyOrJarClosesOnlyObservationAndDoesNotInventFacts() throws Exception {
    var e=environment();e.remove("IDENTITY_PROVIDER_OBSERVATION_KEY_FILE");var r=runtime(e);assertThrows(ConsumerProviderRuntime.Unavailable.class,()->r.observe(request("family-cn-isolated",OP,NOW,NONCE)));
    assertEquals("SMS_123",r.configuration().get("ALIYUN_SMS_TEMPLATE_CODE"));
    var missing=new ConsumerProviderRuntime(environment(),directory.resolve("missing.jar"),Clock.systemUTC());assertThrows(ConsumerProviderRuntime.Unavailable.class,()->missing.observe(request("family-cn-isolated",OP,NOW,NONCE)));
  }
  @Test void changedFileDoesNotChangeExistingProofButRestartChangesBootAndLoadedSecrets() throws Exception {
    var e=environment();Path secret=directory.resolve("supplier-secret");Files.writeString(secret,"S".repeat(32));e.remove("ALIYUN_SMS_ACCESS_KEY_SECRET");e.put("ALIYUN_SMS_ACCESS_KEY_SECRET_FILE",secret.toString());
    var first=runtime(e);var before=first.observe(request("family-cn-isolated",OP,NOW,NONCE));Files.writeString(secret,"T".repeat(32));var after=first.observe(request("family-cn-isolated",OP,NOW,NONCE));assertEquals(before.proof(),after.proof());
    var restarted=runtime(e).observe(request("family-cn-isolated",OP,NOW,NONCE));assertNotEquals(before.bootId(),restarted.bootId());assertNotEquals(before.proof(),restarted.proof());
  }
  static String sign(String... values) throws Exception {
    var mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(KEY,"HmacSHA256"));
    for(String value:values){byte[] bytes=value.getBytes(StandardCharsets.UTF_8);mac.update((bytes.length+":").getBytes(StandardCharsets.US_ASCII));mac.update(bytes);}return Base64.getUrlEncoder().withoutPadding().encodeToString(mac.doFinal());
  }
}

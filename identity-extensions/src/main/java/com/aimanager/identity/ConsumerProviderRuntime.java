package com.aimanager.identity;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.*;
import java.time.Clock;
import java.util.*;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** One immutable process configuration. Observation proves loaded values without returning them. */
final class ConsumerProviderRuntime {
  private static final String UUID_V4="[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}";
  private static final class Holder {private static final ConsumerProviderRuntime INSTANCE=new ConsumerProviderRuntime(System.getenv(),actualJar(),Clock.systemUTC());}
  static ConsumerProviderRuntime current(){return Holder.INSTANCE;}
  private final Map<String,String> configuration;
  private final Clock clock;
  private final String environmentId,operationId,versionId,instanceId,bootId,providerJarSha256;
  private final long startedAt;
  private final byte[] observationKey;
  ConsumerProviderRuntime(Map<String,String> environment,Path jar,Clock clock){
    this.configuration=ConsumerConfiguration.load(environment);this.clock=clock;startedAt=clock.instant().getEpochSecond();bootId=UUID.randomUUID().toString();
    environmentId=environment.get("IDENTITY_PROVIDER_ENVIRONMENT_ID");operationId=environment.get("IDENTITY_PROVIDER_OPERATION_ID");versionId=environment.get("IDENTITY_PROVIDER_VERSION_ID");instanceId=environment.get("IDENTITY_PROVIDER_INSTANCE_ID");
    byte[] key=null;String digest=null;
    try{
      if(environmentId==null||!environmentId.matches("[A-Za-z][A-Za-z0-9_-]{2,63}")||operationId==null||!operationId.matches(UUID_V4)||versionId==null||!versionId.matches(UUID_V4)||instanceId==null||!instanceId.matches("[A-Za-z][A-Za-z0-9_-]{2,63}"))throw new IOException();
      String keyFile=environment.get("IDENTITY_PROVIDER_OBSERVATION_KEY_FILE");if(keyFile==null||keyFile.isBlank())throw new IOException();Path path=Path.of(keyFile);noLinks(path);
      byte[] bytes;try(var input=Files.newInputStream(path)){bytes=input.readNBytes(46);}String encoded=new String(bytes,StandardCharsets.US_ASCII);if(encoded.endsWith("\n"))encoded=encoded.substring(0,encoded.length()-1);if(encoded.endsWith("\r"))encoded=encoded.substring(0,encoded.length()-1);
      key=canonical32(encoded);if(jar==null||!Files.isRegularFile(jar))throw new IOException();noLinks(jar);
      var hash=MessageDigest.getInstance("SHA-256");try(var input=Files.newInputStream(jar)){byte[] buffer=new byte[8192];int count;while((count=input.read(buffer))!=-1)hash.update(buffer,0,count);}digest=HexFormat.of().formatHex(hash.digest());
    }catch(IOException|GeneralSecurityException|IllegalArgumentException failure){if(key!=null)Arrays.fill(key,(byte)0);key=null;digest=null;}
    observationKey=key;providerJarSha256=digest;
  }
  Map<String,String> configuration(){return configuration;}
  Observation observe(Request request){
    if(observationKey==null||providerJarSha256==null)throw new Unavailable();
    long now=clock.instant().getEpochSecond();
    if(request==null||!environmentId.equals(request.environmentId())||!operationId.equals(request.operationId())||request.issuedAt()==null||request.issuedAt()<now-30||request.issuedAt()>now+30)throw new Denied();
    try{canonical32(request.nonce());}catch(IllegalArgumentException failure){throw new Denied();}
    String expected=sign("family-identity-runtime-request-v1",environmentId,operationId,request.nonce(),request.issuedAt().toString());
    if(request.proof()==null||!MessageDigest.isEqual(expected.getBytes(StandardCharsets.US_ASCII),request.proof().getBytes(StandardCharsets.US_ASCII)))throw new Denied();
    boolean phone="true".equals(configuration.get("CONSUMER_PHONE_ENABLED")),wechat="true".equals(configuration.get("CONSUMER_WECHAT_ENABLED")),security="true".equals(configuration.get("CONSUMER_ACCOUNT_SECURITY_ENABLED"));
    String proof=sign("family-identity-runtime-response-v1",environmentId,operationId,versionId,instanceId,bootId,Long.toString(startedAt),Long.toString(now),providerJarSha256,Boolean.toString(phone),Boolean.toString(wechat),Boolean.toString(security),request.nonce(),value("ALIYUN_SMS_SIGN_NAME"),value("ALIYUN_SMS_TEMPLATE_CODE"),value("WECHAT_NATIVE_APP_ID"),value("CONSUMER_OTP_HMAC_KEY"),value("ALIYUN_SMS_ACCESS_KEY_ID"),value("ALIYUN_SMS_ACCESS_KEY_SECRET"),value("ALIYUN_SMS_SECURITY_TOKEN"),value("WECHAT_NATIVE_APP_SECRET"));
    return new Observation(environmentId,operationId,versionId,instanceId,bootId,startedAt,now,providerJarSha256,phone,wechat,security,request.nonce(),proof);
  }
  private String value(String name){return configuration.getOrDefault(name,"");}
  private String sign(String... values){
    try{var mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(observationKey,"HmacSHA256"));for(String value:values){byte[] bytes=value.getBytes(StandardCharsets.UTF_8);mac.update((bytes.length+":").getBytes(StandardCharsets.US_ASCII));mac.update(bytes);}return Base64.getUrlEncoder().withoutPadding().encodeToString(mac.doFinal());}
    catch(GeneralSecurityException failure){throw new Unavailable();}
  }
  private static byte[] canonical32(String encoded){
    if(encoded==null||!encoded.matches("[A-Za-z0-9_-]{43}"))throw new IllegalArgumentException();byte[] result=Base64.getUrlDecoder().decode(encoded);if(result.length!=32||!Base64.getUrlEncoder().withoutPadding().encodeToString(result).equals(encoded))throw new IllegalArgumentException();return result;
  }
  private static void noLinks(Path path)throws IOException {for(Path current=path.toAbsolutePath();current!=null;current=current.getParent()){var attributes=Files.readAttributes(current,java.nio.file.attribute.BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);if(attributes.isSymbolicLink()||attributes.isOther())throw new IOException();}}
  private static Path actualJar(){try{return Path.of(ConsumerProviderRuntime.class.getProtectionDomain().getCodeSource().getLocation().toURI());}catch(Exception failure){return null;}}
  record Request(String environmentId,String operationId,String nonce,Long issuedAt,String proof){}
  record Observation(String environmentId,String operationId,String versionId,String instanceId,String bootId,long startedAt,long observedAt,String providerJarSha256,boolean phoneEnabled,boolean wechatEnabled,boolean accountSecurityEnabled,String nonce,String proof){}
  static final class Denied extends RuntimeException{}static final class Unavailable extends RuntimeException{}
}

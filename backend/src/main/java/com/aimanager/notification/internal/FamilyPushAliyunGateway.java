package com.aimanager.notification.internal;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.GeneralSecurityException;
import java.time.*;
import java.time.temporal.ChronoUnit;
import java.util.*;
import java.util.stream.Collectors;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.springframework.core.env.Environment;

/** Official Aliyun RPC boundary, single configured mainland Android app, no device receipt claim. */
final class FamilyPushAliyunGateway implements FamilyPushGateway {
  private static final URI ENDPOINT=URI.create("https://cloudpush.aliyuncs.com/");
  private final String accessKeyId,accessKeySecret,appKey,channel;
  private final ObjectMapper json;
  private final Clock clock;
  private final HttpClient http;
  FamilyPushAliyunGateway(String accessKeyId,String accessKeySecret,String appKey,String channel,
      ObjectMapper json,Clock clock,HttpClient http) {
    this.accessKeyId=accessKeyId; this.accessKeySecret=accessKeySecret; this.appKey=appKey;
    this.channel=channel; this.json=json; this.clock=clock; this.http=http;
  }
  static FamilyPushAliyunGateway configured(Environment environment,ObjectMapper json,Clock clock) {
    if(!environment.getProperty("manager.family.push.aliyun.enabled",Boolean.class,false)) return null;
    try {
      Path file=Path.of(environment.getRequiredProperty("manager.family.push.aliyun.credentials-file"));
      if(!Files.isRegularFile(file) || Files.size(file)>8192) return null;
      var config=json.readTree(Files.readString(file,StandardCharsets.UTF_8));
      String id=config.path("accessKeyId").asText(), secret=config.path("accessKeySecret").asText(),
          app=config.path("androidAppKey").asText(), channel=config.path("androidChannelId").asText();
      if(!id.matches("[A-Za-z0-9_-]{8,128}") || !secret.matches("[A-Za-z0-9+/=_-]{16,256}")
          || !app.matches("[1-9][0-9]{0,15}") || Long.parseLong(app)>9007199254740991L
          || !channel.matches("[A-Za-z0-9_.-]{1,100}")) return null;
      return new FamilyPushAliyunGateway(id,secret,app,channel,json,clock,
          HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(3)).followRedirects(HttpClient.Redirect.NEVER).build());
    } catch(IOException|IllegalArgumentException|IllegalStateException invalid) { return null; }
  }
  public boolean available() { return true; }
  public Accepted send(Command command) {
    FamilyPushService.uuid(command.deliveryId(),false); FamilyPushService.uuid(command.eventId(),false);
    FamilyPushService.uuid(command.installationId(),true);
    if(command.token()==null || !command.token().matches("[A-Za-z0-9_-]{8,255}")
        || !command.deepLink().equals("aimanager://notifications/"+command.eventId())) throw new Failure("PROVIDER_COMMAND_INVALID",false);
    try {
      var params=new TreeMap<String,String>();
      params.put("Action","Push"); params.put("Version","2016-08-01"); params.put("Format","JSON");
      params.put("AccessKeyId",accessKeyId); params.put("SignatureMethod","HMAC-SHA1"); params.put("SignatureVersion","1.0");
      params.put("SignatureNonce",UUID.randomUUID().toString());
      params.put("Timestamp",clock.instant().truncatedTo(ChronoUnit.SECONDS).toString());
      params.put("RegionId","cn-hangzhou"); params.put("AppKey",appKey);
      params.put("Target","DEVICE"); params.put("TargetValue",command.token());
      params.put("DeviceType","ANDROID"); params.put("PushType","MESSAGE");
      params.put("Title","家庭提醒");
      params.put("Body",json.writeValueAsString(Map.of("eventId",command.eventId(),"deliveryId",command.deliveryId(),"installationId",command.installationId(),"deepLink",command.deepLink())));
      params.put("StoreOffline","false"); params.put("AndroidRemind","false"); params.put("JobKey",command.deliveryId());
      String canonical=query(params);
      Mac signer=Mac.getInstance("HmacSHA1");
      signer.init(new SecretKeySpec((accessKeySecret+"&").getBytes(StandardCharsets.UTF_8),"HmacSHA1"));
      String signature=Base64.getEncoder().encodeToString(signer.doFinal(("POST&%2F&"+encode(canonical)).getBytes(StandardCharsets.UTF_8)));
      var request=HttpRequest.newBuilder(ENDPOINT).timeout(Duration.ofSeconds(6))
          .header("Content-Type","application/x-www-form-urlencoded; charset=UTF-8")
          .POST(HttpRequest.BodyPublishers.ofString(canonical+"&Signature="+encode(signature),StandardCharsets.UTF_8)).build();
      var response=http.send(request,HttpResponse.BodyHandlers.ofInputStream());
      byte[] bytes;
      try(var body=response.body()) { bytes=body.readNBytes(65537); }
      if(bytes.length>65536) throw new Failure("PROVIDER_RESPONSE_INVALID",true);
      if(response.statusCode()==429 || response.statusCode()>=500) throw new Failure("PROVIDER_UNAVAILABLE",true);
      if(response.statusCode()!=200) throw new Failure("PROVIDER_REJECTED",false);
      var result=json.readTree(bytes);
      if(result==null || result.has("Code") || !result.path("MessageId").isTextual()) throw new Failure("PROVIDER_RESPONSE_INVALID",true);
      return new Accepted(result.path("MessageId").asText());
    } catch(InterruptedException interrupted) {
      Thread.currentThread().interrupt(); throw new Failure("PROVIDER_INTERRUPTED",true);
    } catch(IOException unavailable) { throw new Failure("PROVIDER_UNAVAILABLE",true); }
    catch(GeneralSecurityException unavailable) { throw new Failure("PROVIDER_SIGNING_UNAVAILABLE",false); }
  }
  private static String query(SortedMap<String,String> parameters) {
    return parameters.entrySet().stream().map(e->encode(e.getKey())+"="+encode(e.getValue())).collect(Collectors.joining("&"));
  }
  private static String encode(String text) {
    return URLEncoder.encode(text,StandardCharsets.UTF_8).replace("+","%20").replace("*","%2A").replace("%7E","~");
  }
}

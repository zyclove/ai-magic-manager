package com.aimanager.identity;
import java.net.URI;
import java.io.IOException;
import java.net.http.*;
import java.time.Duration;
import java.util.Map;
import java.util.TreeMap;
import com.fasterxml.jackson.databind.ObjectMapper;
public final class WechatNative {
  public interface Transport{AliyunSms.Response send(URI uri)throws IOException;}
  private final String appId,secret;private final Transport transport;
  public WechatNative(String appId,String secret,Transport transport){
    if(appId==null||appId.isBlank()||secret==null||secret.isBlank())throw new IllegalArgumentException("WeChat native OAuth is not configured");
    this.appId=appId;this.secret=secret;this.transport=transport;
  }
  public String exchange(String code)throws IOException{
    if(code==null||!code.matches("[A-Za-z0-9_-]{1,512}"))throw new IllegalArgumentException("Invalid WeChat code");
    URI uri=URI.create("https://api.weixin.qq.com/sns/oauth2/access_token?"+AliyunSms.form(new TreeMap<>(Map.of("appid",appId,"secret",secret,"code",code,"grant_type","authorization_code"))));
    var response=transport.send(uri);
    if(response.status()!=200||response.body().length()>65536)throw new IOException("WeChat code exchange failed");
    var json=new ObjectMapper().readTree(response.body());String openId=json.path("openid").asText();
    if(json.has("errcode")||!openId.matches("[A-Za-z0-9_-]{1,128}")||json.path("access_token").asText().isBlank())throw new IOException("WeChat code exchange rejected");
    return openId;
  }
  public static Transport httpTransport(HttpClient client){
    java.util.Objects.requireNonNull(client);
    return uri->{try{var response=client.send(HttpRequest.newBuilder(uri).timeout(Duration.ofSeconds(5)).GET().build(),HttpResponse.BodyHandlers.ofString());return new AliyunSms.Response(response.statusCode(),response.body());}
      catch(InterruptedException e){Thread.currentThread().interrupt();throw new IOException("WeChat request interrupted");}};
  }
}

package com.aimanager.identity;
import java.io.IOException;
import java.net.URI;
import java.util.Map;
import java.util.TreeMap;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.net.http.*;
import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import com.fasterxml.jackson.databind.ObjectMapper;
public final class AliyunSms implements PhoneOtp.Sender {
  public record Request(URI uri,Map<String,String> headers,String body){}
  public record Response(int status,String body){}
  public interface Transport {Response send(Request request)throws IOException;}
  private final String id,secret,sign,template,securityToken;
  private final Transport transport;
  public AliyunSms(String id,String secret,String sign,String template,String securityToken,Transport transport){
    for(String value:new String[]{id,secret,sign,template})if(value==null||value.isBlank())throw new IllegalArgumentException("SMS provider is not configured");
    this.id=id;this.secret=secret;this.sign=sign;this.template=template;this.securityToken=securityToken;this.transport=transport;
  }
  public void send(String phone,String code)throws IOException{
    phone=PhoneOtp.canonicalPhone(phone);
    if(code==null||!code.matches("[0-9]{6}"))throw new IllegalArgumentException("Invalid code format");
    // SendSms's published RPC metadata declares these fields in the query.
    String query=form(new TreeMap<>(Map.of("PhoneNumbers",phone.substring(3),"SignName",sign,"TemplateCode",template,"TemplateParam","{\"code\":\""+code+"\"}")));
    String body="";
    Map<String,String> headers=new TreeMap<>(Map.of("host","dysmsapi.aliyuncs.com","content-type","application/x-www-form-urlencoded","x-acs-action","SendSms","x-acs-version","2017-05-25","x-acs-date",Instant.now().truncatedTo(ChronoUnit.SECONDS).toString(),"x-acs-signature-nonce",java.util.UUID.randomUUID().toString(),"x-acs-content-sha256",sha256(body)));
    if(securityToken!=null&&!securityToken.isBlank())headers.put("x-acs-security-token",securityToken);
    headers.put("Authorization",authorization(id,secret,"POST","/",query,headers,body));
    Response response=transport.send(new Request(URI.create("https://dysmsapi.aliyuncs.com/?"+query),Map.copyOf(headers),body));
    if(response.status()!=200 || response.body().length()>65536 || !"OK".equals(new ObjectMapper().readTree(response.body()).path("Code").asText()))throw new IOException("SMS provider rejected the request");
  }
  public static String authorization(String id,String secret,String method,String path,String query,Map<String,String> headers,String body){
    var signed=new TreeMap<String,String>();headers.forEach((key,value)->{String lower=key.toLowerCase(java.util.Locale.ROOT);if(lower.startsWith("x-acs-")||lower.equals("host")||lower.equals("content-type"))signed.put(lower,value.strip());});
    StringBuilder canonicalHeaders=new StringBuilder();signed.forEach((key,value)->canonicalHeaders.append(key).append(':').append(value).append('\n'));
    String names=String.join(";",signed.keySet());
    String canonical=String.join("\n",method,path,query,canonicalHeaders.toString(),names,sha256(body));
    String signature=PhoneOtp.hmac(secret.getBytes(StandardCharsets.UTF_8),"ACS3-HMAC-SHA256\n"+sha256(canonical));
    return "ACS3-HMAC-SHA256 Credential="+id+",SignedHeaders="+names+",Signature="+signature;
  }
  static String sha256(String value){try{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));}catch(java.security.GeneralSecurityException e){throw new IllegalStateException(e);}}
  static String encode(String value){return java.net.URLEncoder.encode(value,StandardCharsets.UTF_8).replace("+","%20").replace("*","%2A").replace("%7E","~");}
  static String form(Map<String,String> values){return values.entrySet().stream().map(entry->encode(entry.getKey())+"="+encode(entry.getValue())).collect(java.util.stream.Collectors.joining("&"));}
  public static Transport httpTransport(HttpClient client){
    java.util.Objects.requireNonNull(client);
    return request->ProviderHttpTransport.send(client,()->{
      HttpRequest.Builder builder=HttpRequest.newBuilder(request.uri()).timeout(Duration.ofSeconds(5)).POST(HttpRequest.BodyPublishers.ofString(request.body(),StandardCharsets.UTF_8));
      request.headers().forEach((key,value)->{if(!key.equalsIgnoreCase("host"))builder.header(key,value);});
      return builder.build();
    });
  }
}

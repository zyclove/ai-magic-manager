package com.aimanager.identityproviders.internal;

import static com.aimanager.identityproviders.internal.ProviderReleaseContracts.*;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.*;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.*;
import java.nio.ByteBuffer;
import java.nio.file.*;
import java.security.SecureRandom;
import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.Flow;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/** Active bounded observation against a fixed private inventory, outside database transactions. */
@Component
final class ProviderRuntimeProbe {
  private static final Set<String> HOSTS=Set.of("identity","keycloak","localhost","127.0.0.1","[::1]","::1");
  private static final Set<String> FIELDS=Set.of("environmentId","operationId","versionId","instanceId","bootId","startedAt","observedAt","providerJarSha256","phoneEnabled","wechatEnabled","accountSecurityEnabled","nonce","proof");
  private final ObjectMapper json;private final Clock clock;private final String environment;private final List<Instance> instances;private final HttpClient http;private final int deadline;
  ProviderRuntimeProbe(ObjectMapper mapper,Clock clock,@Value("${manager.identity-providers.environment-id:family-cn-pilot}") String environment,
      @Value("${manager.identity-providers.runtime-inventory-file:}") String inventory,@Value("${manager.identity-providers.runtime-timeout-millis:2000}") int deadline){
    this.json=mapper.copy().enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION).enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);this.clock=clock;this.environment=environment;
    if(deadline<100||deadline>5000)throw new IllegalArgumentException("Invalid identity runtime observation deadline");this.deadline=deadline;
    http=HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).connectTimeout(Duration.ofMillis(deadline)).version(HttpClient.Version.HTTP_1_1).build();
    List<Instance> configured=new ArrayList<>();
    try{
      Path path=Path.of(inventory);ProviderVault.noLinks(path);if(!path.isAbsolute()||!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)||Files.size(path)>16384)throw new IllegalArgumentException();
      JsonNode root=json.readTree(Files.readAllBytes(path));if(!names(root).equals(Set.of("schemaVersion","environmentId","instances"))||!root.path("schemaVersion").isIntegralNumber()||root.path("schemaVersion").intValue()!=1||!environment.equals(root.path("environmentId").textValue())||!root.path("instances").isArray()||root.path("instances").isEmpty()||root.path("instances").size()>8)throw new IllegalArgumentException();
      Set<String> ids=new HashSet<>();Set<URI> urls=new HashSet<>();Set<String> keys=new HashSet<>();
      for(JsonNode value:root.path("instances")){
        if(!names(value).equals(Set.of("instanceId","url","keyFile")))throw new IllegalArgumentException();String id=value.path("instanceId").textValue();
        if(id==null||!id.matches("[A-Za-z][A-Za-z0-9_-]{2,63}")||!ids.add(id))throw new IllegalArgumentException();URI url=url(value.path("url").textValue());
        byte[] key=ProviderRuntimeCrypto.key(value.path("keyFile").textValue());if(!urls.add(url)||!keys.add(Base64.getEncoder().encodeToString(key)))throw new IllegalArgumentException();configured.add(new Instance(id,url,key));
      }
    }catch(Exception unavailable){configured.clear();}
    instances=List.copyOf(configured);
  }
  boolean available(){return !instances.isEmpty();}
  List<RuntimeInstanceView> observe(String operation,String version,String jar,long createdAt,ProviderContracts.Settings settings,Map<String,String> credentials){
    if(!available())return List.of();var results=new ArrayList<RuntimeInstanceView>();
    for(Instance instance:instances)results.add(observe(instance,operation,version,jar,createdAt,settings,credentials));return List.copyOf(results);
  }
  private RuntimeInstanceView observe(Instance instance,String operation,String version,String jar,long createdAt,ProviderContracts.Settings settings,Map<String,String> credentials){
    try{
      long issued=clock.instant().getEpochSecond();byte[] random=new byte[32];new SecureRandom().nextBytes(random);String nonce=Base64.getUrlEncoder().withoutPadding().encodeToString(random);
      String proof=ProviderRuntimeCrypto.mac(instance.key(),List.of("family-identity-runtime-request-v1",environment,operation,nonce,Long.toString(issued)));
      byte[] body=json.writeValueAsBytes(Map.of("environmentId",environment,"operationId",operation,"nonce",nonce,"issuedAt",issued,"proof",proof));
      var request=HttpRequest.newBuilder(instance.url()).timeout(Duration.ofMillis(deadline)).header("Content-Type","application/json").header("Accept","application/json").header("Cache-Control","no-store").POST(HttpRequest.BodyPublishers.ofByteArray(body)).build();
      CompletableFuture<HttpResponse<byte[]>> pending=http.sendAsync(request,response->{if(response.headers().firstValueAsLong("Content-Length").orElse(0)>8192)throw new IllegalArgumentException();return new LimitedBody();});
      HttpResponse<byte[]> response;
      try{response=pending.get(deadline,TimeUnit.MILLISECONDS);}catch(Exception unavailable){pending.cancel(true);if(unavailable instanceof InterruptedException)Thread.currentThread().interrupt();return unavailable(instance);}
      if(response.statusCode()!=200||!response.headers().firstValue("Content-Type").orElse("").split(";",2)[0].strip().equalsIgnoreCase("application/json"))return unavailable(instance);
      JsonNode value=json.readTree(response.body());if(!names(value).equals(FIELDS))return mismatch(instance);
      for(String name:List.of("environmentId","operationId","versionId","instanceId","bootId","providerJarSha256","nonce","proof"))if(!value.path(name).isTextual())return mismatch(instance);
      for(String name:List.of("startedAt","observedAt"))if(!value.path(name).isIntegralNumber()||!value.path(name).canConvertToLong())return mismatch(instance);
      for(String name:List.of("phoneEnabled","wechatEnabled","accountSecurityEnabled"))if(!value.path(name).isBoolean())return mismatch(instance);
      long now=clock.instant().getEpochSecond(),observed=value.path("observedAt").longValue(),started=value.path("startedAt").longValue();
      if(!environment.equals(value.path("environmentId").textValue())||!operation.equals(value.path("operationId").textValue())||!version.equals(value.path("versionId").textValue())||!instance.id().equals(value.path("instanceId").textValue())
          ||!uuid(value.path("bootId").textValue())||!jar.equals(value.path("providerJarSha256").textValue())||!nonce.equals(value.path("nonce").textValue())||observed<issued-1||observed>now+30||observed<now-30||started<createdAt/1000-1||started>observed
          ||value.path("phoneEnabled").booleanValue()||value.path("wechatEnabled").booleanValue()||value.path("accountSecurityEnabled").booleanValue())return mismatch(instance);
      var fields=new ArrayList<>(List.of("family-identity-runtime-response-v1",environment,operation,version,instance.id(),value.path("bootId").textValue(),Long.toString(started),Long.toString(observed),jar,"false","false","false",nonce,settings.smsSignName(),settings.smsTemplateCode(),settings.wechatAppId()));
      for(String name:List.of("CONSUMER_OTP_HMAC_KEY","ALIYUN_SMS_ACCESS_KEY_ID","ALIYUN_SMS_ACCESS_KEY_SECRET","ALIYUN_SMS_SECURITY_TOKEN","WECHAT_NATIVE_APP_SECRET"))fields.add(credentials.get(name));
      if(!ProviderRuntimeCrypto.same(ProviderRuntimeCrypto.mac(instance.key(),fields),value.path("proof").textValue()))return mismatch(instance);
      return new RuntimeInstanceView(instance.id(),"CONFIRMED","RUNTIME_CONFIGURATION_CONFIRMED",observed*1000);
    }catch(Exception unavailable){return unavailable(instance);}
  }
  private static RuntimeInstanceView mismatch(Instance i){return new RuntimeInstanceView(i.id(),"MISMATCH","RUNTIME_CONFIGURATION_MISMATCH",null);}
  private static RuntimeInstanceView unavailable(Instance i){return new RuntimeInstanceView(i.id(),"UNAVAILABLE","RUNTIME_OBSERVATION_UNAVAILABLE",null);}
  private static Set<String> names(JsonNode value){var result=new HashSet<String>();if(value!=null&&value.isObject())value.fieldNames().forEachRemaining(result::add);return result;}
  private static boolean uuid(String value){return value!=null&&value.matches("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");}
  private static URI url(String value){
    URI uri=URI.create(value);String host=uri.getHost();boolean internal="http".equals(uri.getScheme())&&host!=null&&HOSTS.contains(host.toLowerCase(Locale.ROOT));
    if((!"https".equals(uri.getScheme())&&!internal)||host==null||uri.getUserInfo()!=null||uri.getQuery()!=null||uri.getFragment()!=null||uri.getPort()==0||uri.getPort()>65535||uri.getPath()==null
        ||!uri.getPath().endsWith("/consumer-account/runtime-observation")||!uri.getPath().equals(uri.getRawPath())||!uri.normalize().equals(uri))throw new IllegalArgumentException();return uri;
  }
  private record Instance(String id,URI url,byte[] key) {}
  private static final class LimitedBody implements HttpResponse.BodySubscriber<byte[]> {
    private final ByteArrayOutputStream body=new ByteArrayOutputStream();private final CompletableFuture<byte[]> future=new CompletableFuture<>();private Flow.Subscription subscription;
    @Override public CompletionStage<byte[]> getBody(){return future;}
    @Override public void onSubscribe(Flow.Subscription subscription){this.subscription=subscription;subscription.request(1);}
    @Override public void onNext(List<ByteBuffer> buffers){for(ByteBuffer buffer:buffers){if(buffer.remaining()>8192-body.size()){subscription.cancel();future.completeExceptionally(new IllegalArgumentException("Runtime response too large"));return;}byte[] bytes=new byte[buffer.remaining()];buffer.get(bytes);body.writeBytes(bytes);}subscription.request(1);}
    @Override public void onError(Throwable failure){future.completeExceptionally(failure);}
    @Override public void onComplete(){future.complete(body.toByteArray());}
  }
}

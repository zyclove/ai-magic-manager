package com.aimanager.identityproviders.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import com.fasterxml.jackson.databind.*;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.DirectDecrypter;
import com.nimbusds.jose.jwk.*;
import com.sun.net.httpserver.HttpServer;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.*;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;

/** Production repository and actual HTTP/SQL. The runtime responder and JWT/MFA remain fixtures. */
@EnabledIfSystemProperty(named="guardian.release.dart.command",matches=".+")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,properties={"server.address=127.0.0.1",
    "spring.datasource.url=jdbc:h2:mem:provider-release-guardian-http;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE","spring.datasource.username=sa","spring.datasource.password=",
    "manager.exports.worker.enabled=false","manager.report-jobs.worker.enabled=false","manager.diagnostic-packages.worker.enabled=false",
    "manager.consumer-security.enabled=false","manager.identity-providers.environment-id=isolated-release-http"})
class ProviderReleaseGuardianHttpTest {
  static final String ENV="isolated-release-http";static final ObjectMapper JSON=new ObjectMapper();
  static final byte[] VAULT=new byte[32],OBSERVATION=new byte[32],EXECUTOR=new byte[32];
  static final Path DIR=directory();static final HttpServer RUNTIME=runtime();static final String BOOT=UUID.randomUUID().toString();
  static volatile JdbcTemplate fixtureDatabase;
  static Path directory(){try{
    Arrays.fill(VAULT,(byte)17);Arrays.fill(OBSERVATION,(byte)39);Arrays.fill(EXECUTOR,(byte)51);
    Path directory=Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")),"release-guardian-http-");
    Files.writeString(directory.resolve("ring.json"),new JWKSet(new OctetSequenceKey.Builder(VAULT).keyID("guardian-release-http").keyUse(KeyUse.ENCRYPTION).algorithm(JWEAlgorithm.DIR).build()).toString(false));
    Files.writeString(directory.resolve("observation.key"),Base64.getUrlEncoder().withoutPadding().encodeToString(OBSERVATION));Files.writeString(directory.resolve("executor.key"),Base64.getUrlEncoder().withoutPadding().encodeToString(EXECUTOR));
    Files.createDirectory(directory.resolve("releases"));return directory;
  }catch(Exception unavailable){throw new ExceptionInInitializerError(unavailable);}}
  static HttpServer runtime(){try{
    HttpServer server=HttpServer.create(new java.net.InetSocketAddress("127.0.0.1",0),0);
    server.createContext("/identity/realms/ai-manager/consumer-account/runtime-observation",exchange->{
      try{
        JsonNode request=JSON.readTree(exchange.getRequestBody().readAllBytes());String operation=request.path("operationId").asText(),nonce=request.path("nonce").asText();long issued=request.path("issuedAt").asLong();
        if(!ProviderRuntimeCrypto.same(ProviderRuntimeCrypto.mac(OBSERVATION,List.of("family-identity-runtime-request-v1",ENV,operation,nonce,Long.toString(issued))),request.path("proof").asText())){exchange.sendResponseHeaders(401,-1);return;}
        var row=fixtureDatabase.queryForMap("SELECT o.version_id,o.provider_jar_sha256,v.settings_json,v.protected_payload FROM identity_provider_release_operations o JOIN identity_provider_versions v ON v.id=o.version_id WHERE o.id=?",operation);
        var encrypted=JWEObject.parse((String)row.get("protected_payload"));encrypted.decrypt(new DirectDecrypter(VAULT));JsonNode credentials=JSON.readTree(encrypted.getPayload().toBytes()),settings=JSON.readTree((String)row.get("settings_json"));
        long now=Instant.now().getEpochSecond();String version=String.valueOf(row.get("version_id")),jar=String.valueOf(row.get("provider_jar_sha256"));
        var fields=new ArrayList<>(List.of("family-identity-runtime-response-v1",ENV,operation,version,"identity-1",BOOT,Long.toString(now),Long.toString(now),jar,"false","false","false",nonce,settings.path("smsSignName").asText(),settings.path("smsTemplateCode").asText(),settings.path("wechatAppId").asText()));
        for(String name:List.of("CONSUMER_OTP_HMAC_KEY","ALIYUN_SMS_ACCESS_KEY_ID","ALIYUN_SMS_ACCESS_KEY_SECRET","ALIYUN_SMS_SECURITY_TOKEN","WECHAT_NATIVE_APP_SECRET"))fields.add(credentials.path(name).asText());
        Map<String,Object> response=new LinkedHashMap<>();response.put("environmentId",ENV);response.put("operationId",operation);response.put("versionId",version);response.put("instanceId","identity-1");response.put("bootId",BOOT);response.put("startedAt",now);response.put("observedAt",now);response.put("providerJarSha256",jar);response.put("phoneEnabled",false);response.put("wechatEnabled",false);response.put("accountSecurityEnabled",false);response.put("nonce",nonce);response.put("proof",ProviderRuntimeCrypto.mac(OBSERVATION,fields));
        byte[] bytes=JSON.writeValueAsBytes(response);exchange.getResponseHeaders().add("Content-Type","application/json");exchange.sendResponseHeaders(200,bytes.length);exchange.getResponseBody().write(bytes);
      }catch(Exception failure){exchange.sendResponseHeaders(503,-1);}finally{exchange.close();}
    });server.start();return server;
  }catch(Exception failure){throw new ExceptionInInitializerError(failure);}}
  @DynamicPropertySource static void properties(DynamicPropertyRegistry p)throws Exception{
    Files.writeString(DIR.resolve("inventory.json"),JSON.writeValueAsString(Map.of("schemaVersion",1,"environmentId",ENV,"instances",List.of(Map.of("instanceId","identity-1","url","http://127.0.0.1:"+RUNTIME.getAddress().getPort()+"/identity/realms/ai-manager/consumer-account/runtime-observation","keyFile",DIR.resolve("observation.key").toString())))));
    p.add("manager.identity-providers.key-file",()->DIR.resolve("ring.json").toString());p.add("manager.identity-providers.release-directory",()->DIR.resolve("releases").toString());p.add("manager.identity-providers.executor-key-file",()->DIR.resolve("executor.key").toString());p.add("manager.identity-providers.runtime-inventory-file",()->DIR.resolve("inventory.json").toString());
  }
  @LocalServerPort int port;@Autowired JdbcTemplate db;@MockitoBean JwtDecoder decoder;
  @Test void actualProductionRepositoryPublishesRecoversChecksCancelsAndRollsBack()throws Exception{
    fixtureDatabase=db;Map<String,String> tokens=Map.of("ADMIN","release-admin-"+UUID.randomUUID(),"PUBLISHER","release-publisher-"+UUID.randomUUID(),"ROLLBACK","release-rollback-"+UUID.randomUUID(),"READER","release-reader-"+UUID.randomUUID(),"WEAK","release-weak-"+UUID.randomUUID());
    when(decoder.decode(anyString())).thenAnswer(call->{
      String token=call.getArgument(0);String kind=tokens.entrySet().stream().filter(e->e.getValue().equals(token)).map(Map.Entry::getKey).findFirst().orElseThrow(()->new BadJwtException("Not an explicit release fixture"));Instant now=Instant.now();
      String scope=switch(kind){case "READER"->"identity-config:read";case "PUBLISHER"->"identity-config:read identity-config:test identity-config:publish";case "ROLLBACK"->"identity-config:read identity-config:test identity-config:rollback";default->"identity-config:read identity-config:manage identity-config:test identity-config:publish identity-config:rollback";};
      return Jwt.withTokenValue(token).header("alg","fixture").subject("release-"+kind.toLowerCase(Locale.ROOT)).issuedAt(now).expiresAt(now.plusSeconds(300)).claim("auth_time",now.getEpochSecond()).claim("amr","WEAK".equals(kind)?List.of("pwd"):List.of("pwd","otp")).claim("scope",scope).build();
    });
    Path guardian=Path.of(System.getProperty("guardian.release.package")).toAbsolutePath(),log=Path.of("target/guardian-release-http.log").toAbsolutePath();
    var builder=new ProcessBuilder(System.getProperty("guardian.release.dart.command"),"--packages="+guardian.resolve(".dart_tool/package_config.json"),guardian.resolve("tool/verify_identity_provider_release_http.dart").toString()).directory(guardian.toFile()).redirectErrorStream(true).redirectOutput(log.toFile());
    builder.environment().put("GUARDIAN_RELEASE_HTTP_BASE","http://127.0.0.1:"+port+"/api/v1");builder.environment().put("GUARDIAN_RELEASE_ENVIRONMENT",ENV);builder.environment().put("GUARDIAN_RELEASE_EXECUTOR_KEY",Base64.getUrlEncoder().withoutPadding().encodeToString(EXECUTOR));
    tokens.forEach((name,value)->builder.environment().put("GUARDIAN_RELEASE_"+name+"_TOKEN",value));
    var process=builder.start();
    try{
      assertThat(process.waitFor(120,TimeUnit.SECONDS)).as("Production release HTTP check is bounded").isTrue();assertThat(process.exitValue()).as("See private release HTTP check log: %s",log).isZero();
      assertThat(Files.readString(log)).contains("Controlled release production HTTP checks passed:");
      assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_release_operations WHERE state='APPLIED_CLOSED'",Integer.class)).isGreaterThanOrEqualTo(2);
      assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_release_operations WHERE state='CANCELLED'",Integer.class)).isGreaterThanOrEqualTo(1);
    }finally{if(process.isAlive()){process.destroyForcibly();process.waitFor(10,TimeUnit.SECONDS);}RUNTIME.stop(0);fixtureDatabase=null;}
  }
}

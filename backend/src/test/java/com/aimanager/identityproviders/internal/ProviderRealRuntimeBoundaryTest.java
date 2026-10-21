package com.aimanager.identityproviders.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import com.fasterxml.jackson.databind.*;
import com.nimbusds.jose.JWEAlgorithm;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

/** Opt-in handshake with a newly isolated packaged Keycloak. Never points to existing identity. */
@EnabledIfSystemProperty(named="provider.runtime.boundary",matches="true")
@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:provider-real-runtime-boundary;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa","spring.datasource.password=","manager.exports.worker.enabled=false","manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false","manager.identity-providers.environment-id=isolated-real-boundary","manager.identity-providers.runtime-timeout-millis=5000"})
@AutoConfigureMockMvc
class ProviderRealRuntimeBoundaryTest {
  static final ObjectMapper JSON=new ObjectMapper();static final String ROOT="/api/v1/platform/identity-providers",ENV="isolated-real-boundary";
  static Path directory;
  @DynamicPropertySource static void properties(DynamicPropertyRegistry p)throws Exception{
    Path handoff=Path.of(System.getProperty("provider.runtime.handoff")).toAbsolutePath().normalize();
    Path task=Path.of(System.getProperty("java.io.tmpdir")).toAbsolutePath().normalize().getParent();
    if(!handoff.startsWith(task.getParent())||Files.isSymbolicLink(handoff))throw new IllegalStateException("Boundary handoff must remain in this task");
    directory=Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")),"real-runtime-boundary-");byte[] key=new byte[32];new java.security.SecureRandom().nextBytes(key);
    Files.writeString(directory.resolve("ring.json"),new JWKSet(new OctetSequenceKey.Builder(key).keyID("runtime-boundary").keyUse(KeyUse.ENCRYPTION).algorithm(JWEAlgorithm.DIR).build()).toString(false));Files.createDirectory(directory.resolve("releases"));
    byte[] executor=new byte[32];new java.security.SecureRandom().nextBytes(executor);Files.writeString(directory.resolve("executor.key"),Base64.getUrlEncoder().withoutPadding().encodeToString(executor));
    String url=System.getProperty("provider.runtime.url"),observationKey=System.getProperty("provider.runtime.key-file");
    if(url==null||!url.matches("http://127\\.0\\.0\\.1:[0-9]{4,5}/identity/realms/ai-manager/consumer-account/runtime-observation"))throw new IllegalStateException("Boundary only accepts new loopback runtime");
    Files.writeString(directory.resolve("inventory.json"),JSON.writeValueAsString(Map.of("schemaVersion",1,"environmentId",ENV,"instances",List.of(Map.of("instanceId","identity-1","url",url,"keyFile",observationKey)))));
    p.add("manager.identity-providers.key-file",()->directory.resolve("ring.json").toString());p.add("manager.identity-providers.release-directory",()->directory.resolve("releases").toString());
    p.add("manager.identity-providers.executor-key-file",()->directory.resolve("executor.key").toString());p.add("manager.identity-providers.runtime-inventory-file",()->directory.resolve("inventory.json").toString());
  }
  @Autowired MockMvc mvc;@Autowired ProviderReleaseService releases;@MockitoBean JwtDecoder decoder;
  JsonNode callAdmin(String path,Object body,String scope)throws Exception{return JSON.readTree(mvc.perform(post(ROOT+path).with(jwt().jwt(j->j.subject("isolated-boundary-admin").claim("amr",List.of("pwd","otp")).claim("auth_time",Instant.now())).authorities(new SimpleGrantedAuthority("SCOPE_identity-config:"+scope)))
      .contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(body))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());}
  @Test void backendPublishesAndRollsBackActualPackagedRuntime()throws Exception{
    String jar=System.getProperty("provider.runtime.jar-sha256");assertThat(jar).matches("[a-f0-9]{64}");
    String first=UUID.randomUUID().toString(),firstPrep=UUID.randomUUID().toString();
    createTarget(first,firstPrep,0,Map.of("smsAccessKeyId","LTAIProviderFixture123456","smsAccessKeySecret","ProviderFixtureSecret123456789","wechatAppSecret","abcdef0123456789abcdef0123456789"));
    confirmStage(first,firstPrep,jar,"PUBLISH","",0);
    String second=UUID.randomUUID().toString(),secondPrep=UUID.randomUUID().toString();
    createTarget(second,secondPrep,1,Map.of("smsAccessKeySecret","RotatedProviderFixtureSecret123456789"));
    confirmStage(second,secondPrep,jar,"PUBLISH","-b",releases.status().runtimeRevision());
    assertThat(releases.status().rollbackTargets().stream().anyMatch(t->t.versionId().equals(first))).isTrue();
    confirmStage(first,firstPrep,jar,"ROLLBACK","-rollback",releases.status().runtimeRevision());
    assertThat(releases.status().confirmedOperation().versionId()).isEqualTo(first);
    assertThat(releases.status().confirmedOperation().kind()).isEqualTo("ROLLBACK");
    assertThat(releases.status().salesAllowed()).isFalse();
  }
  void createTarget(String version,String preparation,long base,Map<String,String> replacements)throws Exception{
    callAdmin("/versions",Map.of("id",version,"baseVersion",base,"settings",Map.of("smsSignName","家庭管家","smsTemplateCode","SMS_123456","wechatAppId","wx0123456789abcdef","parentPackageName","com.aimanager.parent","parentCertificateSha256","a".repeat(64)),"replacements",replacements),"manage");
    callAdmin("/versions/"+version+"/release-preparations",Map.of("id",preparation),"manage");
  }
  void confirmStage(String version,String preparation,String jar,String kind,String suffix,long revision)throws Exception{
    String operation=UUID.randomUUID().toString();
    callAdmin("/release-operations",Map.of("id",operation,"kind",kind,"versionId",version,"preparationId",preparation,"expectedRuntimeRevision",revision,"providerJarSha256",jar,"parentApkSha256","c".repeat(64)),"ROLLBACK".equals(kind)?"rollback":"publish");
    byte[] key=ProviderRuntimeCrypto.key(directory.resolve("executor.key").toString());String claim=UUID.randomUUID().toString();
    for(String action:List.of("CLAIM","BEGIN")){
      byte[] bytes=new byte[32];new java.security.SecureRandom().nextBytes(bytes);String nonce=Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);long time=Instant.now().getEpochSecond();
      String proof=ProviderRuntimeCrypto.mac(key,List.of("family-identity-executor-request-v1",action,ENV,operation,claim,nonce,Long.toString(time),""));
      releases.machine(action,new ProviderReleaseContracts.ExecutorInput(ENV,operation,claim,nonce,time,proof,null));
    }
    Path handoff=Path.of(System.getProperty("provider.runtime.handoff"));Files.createDirectories(handoff);
    Files.writeString(handoff.resolve("handoff"+suffix+".json"),JSON.writeValueAsString(Map.of("environmentId",ENV,"versionId",version,"operationId",operation,"preparationId",preparation,"providerJarSha256",jar,
        "releaseBundlePath",directory.resolve("releases").resolve(preparation+".json").toString(),"vaultKeyFile",directory.resolve("ring.json").toString(),"instanceId","identity-1")),StandardOpenOption.CREATE_NEW);
    long until=System.nanoTime()+java.util.concurrent.TimeUnit.MINUTES.toNanos(4);
    while(!Files.isRegularFile(handoff.resolve("runtime-ready"+suffix+".json"))&&System.nanoTime()<until)Thread.sleep(500);
    assertThat(Files.isRegularFile(handoff.resolve("runtime-ready"+suffix+".json"))).as("Isolated runtime handshake is bounded: %s",suffix).isTrue();
    JsonNode result=callAdmin("/release-operations/"+operation+"/runtime-checks",Map.of("id",UUID.randomUUID().toString()),"test");
    Files.writeString(handoff.resolve("backend-observation"+suffix+".json"),result.toPrettyString(),StandardOpenOption.CREATE_NEW);
    assertThat(result.path("state").asText()).isEqualTo("CONFIRMED");assertThat(result.path("instances").size()).isEqualTo(1);assertThat(result.path("salesAllowed").asBoolean()).isFalse();
    assertThat(releases.status().confirmedOperation().id()).isEqualTo(operation);
  }
}

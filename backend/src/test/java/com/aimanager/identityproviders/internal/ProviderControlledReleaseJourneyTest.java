package com.aimanager.identityproviders.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.*;
import com.nimbusds.jose.*;
import com.nimbusds.jose.crypto.DirectDecrypter;
import com.nimbusds.jose.jwk.*;
import com.sun.net.httpserver.HttpServer;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import org.junit.jupiter.api.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** Real SQL and bounded loopback HTTP. Supplier/realm authentication remain explicit fixtures. */
@SpringBootTest(properties={"spring.datasource.url=${IDENTITY_PROVIDER_RELEASE_TEST_DATABASE_URL:jdbc:h2:mem:provider-controlled-release;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
    "spring.datasource.username=${IDENTITY_PROVIDER_RELEASE_TEST_DATABASE_USERNAME:sa}","spring.datasource.password=${IDENTITY_PROVIDER_RELEASE_TEST_DATABASE_PASSWORD:}","manager.exports.worker.enabled=false",
    "manager.report-jobs.worker.enabled=false","manager.diagnostic-packages.worker.enabled=false",
    "manager.identity-providers.environment-id=release-fixture","manager.identity-providers.runtime-timeout-millis=5000"})
@AutoConfigureMockMvc
class ProviderControlledReleaseJourneyTest {
  static final String ROOT="/api/v1/platform/identity-providers",MACHINE="/api/v1/platform/identity-provider-executor";
  static final String ENV="release-fixture",JAR="b".repeat(64),APK="c".repeat(64);
  static final ObjectMapper JSON=new ObjectMapper();
  static final byte[] VAULT_KEY=new byte[32],OBS_KEY=new byte[32],EXEC_KEY=new byte[32];
  static final Path DIR=directory();
  static final HttpServer SERVER=server();
  static volatile Map<String,Object> observed=Map.of();
  static volatile Map<String,String> loaded=Map.of();
  static volatile String mode="unavailable";
  static final java.util.concurrent.atomic.AtomicInteger CALLS=new java.util.concurrent.atomic.AtomicInteger();
  static volatile CountDownLatch probeEntered=new CountDownLatch(1),probeRelease=new CountDownLatch(1);
  static final java.util.concurrent.atomic.AtomicBoolean RESPONSE_WRITTEN=new java.util.concurrent.atomic.AtomicBoolean();
  static Path directory(){try{
    Arrays.fill(VAULT_KEY,(byte)31);Arrays.fill(OBS_KEY,(byte)47);Arrays.fill(EXEC_KEY,(byte)59);
    Path dir=Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")),"provider-release-");
    var key=new OctetSequenceKey.Builder(VAULT_KEY).keyID("release-vault").keyUse(KeyUse.ENCRYPTION).algorithm(JWEAlgorithm.DIR).build();
    Files.writeString(dir.resolve("ring.json"),new JWKSet(key).toString(false));Files.createDirectory(dir.resolve("releases"));
    Files.writeString(dir.resolve("observation.key"),b64(OBS_KEY));Files.writeString(dir.resolve("executor.key"),b64(EXEC_KEY));return dir;
  }catch(Exception failure){throw new ExceptionInInitializerError(failure);}}
  static HttpServer server(){try{
    HttpServer server=HttpServer.create(new java.net.InetSocketAddress("127.0.0.1",0),0);
    server.createContext("/identity/realms/ai-manager/consumer-account/runtime-observation",exchange->{
      CALLS.incrementAndGet();try{
        JsonNode request=JSON.readTree(exchange.getRequestBody().readAllBytes());
        String nonce=request.path("nonce").asText();long issued=request.path("issuedAt").asLong();
        String expected=mac(OBS_KEY,List.of("family-identity-runtime-request-v1",ENV,request.path("operationId").asText(),nonce,Long.toString(issued)));
        if(!expected.equals(request.path("proof").asText())||"unavailable".equals(mode)){exchange.sendResponseHeaders(503,-1);return;}
        if("latched".equals(mode)){probeEntered.countDown();if(!probeRelease.await(5,TimeUnit.SECONDS)){exchange.sendResponseHeaders(503,-1);return;}}
        var response=new LinkedHashMap<>(observed);response.put("nonce",nonce);response.put("observedAt",Instant.now().getEpochSecond());
        if("wrong-version".equals(mode))response.put("versionId",UUID.randomUUID().toString());
        if("enabled".equals(mode))response.put("phoneEnabled",true);
        if("old-boot".equals(mode))response.put("startedAt",1L);
        if("wrong-jar".equals(mode))response.put("providerJarSha256","f".repeat(64));
        if("old-time".equals(mode))response.put("observedAt",1L);
        var fields=new ArrayList<String>(List.of("family-identity-runtime-response-v1",ENV,String.valueOf(response.get("operationId")),String.valueOf(response.get("versionId")),
            "identity-1",String.valueOf(response.get("bootId")),String.valueOf(response.get("startedAt")),String.valueOf(response.get("observedAt")),
            String.valueOf(response.get("providerJarSha256")),String.valueOf(response.get("phoneEnabled")),String.valueOf(response.get("wechatEnabled")),
            String.valueOf(response.get("accountSecurityEnabled")),nonce));
        for(String name:List.of("smsSignName","smsTemplateCode","wechatAppId","CONSUMER_OTP_HMAC_KEY","ALIYUN_SMS_ACCESS_KEY_ID","ALIYUN_SMS_ACCESS_KEY_SECRET","ALIYUN_SMS_SECURITY_TOKEN","WECHAT_NATIVE_APP_SECRET"))
          fields.add("wrong-secret".equals(mode)&&name.equals("ALIYUN_SMS_ACCESS_KEY_SECRET")?"other-loaded-secret":loaded.get(name));
        response.put("proof",mac("wrong-key".equals(mode)?EXEC_KEY:OBS_KEY,fields));
        if("extra-field".equals(mode))response.put("rawSecret","must-reject");
        byte[] body=JSON.writeValueAsBytes(response);exchange.getResponseHeaders().add("Content-Type","application/json");exchange.sendResponseHeaders(200,body.length);exchange.getResponseBody().write(body);RESPONSE_WRITTEN.set(true);
      }catch(Exception failure){exchange.sendResponseHeaders(500,-1);}finally{exchange.close();}
    });server.start();return server;
  }catch(Exception failure){throw new ExceptionInInitializerError(failure);}}
  @DynamicPropertySource static void properties(DynamicPropertyRegistry p)throws Exception{
    String database=System.getenv("IDENTITY_PROVIDER_RELEASE_TEST_DATABASE_URL");
    if(database!=null&&!database.matches("jdbc:mysql://127\\.0\\.0\\.1:[0-9]{1,5}/provider_release_it_[a-f0-9]{32}\\?connectionTimeZone=UTC&useSSL=false&allowPublicKeyRetrieval=true"))throw new IllegalStateException("Only disposable loopback provider-release SQL is allowed");
    Files.writeString(DIR.resolve("inventory.json"),JSON.writeValueAsString(Map.of("schemaVersion",1,"environmentId",ENV,"instances",List.of(Map.of(
        "instanceId","identity-1","url","http://127.0.0.1:"+SERVER.getAddress().getPort()+"/identity/realms/ai-manager/consumer-account/runtime-observation","keyFile",DIR.resolve("observation.key").toString())))));
    p.add("manager.identity-providers.key-file",()->DIR.resolve("ring.json").toString());p.add("manager.identity-providers.release-directory",()->DIR.resolve("releases").toString());
    p.add("manager.identity-providers.executor-key-file",()->DIR.resolve("executor.key").toString());p.add("manager.identity-providers.runtime-inventory-file",()->DIR.resolve("inventory.json").toString());
  }
  @Autowired MockMvc mvc;@Autowired JdbcTemplate db;@MockitoBean JwtDecoder decoder;
  @BeforeEach void reset(){
    if(Boolean.TRUE.equals(db.queryForObject("SELECT COUNT(*)>0 FROM information_schema.tables WHERE table_name='identity_provider_runtime_heads'",Boolean.class)))
      for(String table:List.of("identity_provider_runtime_checks","identity_provider_executor_nonces","identity_provider_runtime_heads","identity_provider_release_operations"))db.update("DELETE FROM "+table);
    mode="unavailable";CALLS.set(0);probeEntered=new CountDownLatch(1);probeRelease=new CountDownLatch(1);RESPONSE_WRITTEN.set(false);
  }
  @AfterAll static void stop(){SERVER.stop(0);}
  RequestPostProcessor actor(String... scopes){return jwt().jwt(j->j.subject("release-admin").claim("amr",List.of("pwd","otp")).claim("auth_time",Instant.now()))
      .authorities(Arrays.stream(scopes).map(s->new SimpleGrantedAuthority("SCOPE_identity-config:"+s)).toArray(SimpleGrantedAuthority[]::new));}
  JsonNode read(String path)throws Exception{return JSON.readTree(mvc.perform(get(ROOT+path).with(actor("read"))).andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store")).andReturn().getResponse().getContentAsString());}
  JsonNode postAdmin(String path,Object input,String scope)throws Exception{return JSON.readTree(mvc.perform(post(ROOT+path).with(actor(scope)).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(input))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());}
  Map<String,Object> target()throws Exception{
    long base=read("/status").path("latestVersion").asLong();String version=UUID.randomUUID().toString(),prep=UUID.randomUUID().toString();
    postAdmin("/versions",Map.of("id",version,"baseVersion",base,"settings",Map.of("smsSignName","家庭管家","smsTemplateCode","SMS_123456","wechatAppId","wx0123456789abcdef","parentPackageName","com.aimanager.parent","parentCertificateSha256","a".repeat(64)),
        "replacements",Map.of("smsAccessKeyId","LTAIProviderFixture123456","smsAccessKeySecret","ProviderFixtureSecret123456789","wechatAppSecret","abcdef0123456789abcdef0123456789")),"manage");
    postAdmin("/versions/"+version+"/release-preparations",Map.of("id",prep),"manage");
    return new LinkedHashMap<>(Map.of("id",UUID.randomUUID().toString(),"kind","PUBLISH","versionId",version,"preparationId",prep,"expectedRuntimeRevision",read("/release-status").path("runtimeRevision").asLong(),"providerJarSha256",JAR,"parentApkSha256",APK));
  }
  JsonNode start(Map<String,Object> target)throws Exception{return postAdmin("/release-operations",target,"PUBLISH".equals(target.get("kind"))?"publish":"rollback");}
  Map<String,Object> machine(String action,String op,String claim,String outcome)throws Exception{
    String nonce=b64(random());long now=Instant.now().getEpochSecond();var body=new LinkedHashMap<String,Object>();body.put("environmentId",ENV);body.put("operationId",op);body.put("claimId",claim);body.put("nonce",nonce);body.put("issuedAt",now);
    if(outcome!=null)body.put("outcome",outcome);body.put("proof",mac(EXEC_KEY,List.of("family-identity-executor-request-v1",action,ENV,op,claim,nonce,Long.toString(now),outcome==null?"":outcome)));return body;
  }
  JsonNode machinePost(String path,Map<String,Object> input)throws Exception{return JSON.readTree(mvc.perform(post(MACHINE+path).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(input))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());}
  String claim(JsonNode op)throws Exception{String id=UUID.randomUUID().toString();machinePost("/claims",machine("CLAIM",op.path("id").asText(),id,null));return id;}
  void begin(JsonNode op,String claim)throws Exception{assertThat(machinePost("/claims/begin",machine("BEGIN",op.path("id").asText(),claim,null)).path("executionAllowed").asBoolean()).isTrue();}
  void load(Map<String,Object> target)throws Exception{
    String version=(String)target.get("versionId");var jwe=JWEObject.parse(db.queryForObject("SELECT protected_payload FROM identity_provider_versions WHERE id=?",String.class,version));jwe.decrypt(new DirectDecrypter(VAULT_KEY));
    var actual=new LinkedHashMap<String,String>();JSON.readTree(jwe.getPayload().toBytes()).fields().forEachRemaining(e->actual.put(e.getKey(),e.getValue().asText()));
    actual.put("smsSignName","家庭管家");actual.put("smsTemplateCode","SMS_123456");actual.put("wechatAppId","wx0123456789abcdef");loaded=Map.copyOf(actual);
    observed=Map.of("environmentId",ENV,"operationId",target.get("id"),"versionId",version,"instanceId","identity-1","bootId",UUID.randomUUID().toString(),"startedAt",Instant.now().getEpochSecond(),"providerJarSha256",JAR,"phoneEnabled",false,"wechatEnabled",false,"accountSecurityEnabled",false);mode="matching";
  }
  JsonNode check(JsonNode op,String id)throws Exception{return postAdmin("/release-operations/"+op.path("id").asText()+"/runtime-checks",Map.of("id",id),"test");}
  JsonNode confirm(Map<String,Object> target)throws Exception{JsonNode op=start(target);String claim=claim(op);begin(op,claim);load(target);return check(op,UUID.randomUUID().toString());}

  @Test void dedicatedReleasePrivilegesAndRecentMfaPrecedeStateLookup()throws Exception{
    mvc.perform(get(ROOT+"/release-status")).andExpect(status().isUnauthorized());
    for(String scope:List.of("read","manage","test"))mvc.perform(post(ROOT+"/release-operations").with(actor(scope)).contentType(MediaType.APPLICATION_JSON).content("{}")).andExpect(status().isForbidden());
    mvc.perform(get(ROOT+"/release-operations/"+UUID.randomUUID()).with(jwt().jwt(j->j.subject("stale").claim("amr",List.of("mfa")).claim("auth_time",Instant.now().minusSeconds(400))).authorities(new SimpleGrantedAuthority("SCOPE_identity-config:read")))).andExpect(status().isUnauthorized());
  }
  @Test void releaseFreezesPreparedTargetAndSameIdRecoversWithoutDuplicateApproval()throws Exception{
    var input=target();JsonNode first=start(input);assertThat(first.path("state").asText()).isEqualTo("WAITING_EXECUTOR");assertThat(start(input)).isEqualTo(first);
    assertThat(read("/release-operations/"+input.get("id"))).isEqualTo(first);
    input.put("providerJarSha256","d".repeat(64));mvc.perform(post(ROOT+"/release-operations").with(actor("publish")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(input))).andExpect(status().isConflict());
    assertThat(first.toString()).doesNotContain(DIR.toString(),"proof","protectedPayload","secretHash");
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_release_operations",Integer.class)).isEqualTo(1);
  }
  @Test void preparedVersionMismatchAndNonV4AndUnknownFieldsAreRejected()throws Exception{
    var first=target();var second=target();first.put("preparationId",second.get("preparationId"));
    mvc.perform(post(ROOT+"/release-operations").with(actor("publish")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(first))).andExpect(status().isConflict());
    first.put("preparationId",second.get("preparationId"));first.put("versionId",second.get("versionId"));first.put("id","00000000-0000-0000-0000-000000000000");
    mvc.perform(post(ROOT+"/release-operations").with(actor("publish")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(first))).andExpect(status().isBadRequest());
    first.put("id",UUID.randomUUID().toString());first.put("applied",true);mvc.perform(post(ROOT+"/release-operations").with(actor("publish")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(first))).andExpect(status().isBadRequest());
  }
  @Test void machineClaimAndBeginAreSeparateAndBeginAllowsExecutionExactlyOnce()throws Exception{
    JsonNode op=start(target());String claim=claim(op);var query=machinePost("/claims/query",machine("QUERY",op.path("id").asText(),claim,null));assertThat(query.path("executionAllowed").asBoolean()).isFalse();
    begin(op,claim);assertThat(machinePost("/claims/begin",machine("BEGIN",op.path("id").asText(),claim,null)).path("executionAllowed").asBoolean()).isFalse();
    assertThat(read("/release-operations/"+op.path("id").asText()).path("state").asText()).isEqualTo("EXECUTION_UNKNOWN");
    assertThat(machinePost("/claims/outcomes",machine("REPORT",op.path("id").asText(),claim,"UNKNOWN")).path("state").asText()).isEqualTo("EXECUTION_UNKNOWN");
  }
  @Test void machineKeyDoesNotCreateReleaseAndWrongSignatureOrReplayIsRejected()throws Exception{
    JsonNode op=start(target());String claim=UUID.randomUUID().toString();var request=machine("CLAIM",op.path("id").asText(),claim,null);var wrong=new LinkedHashMap<>(request);wrong.put("proof",b64(new byte[32]));
    mvc.perform(post(MACHINE+"/claims").contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(wrong))).andExpect(status().isUnauthorized());
    machinePost("/claims",request);mvc.perform(post(MACHINE+"/claims").contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(request))).andExpect(status().isUnauthorized());
    mvc.perform(post(ROOT+"/release-operations").contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(request))).andExpect(status().isUnauthorized());
  }
  @Test void claimedOrUnknownOperationCannotBeCancelledOrSuperseded()throws Exception{
    var first=target();JsonNode op=start(first);String claim=claim(op);var second=target();
    mvc.perform(post(ROOT+"/release-operations").with(actor("publish")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(second))).andExpect(status().isConflict());
    mvc.perform(post(ROOT+"/release-operations/"+op.path("id").asText()+"/cancellations").with(actor("publish")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(Map.of("id",UUID.randomUUID().toString(),"expectedRuntimeRevision",read("/release-status").path("runtimeRevision").asLong())))).andExpect(status().isConflict());
    begin(op,claim);assertThat(read("/release-status").path("activeOperation").path("id").asText()).isEqualTo(op.path("id").asText());
  }
  @Test void unclaimedCancellationIsIdempotentAndOldClaimCannotExecute()throws Exception{
    JsonNode op=start(target());var input=Map.of("id",UUID.randomUUID().toString(),"expectedRuntimeRevision",read("/release-status").path("runtimeRevision").asLong());
    var result=postAdmin("/release-operations/"+op.path("id").asText()+"/cancellations",input,"publish");assertThat(result.path("state").asText()).isEqualTo("CANCELLED");
    assertThat(postAdmin("/release-operations/"+op.path("id").asText()+"/cancellations",input,"publish")).isEqualTo(result);
    mvc.perform(post(MACHINE+"/claims").contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(machine("CLAIM",op.path("id").asText(),UUID.randomUUID().toString(),null)))).andExpect(status().isConflict());
  }
  @Test void actualLoadedConfigurationProofConfirmsClosedRuntimeWithoutSupplierOrSalesApproval()throws Exception{
    var input=target();JsonNode result=confirm(input);assertThat(result.path("state").asText()).isEqualTo("CONFIRMED");assertThat(result.path("instances").get(0).path("state").asText()).isEqualTo("CONFIRMED");
    JsonNode current=read("/release-status");assertThat(current.path("activeOperation").isNull()).isTrue();assertThat(current.path("runtimeStatus").asText()).isEqualTo("APPLIED_CLOSED");assertThat(current.path("salesAllowed").asBoolean()).isFalse();
    assertThat(read("/status").path("runtimeStatus").asText()).isEqualTo("APPLIED_CLOSED");assertThat(result.toString()).doesNotContain("ProviderFixtureSecret","proof",DIR.toString());
    assertThat(CALLS.get()).isEqualTo(1);
  }
  @Test void wrongActualSecretJarVersionKeyTimesOrEnabledEntryNeverConfirm()throws Exception{
    var input=target();JsonNode op=start(input);String claim=claim(op);begin(op,claim);load(input);
    for(String failure:List.of("wrong-secret","wrong-jar","wrong-version","wrong-key","old-boot","old-time","enabled","extra-field")){
      mode=failure;var result=check(op,UUID.randomUUID().toString());assertThat(result.path("state").asText()).as(failure).isIn("MISMATCH","UNAVAILABLE");assertThat(read("/release-status").path("confirmedOperation").isNull()).isTrue();
    }
  }
  @Test void lostProbeResultRecoversByIdWithoutReissuingChallenge()throws Exception{
    var input=target();JsonNode op=start(input);String claim=claim(op);begin(op,claim);String id=UUID.randomUUID().toString();
    var unavailable=check(op,id);assertThat(unavailable.path("state").asText()).isEqualTo("UNAVAILABLE");int calls=CALLS.get();load(input);
    assertThat(read("/runtime-checks/"+id)).isEqualTo(unavailable);assertThat(check(op,id)).isEqualTo(unavailable);assertThat(CALLS.get()).isEqualTo(calls);
    assertThat(check(op,UUID.randomUUID().toString()).path("state").asText()).isEqualTo("CONFIRMED");
  }
  @Test void machineFinishedOnlyConfirmsAfterActualProbeAndCannotForgeApplied()throws Exception{
    var input=target();JsonNode op=start(input);String claim=claim(op);begin(op,claim);load(input);
    JsonNode report=machinePost("/claims/outcomes",machine("REPORT",op.path("id").asText(),claim,"FINISHED"));assertThat(report.path("state").asText()).isEqualTo("APPLIED_CLOSED");assertThat(report.path("executionAllowed").asBoolean()).isFalse();
    assertThat(CALLS.get()).isEqualTo(1);assertThat(read("/release-status").path("salesAllowed").asBoolean()).isFalse();
  }
  @Test void rollbackRequiresConfirmedHistoryAndPreservesIdentityBinding()throws Exception{
    var first=target();assertThat(confirm(first).path("state").asText()).isEqualTo("CONFIRMED");var second=target();assertThat(confirm(second).path("state").asText()).isEqualTo("CONFIRMED");
    assertThat(read("/release-operations/"+first.get("id")).path("runtimeStatus").asText()).isEqualTo("APPLIED_CLOSED");
    var rollback=new LinkedHashMap<>(first);rollback.put("id",UUID.randomUUID().toString());rollback.put("kind","ROLLBACK");rollback.put("expectedRuntimeRevision",read("/release-status").path("runtimeRevision").asLong());
    JsonNode op=start(rollback);assertThat(op.path("kind").asText()).isEqualTo("ROLLBACK");String claim=claim(op);begin(op,claim);load(rollback);assertThat(check(op,UUID.randomUUID().toString()).path("state").asText()).isEqualTo("CONFIRMED");
    assertThat(read("/release-status").path("confirmedOperation").path("versionId").asText()).isEqualTo(first.get("versionId"));
    var unconfirmed=target();unconfirmed.put("kind","ROLLBACK");mvc.perform(post(ROOT+"/release-operations").with(actor("rollback")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(unconfirmed))).andExpect(status().isConflict());
  }
  @Test void simultaneousReleaseApprovalsHaveExactlyOneWinner()throws Exception{
    var left=target();var right=new LinkedHashMap<>(left);right.put("id",UUID.randomUUID().toString());var pool=Executors.newFixedThreadPool(2);var start=new CountDownLatch(1);
    try{
      Callable<Integer> first=()->{start.await();return mvc.perform(post(ROOT+"/release-operations").with(actor("publish")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(left))).andReturn().getResponse().getStatus();};
      Callable<Integer> second=()->{start.await();return mvc.perform(post(ROOT+"/release-operations").with(actor("publish")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(right))).andReturn().getResponse().getStatus();};
      var a=pool.submit(first);var b=pool.submit(second);start.countDown();assertThat(List.of(a.get(10,TimeUnit.SECONDS),b.get(10,TimeUnit.SECONDS))).containsExactlyInAnyOrder(200,412);
    }finally{pool.shutdownNow();}
  }
  @Test void claimedPreflightCanAbandonBeforeBeginAndOriginalClaimCannotExecuteLater()throws Exception{
    JsonNode op=start(target());String claim=claim(op);
    var abandoned=machinePost("/claims/abandon",machine("ABANDON_BEFORE_BEGIN",op.path("id").asText(),claim,null));
    assertThat(abandoned.path("state").asText()).isEqualTo("CANCELLED");
    assertThat(machinePost("/claims/query",machine("QUERY",op.path("id").asText(),claim,null)).path("state").asText()).isEqualTo("CANCELLED");
    assertThat(read("/release-status").path("activeOperation").isNull()).isTrue();
    mvc.perform(post(MACHINE+"/claims/begin").contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(machine("BEGIN",op.path("id").asText(),claim,null)))).andExpect(status().isConflict());
  }
  @Test void activeObservationCannotConfirmBeforeBeginAndAbandonAfterBeginIsRefused()throws Exception{
    var input=target();JsonNode op=start(input);load(input);String request=UUID.randomUUID().toString();
    mvc.perform(post(ROOT+"/release-operations/"+op.path("id").asText()+"/runtime-checks").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(Map.of("id",request)))).andExpect(status().isConflict());
    String claim=claim(op);
    mvc.perform(post(ROOT+"/release-operations/"+op.path("id").asText()+"/runtime-checks").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(Map.of("id",request)))).andExpect(status().isConflict());
    assertThat(CALLS.get()).isZero();begin(op,claim);
    mvc.perform(post(MACHINE+"/claims/abandon").contentType(MediaType.APPLICATION_JSON).content(JSON.writeValueAsBytes(machine("ABANDON_BEFORE_BEGIN",op.path("id").asText(),claim,null)))).andExpect(status().isConflict());
  }
  @Test void independentPublisherCanSelectPreparedTargetWithoutManageAndVersionLeaks()throws Exception{
    var first=target();var second=target();String firstVersion=(String)first.get("versionId");
    String extra=UUID.randomUUID().toString();postAdmin("/versions/"+firstVersion+"/release-preparations",Map.of("id",extra),"manage");
    JsonNode result=read("/versions/"+firstVersion+"/release-preparations");
    assertThat(result.path("items").size()).isEqualTo(2);assertThat(result.path("items").get(0).path("id").asText()).isEqualTo(extra);
    assertThat(result.toString()).doesNotContain((String)second.get("versionId"),DIR.toString(),"protectedPayload");
    for(JsonNode item:result.path("items"))assertThat(item.path("versionId").asText()).isEqualTo(firstVersion);
    for(int i=0;i<6;i++)postAdmin("/versions/"+firstVersion+"/release-preparations",Map.of("id",UUID.randomUUID().toString()),"manage");
    assertThat(read("/versions/"+firstVersion+"/release-preparations").path("items").size()).isEqualTo(5);
    String draft=UUID.randomUUID().toString();postAdmin("/versions",Map.of("id",draft,"baseVersion",read("/status").path("latestVersion").asLong(),"settings",Map.of()),"manage");
    assertThat(read("/versions/"+draft+"/release-preparations").path("items").isEmpty()).isTrue();
    mvc.perform(get(ROOT+"/versions/"+firstVersion+"/release-preparations").with(actor("publish"))).andExpect(status().isForbidden());
    mvc.perform(get(ROOT+"/versions/"+UUID.randomUUID()+"/release-preparations").with(actor("read"))).andExpect(status().isNotFound());
  }
  @Test void historicalConfirmedClaimCannotAuthorizeRewritingTheCurrentHostPointer()throws Exception{
    var first=target();JsonNode firstOp=start(first);String firstClaim=claim(firstOp);begin(firstOp,firstClaim);load(first);check(firstOp,UUID.randomUUID().toString());
    assertThat(machinePost("/claims/query",machine("QUERY",firstOp.path("id").asText(),firstClaim,null)).path("canFinalizeHostPointer").asBoolean()).isTrue();
    var second=target();JsonNode secondOp=start(second);String secondClaim=claim(secondOp);begin(secondOp,secondClaim);load(second);check(secondOp,UUID.randomUUID().toString());
    JsonNode old=machinePost("/claims/query",machine("QUERY",firstOp.path("id").asText(),firstClaim,null));
    assertThat(old.path("state").asText()).isEqualTo("APPLIED_CLOSED");assertThat(old.path("canFinalizeHostPointer").asBoolean()).isFalse();
    assertThat(machinePost("/claims/query",machine("QUERY",secondOp.path("id").asText(),secondClaim,null)).path("canFinalizeHostPointer").asBoolean()).isTrue();
    start(target());assertThat(machinePost("/claims/query",machine("QUERY",secondOp.path("id").asText(),secondClaim,null)).path("canFinalizeHostPointer").asBoolean()).isFalse();
  }
  @Test void onlyNeverStartedCancelledFirstClaimCanClearItsOwnPendingHostPointer()throws Exception{
    JsonNode cancelled=start(target());String abandonedClaim=claim(cancelled);
    JsonNode first=machinePost("/claims/abandon",machine("ABANDON_BEFORE_BEGIN",cancelled.path("id").asText(),abandonedClaim,null));
    assertThat(first.path("canClearPendingHostPointer").asBoolean()).isTrue();assertThat(first.path("currentConfirmedOperationId").isNull()).isTrue();
    var next=target();JsonNode active=start(next);String activeClaim=claim(active);begin(active,activeClaim);
    JsonNode unknown=machinePost("/claims/query",machine("QUERY",active.path("id").asText(),activeClaim,null));assertThat(unknown.path("canClearPendingHostPointer").asBoolean()).isFalse();
    assertThat(machinePost("/claims/query",machine("QUERY",cancelled.path("id").asText(),abandonedClaim,null)).path("canClearPendingHostPointer").asBoolean()).isFalse();
    load(next);check(active,UUID.randomUUID().toString());
    JsonNode confirmed=machinePost("/claims/query",machine("QUERY",active.path("id").asText(),activeClaim,null));assertThat(confirmed.path("currentConfirmedOperationId").asText()).isEqualTo(active.path("id").asText());
    assertThat(confirmed.path("canFinalizeHostPointer").asBoolean()).isTrue();assertThat(confirmed.path("canClearPendingHostPointer").asBoolean()).isFalse();
    assertThat(machinePost("/claims/query",machine("QUERY",cancelled.path("id").asText(),abandonedClaim,null)).path("canClearPendingHostPointer").asBoolean()).isFalse();
  }
  @Test void expiredPendingCheckBecomesUnavailableWithoutConfirmingOrReplaying()throws Exception{
    var input=target();JsonNode op=start(input);String claim=claim(op);begin(op,claim);load(input);String checkId=UUID.randomUUID().toString();
    db.update("INSERT INTO identity_provider_runtime_checks(id,environment_id,operation_id,version_id,actor_key,state,reason_code,instances_json,created_at) VALUES(?,?,?,?,?,'CHECKING','RUNTIME_CHECK_PENDING','[]',?)",checkId,ENV,op.path("id").asText(),input.get("versionId"),"persisted-crash-fixture",Instant.now().toEpochMilli()-121000);
    JsonNode expired=read("/runtime-checks/"+checkId);assertThat(expired.path("state").asText()).isEqualTo("UNAVAILABLE");assertThat(expired.path("reasonCode").asText()).isEqualTo("RUNTIME_CHECK_INTERRUPTED");
    assertThat(expired.path("completedAt").isIntegralNumber()).isTrue();assertThat(read("/runtime-checks/"+checkId)).isEqualTo(expired);assertThat(CALLS.get()).isZero();
    assertThat(read("/release-status").path("activeOperation").path("id").asText()).isEqualTo(op.path("id").asText());assertThat(read("/release-status").path("confirmedOperation").isNull()).isTrue();
    assertThat(check(op,UUID.randomUUID().toString()).path("state").asText()).isEqualTo("CONFIRMED");
  }
  @Test void checkingWithinLeaseRemainsPendingWithoutCallingTheRuntime()throws Exception{
    var input=target();JsonNode op=start(input);String claim=claim(op);begin(op,claim);String id=UUID.randomUUID().toString();
    db.update("INSERT INTO identity_provider_runtime_checks(id,environment_id,operation_id,version_id,actor_key,state,reason_code,instances_json,created_at) VALUES(?,?,?,?,?,'CHECKING','RUNTIME_CHECK_PENDING','[]',?)",id,ENV,op.path("id").asText(),input.get("versionId"),"persisted-running-fixture",Instant.now().toEpochMilli());
    JsonNode pending=read("/runtime-checks/"+id);assertThat(pending.path("state").asText()).isEqualTo("CHECKING");assertThat(pending.path("completedAt").isNull()).isTrue();assertThat(CALLS.get()).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_audit_events WHERE resource_id=? AND action='RUNTIME_CHECK_EXPIRED'",Integer.class,id)).isZero();
  }
  @Test void expiredCheckCannotBeRevivedByAnAlreadyRunningMatchingProbe()throws Exception{
    var input=target();JsonNode op=start(input);String claim=claim(op);begin(op,claim);load(input);mode="latched";String id=UUID.randomUUID().toString();
    ExecutorService pool=Executors.newSingleThreadExecutor();
    try{
      Future<JsonNode> original=pool.submit(()->check(op,id));assertThat(probeEntered.await(2,TimeUnit.SECONDS)).isTrue();
      db.update("UPDATE identity_provider_runtime_checks SET created_at=? WHERE id=?",Instant.now().toEpochMilli()-121000,id);
      JsonNode expired=read("/runtime-checks/"+id);assertThat(expired.path("state").asText()).isEqualTo("UNAVAILABLE");assertThat(expired.path("reasonCode").asText()).isEqualTo("RUNTIME_CHECK_INTERRUPTED");
      probeRelease.countDown();assertThat(original.get(3,TimeUnit.SECONDS)).isEqualTo(expired);assertThat(RESPONSE_WRITTEN.get()).isTrue();
      assertThat(read("/runtime-checks/"+id)).isEqualTo(expired);assertThat(CALLS.get()).isEqualTo(1);
      assertThat(read("/release-status").path("confirmedOperation").isNull()).isTrue();assertThat(read("/release-status").path("activeOperation").path("id").asText()).isEqualTo(op.path("id").asText());
      assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_audit_events WHERE resource_id=? AND action='RUNTIME_CHECK_EXPIRED'",Integer.class,id)).isEqualTo(1);
      mode="matching";assertThat(check(op,UUID.randomUUID().toString()).path("state").asText()).isEqualTo("CONFIRMED");
    }finally{probeRelease.countDown();pool.shutdownNow();}
  }
  static byte[] random(){byte[] value=new byte[32];new java.security.SecureRandom().nextBytes(value);return value;}
  static String b64(byte[] value){return Base64.getUrlEncoder().withoutPadding().encodeToString(value);}
  static String mac(byte[] key,List<String> fields)throws Exception{var bytes=new java.io.ByteArrayOutputStream();for(String field:fields){byte[] value=field.getBytes(StandardCharsets.UTF_8);bytes.write(Integer.toString(value.length).getBytes(StandardCharsets.US_ASCII));bytes.write(':');bytes.write(value);}var mac=Mac.getInstance("HmacSHA256");mac.init(new SecretKeySpec(key,"HmacSHA256"));return b64(mac.doFinal(bytes.toByteArray()));}
}

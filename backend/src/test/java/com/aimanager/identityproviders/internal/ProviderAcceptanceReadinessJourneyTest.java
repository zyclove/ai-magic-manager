package com.aimanager.identityproviders.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.aimanager.commerce.FamilySalesGate;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.JWEAlgorithm;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
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
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/** 仅验证本地状态机；身份、配置、发布事实均为夹具，不代表供应商或真机验收。 */
@SpringBootTest(properties={
    "spring.datasource.url=${IDENTITY_PROVIDER_TEST_DATABASE_URL:jdbc:h2:mem:provider-acceptance-readiness;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
    "spring.datasource.username=${IDENTITY_PROVIDER_TEST_DATABASE_USERNAME:sa}","spring.datasource.password=${IDENTITY_PROVIDER_TEST_DATABASE_PASSWORD:}",
    "manager.exports.worker.enabled=false","manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false","manager.family.sales-enabled=true",
    "manager.identity-providers.environment-id=acceptance-fixture"})
@AutoConfigureMockMvc
class ProviderAcceptanceReadinessJourneyTest {
  static final String ROOT="/api/v1/platform/identity-providers",ENV="acceptance-fixture",JAR="b".repeat(64),APK="c".repeat(64);
  static final Path DIR=directory();
  static Path directory(){try{
    Path dir=Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")),"provider-acceptance-");
    byte[] key=new byte[32];new java.security.SecureRandom().nextBytes(key);
    var jwk=new OctetSequenceKey.Builder(key).keyID("acceptance-vault").keyUse(KeyUse.ENCRYPTION).algorithm(JWEAlgorithm.DIR).build();
    Files.writeString(dir.resolve("ring.json"),new JWKSet(jwk).toString(false));Files.createDirectory(dir.resolve("releases"));return dir;
  }catch(Exception failure){throw new ExceptionInInitializerError(failure);}}
  @DynamicPropertySource static void properties(DynamicPropertyRegistry p){
    String database=System.getenv("IDENTITY_PROVIDER_TEST_DATABASE_URL");
    if(database!=null&&!database.matches("jdbc:mysql://127\\.0\\.0\\.1:[0-9]{1,5}/identity_provider_it_[a-f0-9]{32}\\?connectionTimeZone=UTC&useSSL=false&allowPublicKeyRetrieval=true"))
      throw new IllegalStateException("Only an explicitly disposable loopback identity-provider test database is allowed");
    p.add("manager.identity-providers.key-file",()->DIR.resolve("ring.json").toString());
    p.add("manager.identity-providers.release-directory",()->DIR.resolve("releases").toString());
  }
  @Autowired MockMvc mvc;@Autowired ObjectMapper json;@Autowired JdbcTemplate db;
  @Autowired PlatformTransactionManager transactions;@Autowired FamilySalesGate salesGate;
  @MockitoBean JwtDecoder decoder;
  @BeforeEach void clearFixture(){
    // 本例包含跨环境读取夹具；它仍只清理本测试版本引用的记录。
    db.update("DELETE FROM identity_provider_acceptance_runs WHERE version_id IN (SELECT id FROM identity_provider_versions WHERE environment_id=?)",ENV);
    for(String table:List.of("identity_provider_runtime_checks","identity_provider_runtime_heads","identity_provider_executor_nonces",
        "identity_provider_release_operations","identity_provider_acceptance_runs","identity_provider_release_preparations",
        "identity_provider_audit_events","identity_provider_versions","identity_provider_heads"))
      db.update("DELETE FROM "+table+" WHERE environment_id=?",ENV);
  }
  RequestPostProcessor actor(String...scopes){return jwt().jwt(j->j.subject("acceptance-admin").claim("amr",List.of("pwd","otp")).claim("auth_time",Instant.now()))
      .authorities(Arrays.stream(scopes).map(s->new SimpleGrantedAuthority("SCOPE_identity-config:"+s)).toArray(SimpleGrantedAuthority[]::new));}
  JsonNode getStatus()throws Exception{return json.readTree(mvc.perform(get(ROOT+"/acceptance-status").with(actor("read")))
      .andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store")).andExpect(header().stringValues("Vary",org.hamcrest.Matchers.hasItem("Authorization")))
      .andReturn().getResponse().getContentAsString());}
  String version(boolean complete)throws Exception{
    var rows=db.queryForList("SELECT version FROM identity_provider_heads WHERE environment_id=?",Long.class,ENV);
    var input=new LinkedHashMap<String,Object>();input.put("id",UUID.randomUUID().toString());input.put("baseVersion",rows.isEmpty()?0:rows.get(0));
    input.put("settings",complete?Map.of("smsSignName","家庭管家","smsTemplateCode","SMS_123456","wechatAppId","wx0123456789abcdef",
        "parentPackageName","com.aimanager.parent","parentCertificateSha256","a".repeat(64)):Map.of());
    input.put("replacements",complete?Map.of("smsAccessKeyId","LTAIAcceptanceFixture1234","smsAccessKeySecret","AcceptanceFixtureSecret1234","wechatAppSecret","0123456789abcdef0123456789abcdef"):Map.of());
    return json.readTree(mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(input)))
        .andExpect(status().isOk()).andReturn().getResponse().getContentAsString()).path("id").asText();
  }
  String confirm(String version,long revision)throws Exception{
    String preparation=UUID.randomUUID().toString();mvc.perform(post(ROOT+"/versions/"+version+"/release-preparations").with(actor("manage"))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("id",preparation)))).andExpect(status().isOk());
    String operation=UUID.randomUUID().toString();long now=System.currentTimeMillis();
    db.update("INSERT INTO identity_provider_release_operations(id,environment_id,kind,version_id,preparation_id,provider_jar_sha256,parent_apk_sha256,base_runtime_revision,state,reason_code,actor_key,request_json,created_at,confirmed_at) VALUES(?,?,'PUBLISH',?,?,?,?,?,'APPLIED_CLOSED','RUNTIME_CONFIGURATION_CONFIRMED','fixture','{}',?,?)",
        operation,ENV,version,preparation,JAR,APK,revision-2,now,now);
    db.update("INSERT INTO identity_provider_runtime_heads(environment_id,revision,confirmed_operation_id) VALUES(?,?,?) ON DUPLICATE KEY UPDATE revision=?,confirmed_operation_id=?,active_operation_id=NULL",ENV,revision,operation,revision,operation);return operation;
  }
  Map<String,Object> input(String id,String version){return new LinkedHashMap<>(Map.of("id",id,"versionId",version,"environmentId",ENV,"providerJarSha256",JAR,"parentApkSha256",APK));}
  Map<String,Object> bound(String id,String version,String operation,long revision){var input=input(id,version);input.put("releaseOperationId",operation);input.put("expectedRuntimeRevision",revision);return input;}
  JsonNode create(Map<String,Object> input)throws Exception{return json.readTree(mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test"))
      .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(input))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());}

  @Test void statusAndRecentRunsRequireReadScopeAndRecentPlatformMfa()throws Exception{
    mvc.perform(get(ROOT+"/acceptance-status")).andExpect(status().isUnauthorized());
    mvc.perform(get(ROOT+"/acceptance-status").with(actor("test"))).andExpect(status().isForbidden());
    mvc.perform(get(ROOT+"/acceptance-runs").with(actor("manage"))).andExpect(status().isForbidden());
    mvc.perform(get(ROOT+"/acceptance-status").with(jwt().jwt(j->j.subject("consumer").claim("amr",List.of("sms")).claim("auth_time",Instant.now()))
        .authorities(new SimpleGrantedAuthority("SCOPE_identity-config:read")))).andExpect(status().isUnauthorized());
    mvc.perform(get(ROOT+"/acceptance-runs").with(actor("read"))).andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(0));
  }
  @Test void nextStepUsesActualConfigurationAndRuntimeFacts()throws Exception{
    assertThat(getStatus().path("nextAction").asText()).isEqualTo("CONFIGURE");
    version(false);assertThat(getStatus().path("nextAction").asText()).isEqualTo("CHECK_CONFIGURATION");
    String version=version(true);assertThat(getStatus().path("nextAction").asText()).isEqualTo("PUBLISH_CONFIGURATION");
    confirm(version,2);assertThat(getStatus().path("nextAction").asText()).isEqualTo("REGISTER_RUN");
  }
  @Test void validRunBindsCurrentConfirmedOperationAndExpiresWithoutClaimingRealSuccess()throws Exception{
    String version=version(true),operation=confirm(version,2),id=UUID.randomUUID().toString();
    JsonNode run=create(bound(id,version,operation,2));long expiry=run.path("expiresAt").asLong();
    assertThat(run.path("releaseOperationId").asText()).isEqualTo(operation);assertThat(run.path("runtimeRevision").asLong()).isEqualTo(2);
    assertThat(expiry-run.path("createdAt").asLong()).isEqualTo(86_400_000);
    assertThat(run.path("status").asText()).isEqualTo("BLOCKED");assertThat(run.path("providerRequestsPerformed").asBoolean()).isFalse();
    JsonNode current=getStatus();assertThat(current.path("status").asText()).isEqualTo("PENDING");assertThat(current.path("nextAction").asText()).isEqualTo("PREPARE_PILOT");
    assertThat(current.path("passedCount").asInt()).isZero();assertThat(current.path("requiredCount").asInt()).isEqualTo(12);
    for(JsonNode check:current.path("checks"))assertThat(check.path("status").asText()).isEqualTo("PENDING");
    assertThat(current.path("salesGate").path("allowed").asBoolean()).isFalse();assertThat(current.path("salesGate").path("status").asText()).isEqualTo("CLOSED");
    assertThat(salesGate.allowed()).isFalse();
    assertThat(current.toString()).doesNotContain("LTAIAcceptanceFixture1234","AcceptanceFixtureSecret1234","0123456789abcdef0123456789abcdef","proof","phone_number");
  }
  @Test void missingHalfBindingUnknownPassAndWrongArtifactsAreRejected()throws Exception{
    String version=version(true),operation=confirm(version,2);
    var half=input(UUID.randomUUID().toString(),version);half.put("releaseOperationId",operation);
    mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(half))).andExpect(status().isBadRequest());
    var wrong=bound(UUID.randomUUID().toString(),version,operation,2);wrong.put("parentApkSha256","d".repeat(64));
    mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(wrong))).andExpect(status().isConflict());
    var pass=bound(UUID.randomUUID().toString(),version,operation,2);pass.put("status","PASS");
    mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(pass))).andExpect(status().isBadRequest());
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_acceptance_runs WHERE environment_id=?",Integer.class,ENV)).isZero();
  }
  @Test void oldRevisionAndUnconfirmedOrActiveReleaseCannotBind()throws Exception{
    String version=version(true),operation=confirm(version,2);
    mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(bound(UUID.randomUUID().toString(),version,operation,1))))
        .andExpect(status().isPreconditionFailed());
    db.update("UPDATE identity_provider_runtime_heads SET active_operation_id=? WHERE environment_id=?",operation,ENV);
    mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(bound(UUID.randomUUID().toString(),version,operation,2))))
        .andExpect(status().isConflict());
    assertThat(getStatus().path("nextAction").asText()).isEqualTo("CHECK_RUNTIME");
    db.update("UPDATE identity_provider_runtime_heads SET active_operation_id=NULL,confirmed_operation_id=NULL WHERE environment_id=?",ENV);
    mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(bound(UUID.randomUUID().toString(),version,operation,2))))
        .andExpect(status().isConflict());
  }
  @Test void legacyUnboundRunStaysBlockedAndDuplicateCannotUpgradeItsBinding()throws Exception{
    String version=version(true),operation=confirm(version,2),id=UUID.randomUUID().toString();JsonNode old=create(input(id,version));
    assertThat(old.path("releaseOperationId").isNull()).isTrue();assertThat(getStatus().path("status").asText()).isEqualTo("BLOCKED");
    mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(bound(id,version,operation,2))))
        .andExpect(status().isConflict());assertThat(create(input(id,version))).isEqualTo(old);
  }
  @Test void replayAfterExpiryOrNewReleaseReturnsOriginalRunWithoutRenewingLease()throws Exception{
    String version=version(true),operation=confirm(version,2),id=UUID.randomUUID().toString();var request=bound(id,version,operation,2);JsonNode original=create(request);
    db.update("UPDATE identity_provider_acceptance_runs SET expires_at=? WHERE id=?",System.currentTimeMillis()-1,id);
    assertThat(getStatus().path("status").asText()).isEqualTo("STALE");
    confirm(version,4);JsonNode retry=create(request);assertThat(retry.path("releaseOperationId")).isEqualTo(original.path("releaseOperationId"));
    assertThat(retry.path("runtimeRevision").asLong()).isEqualTo(2);assertThat(retry.path("expiresAt").asLong()).isLessThan(System.currentTimeMillis());
    assertThat(getStatus().path("status").asText()).isEqualTo("STALE");
  }
  @Test void newDraftAndActivePublishInvalidateOldReadinessEvenIfHistoricalRunStillExists()throws Exception{
    String version=version(true),operation=confirm(version,2);create(bound(UUID.randomUUID().toString(),version,operation,2));
    version(true);assertThat(getStatus().path("status").asText()).isEqualTo("STALE");assertThat(getStatus().path("nextAction").asText()).isEqualTo("PUBLISH_CONFIGURATION");
    db.update("UPDATE identity_provider_runtime_heads SET active_operation_id=? WHERE environment_id=?",operation,ENV);
    assertThat(getStatus().path("status").asText()).isEqualTo("STALE");
  }
  @Test void recentRunsAreBoundedDeterministicAndCannotLeakOtherEnvironments()throws Exception{
    String version=version(true);for(int i=0;i<7;i++){String id=UUID.randomUUID().toString();create(input(id,version));db.update("UPDATE identity_provider_acceptance_runs SET created_at=? WHERE id=?",1000L+i,id);}
    String body=mvc.perform(get(ROOT+"/acceptance-runs").with(actor("read"))).andExpect(status().isOk()).andExpect(jsonPath("$.items.length()").value(5))
        .andReturn().getResponse().getContentAsString();JsonNode items=json.readTree(body).path("items");assertThat(items.get(0).path("createdAt").asLong()).isEqualTo(1006);
    assertThat(items.get(4).path("createdAt").asLong()).isEqualTo(1002);
    String first=items.get(0).path("id").asText();db.update("UPDATE identity_provider_acceptance_runs SET environment_id='other-environment' WHERE id=?",first);
    String reloaded=mvc.perform(get(ROOT+"/acceptance-runs").with(actor("read"))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();assertThat(reloaded).doesNotContain(first);
  }
  @Test void concurrentSameIdRegistrationsRecoverOneOriginalLease()throws Exception{
    String version=version(true),operation=confirm(version,2),id=UUID.randomUUID().toString();String body=json.writeValueAsString(bound(id,version,operation,2));
    var pool=Executors.newFixedThreadPool(2);var start=new CountDownLatch(1);
    Callable<String> request=()->{start.await();return mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isOk()).andReturn().getResponse().getContentAsString();};
    try{var first=pool.submit(request);var second=pool.submit(request);start.countDown();assertThat(first.get(15,TimeUnit.SECONDS)).isEqualTo(second.get(15,TimeUnit.SECONDS));
      assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_acceptance_runs WHERE id=?",Integer.class,id)).isEqualTo(1);
    }finally{pool.shutdownNow();}
  }
  @Test void unavailablePrivateReleaseDirectoryBlocksPreparedRun()throws Exception{
    String version=version(true),operation=confirm(version,2);create(bound(UUID.randomUUID().toString(),version,operation,2));
    Path original=DIR.resolve("releases"),paused=DIR.resolve("releases-paused-"+UUID.randomUUID());Files.move(original,paused);
    try{JsonNode state=getStatus();assertThat(state.path("nextAction").asText()).isEqualTo("CHECK_CONFIGURATION");assertThat(state.path("status").asText()).isNotEqualTo("PENDING");}
    finally{Files.move(paused,original);}
  }
  @Test void newBoundRegistrationRejectsHistoricalConfirmedVersionAfterNewDraft()throws Exception{
    String version=version(true),operation=confirm(version,2);var original=bound(UUID.randomUUID().toString(),version,operation,2);JsonNode saved=create(original);
    version(true);
    mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(bound(UUID.randomUUID().toString(),version,operation,2))))
        .andExpect(status().isConflict());assertThat(create(original)).isEqualTo(saved);
  }
  @Test void unavailablePrivateReleaseDirectoryRejectsNewBoundRunButKeepsLegacyAndReplay()throws Exception{
    String version=version(true),operation=confirm(version,2);var original=bound(UUID.randomUUID().toString(),version,operation,2);JsonNode saved=create(original);
    Path directory=DIR.resolve("releases"),paused=DIR.resolve("releases-paused-"+UUID.randomUUID());Files.move(directory,paused);
    try{
      mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(bound(UUID.randomUUID().toString(),version,operation,2))))
          .andExpect(status().isConflict());assertThat(create(original)).isEqualTo(saved);assertThat(create(input(UUID.randomUUID().toString(),version)).path("releaseOperationId").isNull()).isTrue();
    }finally{Files.move(paused,directory);}
  }
  @Test void registrationWaitingForRuntimeHeadObservesCommittedNewRevision()throws Exception{
    String version=version(true),operation=confirm(version,2),id=UUID.randomUUID().toString();String body=json.writeValueAsString(bound(id,version,operation,2));
    var pool=Executors.newSingleThreadExecutor();var entered=new CountDownLatch(1);
    var response=new java.util.concurrent.atomic.AtomicReference<Future<Integer>>();
    try{
      new TransactionTemplate(transactions).executeWithoutResult(tx->{
        db.queryForMap("SELECT * FROM identity_provider_runtime_heads WHERE environment_id=? FOR UPDATE",ENV);
        db.update("UPDATE identity_provider_runtime_heads SET revision=3,active_operation_id=? WHERE environment_id=?",operation,ENV);
        response.set(pool.submit(()->{entered.countDown();return mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(body)).andReturn().getResponse().getStatus();}));
        try{assertThat(entered.await(5,TimeUnit.SECONDS)).isTrue();Thread.sleep(100);assertThat(response.get().isDone()).isFalse();}
        catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IllegalStateException(interrupted);}
      });
      assertThat(response.get().get(15,TimeUnit.SECONDS)).isEqualTo(412);
      assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_acceptance_runs WHERE id=?",Integer.class,id)).isZero();
    }finally{pool.shutdownNow();}
  }
}

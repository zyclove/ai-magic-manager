package com.aimanager.identityproviders.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.nimbusds.jose.JWEAlgorithm;
import com.nimbusds.jose.jwk.*;
import java.nio.file.*;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;
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

/** Isolated SQL/HTTP behavior. JWT/MFA and credentials are fixtures, never supplier acceptance. */
@SpringBootTest(properties={
    "spring.datasource.url=${IDENTITY_PROVIDER_TEST_DATABASE_URL:jdbc:h2:mem:identity-provider-admin;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
    "spring.datasource.username=${IDENTITY_PROVIDER_TEST_DATABASE_USERNAME:sa}","spring.datasource.password=${IDENTITY_PROVIDER_TEST_DATABASE_PASSWORD:}",
    "manager.exports.worker.enabled=false","manager.report-jobs.worker.enabled=false",
    "manager.diagnostic-packages.worker.enabled=false","manager.identity-providers.environment-id=isolated-admin"})
@AutoConfigureMockMvc
class IdentityProviderAdminJourneyTest {
  static final String ROOT="/api/v1/platform/identity-providers";
  static final String AK="LTAIProviderFixture123456",SECRET="ProviderFixtureSecret123456789",WX="abcdef0123456789abcdef0123456789";
  static final Path DIRECTORY=directory();
  static Path directory(){try{
    Path root=Files.createTempDirectory(Path.of(System.getProperty("java.io.tmpdir")),"provider-admin-test-");
    byte[] bytes=new byte[32];new java.security.SecureRandom().nextBytes(bytes);
    var key=new OctetSequenceKey.Builder(bytes).keyID("provider-key").keyUse(KeyUse.ENCRYPTION).algorithm(JWEAlgorithm.DIR).build();
    Files.writeString(root.resolve("ring.json"),new JWKSet(key).toString(false));Files.createDirectory(root.resolve("releases"));return root;
  }catch(Exception failure){throw new ExceptionInInitializerError(failure);}}
  @DynamicPropertySource static void properties(DynamicPropertyRegistry p){
    String database=System.getenv("IDENTITY_PROVIDER_TEST_DATABASE_URL");
    if(database!=null&&!database.matches("jdbc:mysql://127\\.0\\.0\\.1:[0-9]{1,5}/identity_provider_it_[a-f0-9]{32}\\?connectionTimeZone=UTC&useSSL=false&allowPublicKeyRetrieval=true"))
      throw new IllegalStateException("Only an explicitly disposable loopback identity-provider test database is allowed");
    p.add("manager.identity-providers.key-file",()->DIRECTORY.resolve("ring.json").toString());
    p.add("manager.identity-providers.release-directory",()->DIRECTORY.resolve("releases").toString());
  }
  @Autowired MockMvc mvc;@Autowired ObjectMapper json;@Autowired JdbcTemplate db;
  @Autowired ProviderVault vault;
  @MockitoBean JwtDecoder decoder;
  RequestPostProcessor actor(String... scopes){return jwt().jwt(j->j.subject("provider-admin").claim("amr",List.of("pwd","otp")).claim("auth_time",Instant.now()))
      .authorities(Arrays.stream(scopes).map(s->new SimpleGrantedAuthority("SCOPE_identity-config:"+s)).toArray(SimpleGrantedAuthority[]::new));}
  JsonNode statusView()throws Exception{return json.readTree(mvc.perform(get(ROOT+"/status").with(actor("read","manage","test")))
      .andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store")).andReturn().getResponse().getContentAsString());}
  Map<String,Object> input(String id,long base){return new LinkedHashMap<>(Map.of("id",id,"baseVersion",base,"settings",Map.of(
      "smsSignName","家庭管家","smsTemplateCode","SMS_123456","wechatAppId","wx0123456789abcdef",
      "parentPackageName","com.aimanager.parent","parentCertificateSha256","a".repeat(64)),
      "replacements",Map.of("smsAccessKeyId",AK,"smsAccessKeySecret",SECRET,"wechatAppSecret",WX),"clearSmsSecurityToken",false));}
  JsonNode create(Map<String,Object> input)throws Exception{return json.readTree(mvc.perform(post(ROOT+"/versions").with(actor("manage"))
      .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(input))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString());}

  @Test void statusAndWritesRequireSeparateScopeAndRealRecentMfa()throws Exception{
    mvc.perform(get(ROOT+"/status")).andExpect(status().isUnauthorized());
    mvc.perform(get(ROOT+"/status").with(actor("manage"))).andExpect(status().isForbidden());
    mvc.perform(get(ROOT+"/status").with(jwt().jwt(j->j.subject("family").claim("amr",List.of("sms")).claim("auth_time",Instant.now()))
        .authorities(new SimpleGrantedAuthority("SCOPE_identity-config:read"))))
        .andExpect(status().isUnauthorized()).andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    mvc.perform(get(ROOT+"/status").with(jwt().jwt(j->j.subject("stale").claim("amr",List.of("mfa")).claim("auth_time",Instant.now().minusSeconds(301)))
        .authorities(new SimpleGrantedAuthority("SCOPE_identity-config:read")))).andExpect(status().isUnauthorized());
    mvc.perform(post(ROOT+"/versions").with(actor("read")).contentType(MediaType.APPLICATION_JSON).content("{}"))
        .andExpect(status().isForbidden());
    assertThat(statusView().path("salesAllowed").asBoolean()).isFalse();
  }

  @Test void savesEncryptedImmutableVersionAndRecoversByClientIdWithoutSecretReadback()throws Exception{
    long base=statusView().path("latestVersion").asLong();String id=UUID.randomUUID().toString();var request=input(id,base);
    JsonNode saved=create(request);assertThat(saved.path("version").asLong()).isEqualTo(base+1);
    assertThat(saved.path("credentials").path("otpHmacKey").asBoolean()).isTrue();
    String body=mvc.perform(get(ROOT+"/versions/"+id).with(actor("read"))).andExpect(status().isOk()).andReturn().getResponse().getContentAsString();
    assertThat(body).doesNotContain(AK,SECRET,WX,"protectedPayload","ciphertext","secretHash");
    assertThat(create(request)).isEqualTo(saved);
    var changed=new LinkedHashMap<>(request);changed.put("replacements",Map.of("smsAccessKeySecret","DifferentProviderSecret1234"));
    mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(changed)))
        .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("IDENTITY_PROVIDER_ID_CONFLICT"));
    String encrypted=db.queryForObject("SELECT protected_payload FROM identity_provider_versions WHERE id=?",String.class,id);
    assertThat(encrypted).startsWith("ey").doesNotContain(AK,SECRET,WX);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_audit_events WHERE resource_id=?",Integer.class,id)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id='platform-identity-providers'",Integer.class)).isZero();
  }

  @Test void globalCasPreventsLostUpdateAndOmittedSecretsPersistWhileStsNeedsExplicitClear()throws Exception{
    long base=statusView().path("latestVersion").asLong();String id=UUID.randomUUID().toString();var first=input(id,base);
    first.put("replacements",Map.of("smsAccessKeyId",AK,"smsAccessKeySecret",SECRET,"wechatAppSecret",WX,"smsSecurityToken","StsFixtureToken123456789"));
    JsonNode saved=create(first);var stale=input(UUID.randomUUID().toString(),base);
    mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(stale)))
        .andExpect(status().isPreconditionFailed()).andExpect(jsonPath("$.errorCode").value("IDENTITY_PROVIDER_VERSION_CONFLICT"));
    var next=input(UUID.randomUUID().toString(),saved.path("version").asLong());next.put("replacements",Map.of());next.put("clearSmsSecurityToken",true);
    JsonNode retained=create(next);assertThat(retained.path("credentials").path("smsAccessKeyId").asBoolean()).isTrue();
    assertThat(retained.path("credentials").path("wechatAppSecret").asBoolean()).isTrue();
    assertThat(retained.path("credentials").path("smsSecurityToken").asBoolean()).isFalse();
    var initialSecrets=secrets(id);var retainedSecrets=secrets(retained.path("id").asText());
    assertThat(retainedSecrets.path("CONSUMER_OTP_HMAC_KEY").asText()).isEqualTo(initialSecrets.path("CONSUMER_OTP_HMAC_KEY").asText());
    assertThat(Base64.getUrlDecoder().decode(initialSecrets.path("CONSUMER_OTP_HMAC_KEY").asText())).hasSize(32);
    assertThat(retainedSecrets.path("ALIYUN_SMS_ACCESS_KEY_ID").asText()).isEqualTo(AK);
    assertThat(retainedSecrets.path("ALIYUN_SMS_SECURITY_TOKEN").asText()).isEmpty();
  }

  @Test void validationAndReleasePreparationNeverClaimRuntimeEnablement()throws Exception{
    JsonNode saved=create(input(UUID.randomUUID().toString(),statusView().path("latestVersion").asLong()));String id=saved.path("id").asText();
    mvc.perform(post(ROOT+"/versions/"+id+"/validations").with(actor("manage"))).andExpect(status().isForbidden());
    mvc.perform(post(ROOT+"/versions/"+id+"/validations").with(actor("test"))).andExpect(status().isOk())
        .andExpect(jsonPath("$.readinessStatus").value("READY")).andExpect(jsonPath("$.runtimeStatus").value("APPLY_REQUIRED"))
        .andExpect(jsonPath("$.salesAllowed").value(false));
    String release=UUID.randomUUID().toString();String body=mvc.perform(post(ROOT+"/versions/"+id+"/release-preparations").with(actor("manage"))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("id",release))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("PREPARED")).andExpect(jsonPath("$.runtimeStatus").value("APPLY_REQUIRED"))
        .andExpect(jsonPath("$.salesAllowed").value(false)).andReturn().getResponse().getContentAsString();
    assertThat(body).doesNotContain(DIRECTORY.toString(),AK,SECRET,WX,"protectedPayload");
    Path path=DIRECTORY.resolve("releases").resolve(release+".json");JsonNode bundle=json.readTree(Files.readString(path));
    assertThat(bundle.path("schemaVersion").asInt()).isEqualTo(1);assertThat(bundle.path("environmentId").asText()).isEqualTo("isolated-admin");
    assertThat(bundle.path("versionId").asText()).isEqualTo(id);assertThat(Files.readString(path)).doesNotContain(AK,SECRET,WX);
    mvc.perform(get(ROOT+"/release-preparations/"+release).with(actor("read"))).andExpect(status().isOk()).andExpect(jsonPath("$.id").value(release));
  }

  @Test void acceptanceRunFreezesVersionsAndAllTwelveRealChecksRemainBlockedOrPending()throws Exception{
    JsonNode saved=create(input(UUID.randomUUID().toString(),statusView().path("latestVersion").asLong()));String id=UUID.randomUUID().toString();
    var request=new LinkedHashMap<String,Object>(Map.of("id",id,"versionId",saved.path("id").asText(),"environmentId","isolated-admin",
        "providerJarSha256","b".repeat(64),"parentApkSha256","c".repeat(64)));
    String body=mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(request)))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("BLOCKED")).andExpect(jsonPath("$.checks.length()").value(12))
        .andExpect(jsonPath("$.providerRequestsPerformed").value(false)).andExpect(jsonPath("$.salesAllowed").value(false)).andReturn().getResponse().getContentAsString();
    for(JsonNode check:json.readTree(body).path("checks"))assertThat(check.path("status").asText()).isIn("BLOCKED","PENDING");
    mvc.perform(get(ROOT+"/acceptance-runs/"+id).with(actor("read"))).andExpect(status().isOk()).andExpect(content().json(body));
    request.put("status","PASS");mvc.perform(post(ROOT+"/acceptance-runs").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(request)))
        .andExpect(status().isBadRequest());
    mvc.perform(post(ROOT+"/acceptance-runs/"+id+"/checks/REAL_SMS_DELIVERY").with(actor("test")).contentType(MediaType.APPLICATION_JSON).content("{\"status\":\"PASS\"}"))
        .andExpect(status().isNotFound());
  }

  @Test void incompleteDraftIsAllowedButUnsafeSettingsAndSecretFieldsAreRejected()throws Exception{
    var draft=input(UUID.randomUUID().toString(),statusView().path("latestVersion").asLong());draft.put("settings",Map.of());draft.put("replacements",Map.of());
    JsonNode saved=create(draft);assertThat(saved.path("readinessStatus").asText()).isEqualTo("BLOCKED");
    mvc.perform(post(ROOT+"/versions/"+saved.path("id").asText()+"/release-preparations").with(actor("manage"))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("id",UUID.randomUUID().toString()))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("BLOCKED"));
    draft.put("id",UUID.randomUUID().toString());draft.put("baseVersion",saved.path("version").asLong());
    draft.put("replacements",Map.of("otpHmacKey","client-cannot-control-hmac"));
    mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(draft))).andExpect(status().isBadRequest());
    draft.put("replacements",Map.of());draft.put("settings",Map.of("smsSignName","bad\nSECRET_VALUE"));
    String error=mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(draft)))
        .andExpect(status().isBadRequest()).andReturn().getResponse().getContentAsString();assertThat(error).doesNotContain("SECRET_VALUE");
  }
  JsonNode secrets(String id)throws Exception{return json.readTree(vault.open(ProviderConfigurationService.VAULT,"isolated-admin",id,
      db.queryForObject("SELECT protected_payload FROM identity_provider_versions WHERE id=?",String.class,id)));}
  @Test void simultaneousWritersHaveExactlyOneCasWinner()throws Exception{
    long base=statusView().path("latestVersion").asLong();String left=UUID.randomUUID().toString(),right=UUID.randomUUID().toString();
    ExecutorService pool=Executors.newFixedThreadPool(2);CountDownLatch start=new CountDownLatch(1);
    try{
      var first=pool.submit(()->{start.await();return mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON)
          .content(json.writeValueAsString(input(left,base)))).andReturn().getResponse().getStatus();});
      var second=pool.submit(()->{start.await();return mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON)
          .content(json.writeValueAsString(input(right,base)))).andReturn().getResponse().getStatus();});
      start.countDown();assertThat(List.of(first.get(15,TimeUnit.SECONDS),second.get(15,TimeUnit.SECONDS))).containsExactlyInAnyOrder(200,412);
      assertThat(statusView().path("latestVersion").asLong()).isEqualTo(base+1);
      assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_versions WHERE id IN (?,?)",Integer.class,left,right)).isEqualTo(1);
    }finally{pool.shutdownNow();}
  }
  @Test void everyRecoveryReadAndSensitiveOperationRequiresRecentMfaBeforeStateLookup()throws Exception{
    String id=UUID.randomUUID().toString();
    for(String path:List.of("/versions/"+id,"/release-preparations/"+id,"/acceptance-runs/"+id)){
      mvc.perform(get(ROOT+path).with(jwt().jwt(j->j.subject("stale").claim("amr",List.of("mfa")).claim("auth_time",Instant.now().minusSeconds(1000)))
          .authorities(new SimpleGrantedAuthority("SCOPE_identity-config:read")))).andExpect(status().isUnauthorized());
    }
    mvc.perform(post(ROOT+"/versions/"+id+"/validations").with(jwt().jwt(j->j.subject("sms-only").claim("amr",List.of("sms")).claim("auth_time",Instant.now()))
        .authorities(new SimpleGrantedAuthority("SCOPE_identity-config:test")))).andExpect(status().isUnauthorized());
  }
  @Test void missingBaseVersionAndUnsafeReplacementDoNotConsumeTheGlobalVersion()throws Exception{
    long before=statusView().path("latestVersion").asLong();var request=input(UUID.randomUUID().toString(),before);request.remove("baseVersion");
    mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(request)))
        .andExpect(status().isBadRequest());
    request.put("baseVersion",before);request.put("replacements",Map.of("smsSecurityToken","a".repeat(8193)));
    mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(request)))
        .andExpect(status().isBadRequest());
    assertThat(statusView().path("latestVersion").asLong()).isEqualTo(before);
  }
  @Test void databaseBoundaryIsExplicit()throws Exception{
    try(var connection=Objects.requireNonNull(db.getDataSource()).getConnection()){
      if(System.getenv("IDENTITY_PROVIDER_TEST_DATABASE_URL")==null)assertThat(connection.getMetaData().getDatabaseProductName()).isEqualTo("H2");
      else{
        assertThat(connection.getMetaData().getDatabaseProductName()).isEqualTo("MySQL");
        assertThat(connection.getMetaData().getDatabaseProductVersion()).startsWith("8.4.");
        assertThat(db.queryForObject("SELECT @@transaction_isolation",String.class)).isEqualTo("REPEATABLE-READ");
      }
    }
  }
  @Test void auditFailureRollsBackVersionSecretsAndTheGlobalHead()throws Exception{
    long before=statusView().path("latestVersion").asLong();String id=UUID.randomUUID().toString();boolean mysql;
    try(var connection=Objects.requireNonNull(db.getDataSource()).getConnection()){mysql="MySQL".equals(connection.getMetaData().getDatabaseProductName());}
    db.execute("ALTER TABLE identity_provider_audit_events ADD CONSTRAINT fixture_reject_version_audit CHECK (resource_id <> '"+id+"')");
    try{
      mvc.perform(post(ROOT+"/versions").with(actor("manage")).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(input(id,before))))
          .andExpect(status().is5xxServerError());
      assertThat(statusView().path("latestVersion").asLong()).isEqualTo(before);
      assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_versions WHERE id=?",Integer.class,id)).isZero();
      assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_audit_events WHERE resource_id=?",Integer.class,id)).isZero();
    }finally{db.execute("ALTER TABLE identity_provider_audit_events "+(mysql?"DROP CHECK ":"DROP CONSTRAINT ")+"fixture_reject_version_audit");}
  }
}

package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.doReturn;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:family-phone-invites;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "manager.family.rule-renewal.enabled=false", "manager.exports.worker.enabled=false", "manager.report-jobs.worker.enabled=false"})
@AutoConfigureMockMvc
class FamilyPhoneInvitationJourneyTest {
  @Autowired MockMvc mvc;
  @MockitoSpyBean JdbcTemplate db;
  @Autowired ObjectMapper json;
  @MockitoBean JwtDecoder decoder;
  String tenant, owner, recipient, id, token, issueKey;
  static final String OWNER_PHONE="+8613900000101", RECIPIENT_PHONE="+8613900000102";

  @BeforeEach void family() throws Exception {
    owner="owner-"+UUID.randomUUID(); recipient="guardian-"+UUID.randomUUID();
    id=UUID.randomUUID().toString(); token=SecretMaterial.token(); issueKey=UUID.randomUUID().toString();
    tenant=body(mvc.perform(post("/api/v1/family-onboarding").with(adult(owner,OWNER_PHONE))
        .header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON)
        .content("{\"adultGuardian\":true,\"declarationVersion\":\"family-guardian-v1\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("id").asText();
    long now=Instant.now().toEpochMilli();
    db.update("INSERT INTO commercial_accounts(tenant_id,version) VALUES(?,1)",tenant);
    db.update("INSERT INTO commercial_sources(tenant_id,source_system,source_key,source_revision,product_key,capacity_kind,device_capacity,features_json,active_from,expires_at,state,payload_hash,evidence_hash,verified_by,verified_at) VALUES(?,'TRIAL',?,1,'FAMILY_SUBSCRIPTION','BASE',3,?,?,?,'ACTIVE',?,?,?,?)",
        tenant,UUID.randomUUID().toString(),"[\"FAMILY_MULTI_DEVICE\"]",now-1000,now+86400000,"a".repeat(64),"b".repeat(64),"test-fixture",now);
  }

  @Test void phoneInviteIsPrivateIdempotentAndAcceptedOnlyWithMatchingVerifiedPhone() throws Exception {
    String first=issue();
    assertThat(first).doesNotContain(RECIPIENT_PHONE,token,SecretMaterial.hash(RECIPIENT_PHONE));
    mvc.perform(post(base()+"/family-invitations").with(adult(owner,OWNER_PHONE)).header("Idempotency-Key",issueKey)
        .contentType(MediaType.APPLICATION_JSON).content(issueBody()))
        .andExpect(status().isCreated()).andExpect(jsonPath("$.id").value(id));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM family_phone_invitations WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    mvc.perform(post("/api/v1/family-invitations/preview").with(adult(recipient,"+8613900000999"))
        .contentType(MediaType.APPLICATION_JSON).content(secretBody())).andExpect(status().isForbidden());
    mvc.perform(post("/api/v1/family-invitations/preview").with(adult(recipient,RECIPIENT_PHONE))
        .contentType(MediaType.APPLICATION_JSON).content(secretBody())).andExpect(status().isOk())
        .andExpect(jsonPath("$.tenantId").value(tenant)).andExpect(jsonPath("$.role").value("GUARDIAN"));
    String acceptKey=UUID.randomUUID().toString(); accept(acceptKey).andExpect(status().isOk())
        .andExpect(jsonPath("$.currentState").value("ACTIVE"));
    accept(acceptKey).andExpect(status().isOk());
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND actor_key=?",Integer.class,tenant,ActorKeys.key(recipient))).isEqualTo(1);
    assertThat(db.queryForObject("SELECT declaration_version FROM family_guardian_declarations WHERE actor_key=?",String.class,ActorKeys.key(recipient))).isEqualTo("family-guardian-v1");
    mvc.perform(get(base()+"/family-members").with(adult(recipient,RECIPIENT_PHONE)))
        .andExpect(status().isOk()).andExpect(jsonPath("$.currentRole").value("GUARDIAN"))
        .andExpect(jsonPath("$.members.length()").value(2));
    mvc.perform(post(base()+"/family-invitations").with(adult(recipient,RECIPIENT_PHONE))
        .header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("invitationId",UUID.randomUUID().toString(),"targetPhone","13900000103","token",SecretMaterial.token()))))
        .andExpect(status().isForbidden());
  }

  @Test void revocationExpiryDeclarationAndRecentSmsAreRechecked() throws Exception {
    issue();
    mvc.perform(post("/api/v1/family-invitations/accept").with(adult(recipient,RECIPIENT_PHONE))
        .header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("invitationId",id,"token",token,"adultGuardian",false,"declarationVersion","family-guardian-v1"))))
        .andExpect(status().isBadRequest());
    mvc.perform(post("/api/v1/family-invitations/accept").with(jwt().jwt(j->j.subject(recipient)
        .claim("phone_number",RECIPIENT_PHONE).claim("phone_number_verified",true).claim("auth_time",Instant.now().minusSeconds(3600).getEpochSecond()).claim("amr",List.of("sms"))))
        .header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON).content(acceptBody()))
        .andExpect(status().isUnauthorized());
    mvc.perform(delete(base()+"/family-invitations/"+id).with(adult(owner,OWNER_PHONE))).andExpect(status().isNoContent());
    accept(UUID.randomUUID().toString()).andExpect(status().isConflict());
    mvc.perform(get(base()+"/family-invitations").with(adult(owner,OWNER_PHONE))).andExpect(status().isOk())
        .andExpect(jsonPath("$.items[0].state").value("REVOKED"));
    id=UUID.randomUUID().toString();token=SecretMaterial.token();issueKey=UUID.randomUUID().toString();issue();
    db.update("UPDATE family_phone_invitations SET expires_at=? WHERE id=?",Instant.now().minusSeconds(1).toEpochMilli(),id);
    accept(UUID.randomUUID().toString()).andExpect(status().isConflict());
  }

  @Test void removedGuardianCannotUseMembershipAndReplayingAcceptanceDoesNotRestoreIt() throws Exception {
    issue();String acceptKey=UUID.randomUUID().toString();accept(acceptKey).andExpect(status().isOk());
    String installation=UUID.randomUUID().toString();
    mvc.perform(put(base()+"/push-installations/"+installation).with(adult(recipient,RECIPIENT_PHONE))
        .contentType(MediaType.APPLICATION_JSON).content("{\"provider\":\"ALIYUN\",\"platform\":\"ANDROID\",\"providerToken\":\"test_invitation_guardian_token\",\"notificationConsent\":true,\"permissionGranted\":true}"))
        .andExpect(status().isOk());
    mvc.perform(put(base()+"/notification-preferences").with(adult(recipient,RECIPIENT_PHONE))
        .contentType(MediaType.APPLICATION_JSON).content("{\"enabled\":true,\"requests\":true,\"deviceAttention\":true,\"ruleExpiry\":true}"))
        .andExpect(status().isOk());
    mvc.perform(delete(base()+"/family-members/"+ActorKeys.key(recipient)).with(adult(owner,OWNER_PHONE))
        .header("If-Match","\"1\"").header("Idempotency-Key",UUID.randomUUID().toString())).andExpect(status().isPreconditionFailed());
    mvc.perform(delete(base()+"/family-members/"+ActorKeys.key(recipient)).with(adult(owner,OWNER_PHONE))
        .header("If-Match","\"0\"").header("Idempotency-Key",UUID.randomUUID().toString())).andExpect(status().isNoContent());
    assertThat(db.queryForObject("SELECT provider_token IS NULL AND revoked_at IS NOT NULL FROM family_push_installations WHERE installation_id=?",Boolean.class,installation)).isTrue();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM family_notification_preferences WHERE tenant_id=? AND actor_key=?",Integer.class,tenant,ActorKeys.key(recipient))).isZero();
    mvc.perform(get(base()+"/family-members").with(adult(recipient,RECIPIENT_PHONE))).andExpect(status().isForbidden());
    accept(acceptKey).andExpect(status().isOk()).andExpect(jsonPath("$.currentState").value("REVOKED"));
    assertThat(db.queryForObject("SELECT revoked_at IS NOT NULL FROM tenant_members WHERE tenant_id=? AND actor_key=?",Boolean.class,tenant,ActorKeys.key(recipient))).isTrue();
    mvc.perform(delete(base()+"/family-members/"+ActorKeys.key(owner)).with(adult(owner,OWNER_PHONE))
        .header("If-Match","\"0\"").header("Idempotency-Key",UUID.randomUUID().toString()))
        .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("OWNER_TRANSFER_REQUIRED"));
  }

  @Test void expiredMembershipBlocksAddingGuardiansButStillAllowsRevokeRemoveAndHistoricalRecovery() throws Exception {
    issue();
    db.update("UPDATE commercial_sources SET expires_at=? WHERE tenant_id=?",Instant.now().minusSeconds(1).toEpochMilli(),tenant);
    accept(UUID.randomUUID().toString()).andExpect(status().isPaymentRequired()).andExpect(jsonPath("$.errorCode").value("ENTITLEMENT_REQUIRED"));
    mvc.perform(post(base()+"/family-invitations").with(adult(owner,OWNER_PHONE)).header("Idempotency-Key",issueKey)
        .contentType(MediaType.APPLICATION_JSON).content(issueBody())).andExpect(status().isCreated()).andExpect(jsonPath("$.id").value(id));
    mvc.perform(delete(base()+"/family-invitations/"+id).with(adult(owner,OWNER_PHONE))).andExpect(status().isNoContent());
    id=UUID.randomUUID().toString();token=SecretMaterial.token();issueKey=UUID.randomUUID().toString();
    mvc.perform(post(base()+"/family-invitations").with(adult(owner,OWNER_PHONE)).header("Idempotency-Key",issueKey)
        .contentType(MediaType.APPLICATION_JSON).content(issueBody())).andExpect(status().isPaymentRequired());
    db.update("UPDATE commercial_sources SET expires_at=? WHERE tenant_id=?",Instant.now().plusSeconds(3600).toEpochMilli(),tenant);
    issue();String key=UUID.randomUUID().toString();accept(key).andExpect(status().isOk());
    db.update("UPDATE commercial_sources SET expires_at=? WHERE tenant_id=?",Instant.now().minusSeconds(1).toEpochMilli(),tenant);
    mvc.perform(get(base()+"/family-members").with(adult(recipient,RECIPIENT_PHONE))).andExpect(status().isOk());
    mvc.perform(delete(base()+"/family-members/"+ActorKeys.key(recipient)).with(adult(owner,OWNER_PHONE))
        .header("If-Match","\"0\"").header("Idempotency-Key",UUID.randomUUID().toString())).andExpect(status().isNoContent());
    accept(key).andExpect(status().isOk()).andExpect(jsonPath("$.currentState").value("REVOKED"));
  }

  @Test void changedIssuerAuthorityAndUnverifiedPhoneCannotGrantAccessOrRevealFamily() throws Exception {
    issue();
    mvc.perform(post("/api/v1/family-invitations/preview").with(jwt().jwt(j->j.subject(recipient).claim("phone_number",RECIPIENT_PHONE).claim("phone_number_verified",false)))
        .contentType(MediaType.APPLICATION_JSON).content(secretBody())).andExpect(status().isPreconditionRequired());
    db.update("UPDATE tenant_members SET role='GUARDIAN' WHERE tenant_id=? AND actor_key=?",tenant,ActorKeys.key(owner));
    accept(UUID.randomUUID().toString()).andExpect(status().isForbidden());
    mvc.perform(post("/api/v1/family-invitations/preview").with(adult(recipient,RECIPIENT_PHONE))
        .contentType(MediaType.APPLICATION_JSON).content(secretBody())).andExpect(status().isForbidden());
  }

  @Test void organizationCannotUseFamilyApiAndInvitationJournalsContainNoPhoneOrSecret() throws Exception {
    issue();
    String journals=String.join("",db.queryForList("SELECT response_body FROM idempotency_requests WHERE scope_id=? AND operation='family.invitation.issue'",String.class,tenant));
    assertThat(journals).doesNotContain(token,RECIPIENT_PHONE,"13900000102");
    mvc.perform(post(base()+"/family-invitations").with(adult(owner,OWNER_PHONE)).header("Idempotency-Key",issueKey)
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("invitationId",id,"targetPhone","13900000103","token",token))))
        .andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("IDEMPOTENCY_KEY_CONFLICT"));
    String org=body(mvc.perform(post("/api/v1/tenants").with(adult(owner,OWNER_PHONE)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"机构\",\"kind\":\"ORGANIZATION\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).path("id").asText();
    mvc.perform(get("/api/v1/tenants/"+org+"/family-members").with(adult(owner,OWNER_PHONE))).andExpect(status().isForbidden());
  }

  @Test void legacyGuardianDeclarationCanBeRecordedWithoutChangingMembershipOrCreatingFamily() throws Exception {
    db.update("DELETE FROM family_guardian_declarations WHERE actor_key=?",ActorKeys.key(owner));
    mvc.perform(get(base()+"/family-members").with(adult(owner,OWNER_PHONE))).andExpect(status().isOk())
        .andExpect(jsonPath("$.guardianDeclarationRequired").value(true));
    mvc.perform(post(base()+"/family-invitations").with(adult(owner,OWNER_PHONE)).header("Idempotency-Key",issueKey)
        .contentType(MediaType.APPLICATION_JSON).content(issueBody())).andExpect(status().isBadRequest())
        .andExpect(jsonPath("$.errorCode").value("GUARDIAN_DECLARATION_REQUIRED"));
    mvc.perform(post(base()+"/family-guardian-declaration").with(adult(owner,OWNER_PHONE)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"adultGuardian\":false,\"declarationVersion\":\"family-guardian-v1\"}"))
        .andExpect(status().isBadRequest());
    mvc.perform(post(base()+"/family-guardian-declaration").with(adult(owner,OWNER_PHONE)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"adultGuardian\":true,\"declarationVersion\":\"family-guardian-v1\"}"))
        .andExpect(status().isOk()).andExpect(jsonPath("$.declarationVersion").value("family-guardian-v1"));
    mvc.perform(get(base()+"/family-members").with(adult(owner,OWNER_PHONE))).andExpect(status().isOk())
        .andExpect(jsonPath("$.guardianDeclarationRequired").value(false));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT role FROM tenant_members WHERE tenant_id=? AND actor_key=?",String.class,tenant,ActorKeys.key(owner))).isEqualTo("OWNER");
    mvc.perform(get(base()+"/family-members").with(adult(owner,"+8613900000998"))).andExpect(status().isOk())
        .andExpect(jsonPath("$.guardianDeclarationRequired").value(true));
  }

  @Test void concurrentAcceptanceAndRevocationHaveOneAuthoritativeWinner() throws Exception {
    issue();String key=UUID.randomUUID().toString();var start=new CountDownLatch(1);var workers=Executors.newFixedThreadPool(2);
    try {
      var accepted=workers.submit(()->{start.await();return accept(key).andReturn().getResponse().getStatus();});
      var revoked=workers.submit(()->{start.await();return mvc.perform(delete(base()+"/family-invitations/"+id).with(adult(owner,OWNER_PHONE))).andReturn().getResponse().getStatus();});
      start.countDown();int acceptStatus=accepted.get(15,TimeUnit.SECONDS),revokeStatus=revoked.get(15,TimeUnit.SECONDS);
      assertThat(List.of(acceptStatus,revokeStatus)).isIn(List.of(200,409),List.of(409,204));
      assertThat(db.queryForObject("SELECT COUNT(*) FROM family_phone_invitations WHERE id=? AND consumed_at IS NOT NULL AND revoked_at IS NOT NULL",Integer.class,id)).isZero();
      assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND actor_key=? AND revoked_at IS NULL",Integer.class,tenant,ActorKeys.key(recipient)))
          .isEqualTo(acceptStatus==200?1:0);
    }finally{workers.shutdownNow();}
  }

  @Test void staleSnapshotCountCannotAdmitAnEleventhAdultAfterAnInviteLookup() throws Exception {
    for(int n=0;n<8;n++){
      String member="fixture-"+UUID.randomUUID();
      db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",tenant,member,ActorKeys.key(member));
    }
    issue();String tenth="fixture-"+UUID.randomUUID();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",tenant,tenth,ActorKeys.key(tenth));
    // Model MySQL's older RR consistent read established by the pre-mutex invitation lookup.
    // A locking row read sees the now-current ten members and must deny admission.
    doReturn(9).when(db).queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND revoked_at IS NULL AND role IN ('OWNER','GUARDIAN')",Integer.class,tenant);
    accept(UUID.randomUUID().toString()).andExpect(status().isConflict()).andExpect(jsonPath("$.errorCode").value("FAMILY_MEMBER_LIMIT_REACHED"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(10);
  }

  @Test void nonMembersAndOtherTenantsCannotListOrCancelAndBadTokensAreRateLimited() throws Exception {
    issue();
    mvc.perform(get(base()+"/family-members").with(adult(recipient,RECIPIENT_PHONE))).andExpect(status().isForbidden());
    mvc.perform(get(base()+"/family-invitations").with(adult(recipient,RECIPIENT_PHONE))).andExpect(status().isForbidden());
    mvc.perform(delete("/api/v1/tenants/"+UUID.randomUUID()+"/family-invitations/"+id).with(adult(owner,OWNER_PHONE))).andExpect(status().isForbidden());
    String wrong=json.writeValueAsString(Map.of("invitationId",id,"token",SecretMaterial.token()));
    for(int n=0;n<30;n++)mvc.perform(post("/api/v1/family-invitations/preview").with(adult(recipient,RECIPIENT_PHONE))
        .contentType(MediaType.APPLICATION_JSON).content(wrong)).andExpect(status().isForbidden());
    mvc.perform(post("/api/v1/family-invitations/preview").with(adult(recipient,RECIPIENT_PHONE))
        .contentType(MediaType.APPLICATION_JSON).content(wrong)).andExpect(status().isTooManyRequests());
  }

  String issue() throws Exception {return mvc.perform(post(base()+"/family-invitations").with(adult(owner,OWNER_PHONE))
      .header("Idempotency-Key",issueKey).contentType(MediaType.APPLICATION_JSON).content(issueBody()))
      .andExpect(status().isCreated()).andExpect(jsonPath("$.targetPhoneMasked").value("139****0102"))
      .andReturn().getResponse().getContentAsString();}
  String issueBody() throws Exception {return json.writeValueAsString(Map.of("invitationId",id,"targetPhone","13900000102","token",token));}
  String secretBody() throws Exception {return json.writeValueAsString(Map.of("invitationId",id,"token",token));}
  String acceptBody() throws Exception {return json.writeValueAsString(Map.of("invitationId",id,"token",token,"adultGuardian",true,"declarationVersion","family-guardian-v1"));}
  org.springframework.test.web.servlet.ResultActions accept(String key)throws Exception{return mvc.perform(post("/api/v1/family-invitations/accept").with(adult(recipient,RECIPIENT_PHONE))
      .header("Idempotency-Key",key).contentType(MediaType.APPLICATION_JSON).content(acceptBody()));}
  String base(){return "/api/v1/tenants/"+tenant;}
  JsonNode body(String value)throws Exception{return json.readTree(value);}
  RequestPostProcessor adult(String actor,String phone){return jwt().jwt(j->j.subject(actor).claim("name","监护人").claim("phone_number",phone).claim("phone_number_verified",true)
      .claim("auth_time",Instant.now().getEpochSecond()).claim("amr",List.of("sms"))).authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));}
}

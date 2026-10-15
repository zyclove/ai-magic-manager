package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.*;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:ownershiprecovery;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1","spring.datasource.username=sa","spring.datasource.password="})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class OwnershipRecoveryTest {
  @Autowired MockMvc mvc; @Autowired JdbcTemplate db; @Autowired ObjectMapper json;
  @MockitoBean JwtDecoder decoder;
  RequestPostProcessor actor(String id,boolean fresh) {
    return jwt().jwt(t->t.subject(id).claim("email",id+"@example.test").claim("email_verified",true)
        .claim("auth_time",fresh?Instant.now().getEpochSecond():1L).claim("amr",fresh?List.of("pwd","otp"):List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  JsonNode postJson(String path,String who,Object body,String key,Long version,int expected) throws Exception {
    var r=post(path).with(actor(who,true)).contentType(MediaType.APPLICATION_JSON);
    if(body!=null)r.content(json.writeValueAsString(body));
    if(key!=null)r.header("Idempotency-Key",key);if(version!=null)r.header("If-Match","\""+version+"\"");
    return json.readTree(mvc.perform(r).andExpect(status().is(expected)).andReturn().getResponse().getContentAsString());
  }
  record Fixture(String tenant,String owner,String recipient) { String path(){return "/api/v1/tenants/"+tenant+"/ownership-transfers";} }
  Fixture fixture(String kind) throws Exception {
    String owner="owner-"+UUID.randomUUID(),recipient="recipient-"+UUID.randomUUID();
    String tenant=postJson("/api/v1/tenants",owner,Map.of("name","Ownership fixture","kind",kind,"timeZone","UTC"),null,null,201).get("id").asText();
    var invitation=postJson("/api/v1/tenants/"+tenant+"/invitations",owner,Map.of("role","AUDITOR","recipientEmail",recipient+"@example.test"),null,null,201);
    postJson("/api/v1/invitations/accept",recipient,Map.of("token",invitation.get("token").asText()),null,null,200);
    return new Fixture(tenant,owner,recipient);
  }
  JsonNode query(Fixture f,String who,String key,Object body,int expected) throws Exception {
    var result=mvc.perform(post(f.path()+"/operation-results/"+key+"/query").with(actor(who,false))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body))).andExpect(status().is(expected));
    if(expected==200)result.andExpect(header().string("Cache-Control","no-store"));
    return json.readTree(result.andReturn().getResponse().getContentAsString());
  }
  Map<String,Object> startInput(Fixture f){return Map.of("operation","start","version",0,"targetActorId",f.recipient());}
  Map<String,Object> actionInput(String id,String action){return Map.of("operation",action,"version",0,"transferId",id);}
  @Test void sourceCanRecoverAfterLosingOwnerRoleAndRecipientCanRecoverWithoutFreshMfa() throws Exception {
    var f=fixture("FAMILY");String startKey=UUID.randomUUID().toString(),acceptKey=UUID.randomUUID().toString();
    query(f,f.owner(),startKey,startInput(f),404);
    var start=postJson(f.path(),f.owner(),Map.of("targetActorId",f.recipient()),startKey,0L,201);
    String id=start.get("id").asText();
    postJson(f.path()+"/"+id+"/accept",f.recipient(),null,acceptKey,0L,200);
    long count=db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=?",Long.class,f.tenant());
    var original=query(f,f.owner(),startKey,startInput(f),200);
    assertThat(original.get("original").get("state").asText()).isEqualTo("PENDING");
    assertThat(original.get("current").get("state").asText()).isEqualTo("ACCEPTED");
    assertThat(original.get("currentRole").asText()).isEqualTo("GUARDIAN");
    query(f,f.owner(),acceptKey,actionInput(id,"accept"),404);
    var accepted=query(f,f.recipient(),acceptKey,actionInput(id,"accept"),200);
    assertThat(accepted.get("original").get("state").asText()).isEqualTo("ACCEPTED");
    assertThat(accepted.get("currentRole").asText()).isEqualTo("OWNER");
    postJson(f.path(),f.owner(),Map.of("targetActorId",f.recipient()),startKey,0L,403);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=?",Long.class,f.tenant())).isEqualTo(count);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND role='OWNER' AND revoked_at IS NULL",Integer.class,f.tenant())).isEqualTo(1);
    assertThat(db.queryForList("SELECT DISTINCT response_state FROM idempotency_requests WHERE scope_id=? AND operation LIKE 'ownership.%'",String.class,f.tenant())).containsExactly("NON_SUBJECT");
  }
  @Test void canceledAndDeclinedRequestsHaveIndependentRecoverableResults() throws Exception {
    var f=fixture("ORGANIZATION");
    for(String action:List.of("cancel","decline")){
      String key=UUID.randomUUID().toString(),actionKey=UUID.randomUUID().toString();
      var start=postJson(f.path(),f.owner(),Map.of("targetActorId",f.recipient()),key,0L,201);
      String id=start.get("id").asText(),who=action.equals("cancel")?f.owner():f.recipient();
      postJson(f.path()+"/"+id+"/"+action,who,null,actionKey,0L,200);
      var r=query(f,who,actionKey,actionInput(id,action),200);
      assertThat(r.get("original").get("state").asText()).isEqualTo(action.equals("cancel")?"CANCELLED":"DECLINED");
      assertThat(query(f,f.owner(),key,startInput(f),200).get("current").get("version").asLong()).isEqualTo(1);
    }
  }
  @Test void recoveryEnforcesActorTenantFingerprintMembershipAndErasure() throws Exception {
    var f=fixture("FAMILY");String key=UUID.randomUUID().toString();
    postJson(f.path(),f.owner(),Map.of("targetActorId",f.recipient()),key,0L,201);
    query(f,f.recipient(),key,startInput(f),404);
    query(f,"outsider",key,startInput(f),403);
    var other=fixture("FAMILY");query(other,f.owner(),key,startInput(f),403);
    query(f,f.owner(),key,Map.of("operation","start","version",1,"targetActorId",f.recipient()),409);
    query(f,f.owner(),key,Map.of("operation","start","version",0,"targetActorId",f.recipient(),"transferId",UUID.randomUUID().toString()),400);
    query(f,f.owner(),key,Map.of("operation","unsupported","version",0),400);
    query(f,f.owner(),key,Map.of("operation","start","targetActorId",f.recipient()),400);
    query(f,f.owner(),"invalid",startInput(f),400);
    db.update("UPDATE idempotency_requests SET expires_at=1 WHERE scope_id=? AND operation='ownership.start'",f.tenant());
    query(f,f.owner(),key,startInput(f),200);
    postJson(f.path(),f.owner(),Map.of("targetActorId",f.recipient()),key,0L,409);
    db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL WHERE scope_id=? AND operation='ownership.start'",f.tenant());
    query(f,f.owner(),key,startInput(f),410);
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",f.tenant(),ActorKeys.key(f.owner()));
    query(f,f.owner(),key,startInput(f),403);
  }
  @Test void resultQueryNeverReconcilesPendingStateOrCreatesEvents() throws Exception {
    var f=fixture("FAMILY");String key=UUID.randomUUID().toString();
    var start=postJson(f.path(),f.owner(),Map.of("targetActorId",f.recipient()),key,0L,201);
    // Metadata changes would invalidate a transfer on its ordinary list/detail reconciliation.
    db.update("UPDATE tenants SET version=version+1 WHERE id=?",f.tenant());
    long count=db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=?",Long.class,f.tenant());
    assertThat(query(f,f.owner(),key,startInput(f),200).get("current").get("state").asText()).isEqualTo("PENDING");
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=?",Long.class,f.tenant())).isEqualTo(count);
    mvc.perform(get(f.path()+"/"+start.get("id").asText()).with(actor(f.owner(),false)))
        .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("INVALIDATED"));
    assertThat(query(f,f.owner(),key,startInput(f),200).get("current").get("state").asText()).isEqualTo("INVALIDATED");
  }
}

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

@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:invitationworkflow;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1",
    "spring.datasource.username=sa","spring.datasource.password="})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class InvitationWorkflowTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper json;
  @MockitoBean JwtDecoder decoder;
  RequestPostProcessor actor(String id, boolean recent) {
    return jwt().jwt(t->t.subject(id).claim("email",id+"@example.test").claim("email_verified",true)
        .claim("auth_time",recent?Instant.now().getEpochSecond():1L).claim("amr",recent?List.of("pwd","otp"):List.of("pwd")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  String tenant(String owner, String kind) throws Exception {
    return json.readTree(mvc.perform(post("/api/v1/tenants").with(actor(owner,true)).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("name","Invitation fixture","kind",kind,"timeZone","UTC"))))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
  }
  Map<String,Object> input(String email,String role,List<String> classes) {
    var body=new LinkedHashMap<String,Object>();body.put("recipientEmail",email);body.put("role",role);
    body.put("subjectId",null);body.put("classIds",classes);return body;
  }
  JsonNode issue(String root,String owner,String key,Object body,int expected) throws Exception {
    var result=mvc.perform(post(root+"/issuances").with(actor(owner,true)).header("Idempotency-Key",key)
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body))).andExpect(status().is(expected));
    if(expected==201) result.andExpect(header().string("Cache-Control","no-store"));
    return json.readTree(result.andReturn().getResponse().getContentAsString());
  }
  JsonNode query(String root,String owner,String key,Object body,int expected) throws Exception {
    var result=mvc.perform(post(root+"/issuance-results/"+key+"/query").with(actor(owner,false))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body))).andExpect(status().is(expected));
    if(expected==200) result.andExpect(header().string("Cache-Control","no-store"));
    return json.readTree(result.andReturn().getResponse().getContentAsString());
  }
  @Test void tokenReturnedOnlyOnceAndNeverJournaledAndAcceptanceCannotBeCancelled() throws Exception {
    String owner="owner-"+UUID.randomUUID(),recipient="recipient-"+UUID.randomUUID(),tenant=tenant(owner,"FAMILY"),
        root="/api/v1/tenants/"+tenant+"/invitations",key=UUID.randomUUID().toString();
    var body=input(recipient+"@example.test","GUARDIAN",List.of());
    var first=issue(root,owner,key,body,201);
    String id=first.get("invitation").get("id").asText(),token=first.get("token").asText();
    assertThat(token).matches("[A-Za-z0-9_-]{43}");
    var replay=issue(root,owner,key,body,201);
    assertThat(replay.get("token").isNull()).isTrue();
    assertThat(replay.get("invitation")).isEqualTo(first.get("invitation"));
    assertThat(query(root,owner,key,body,200).get("token").isNull()).isTrue();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM member_invitations WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    String journal=db.queryForObject("SELECT response_body FROM idempotency_requests WHERE scope_id=? AND operation='invitation.issue'",String.class,tenant);
    assertThat(journal).doesNotContain(token,recipient,"subjectId");
    assertThat(db.queryForObject("SELECT response_state FROM idempotency_requests WHERE scope_id=? AND operation='invitation.issue'",String.class,tenant)).isEqualTo("NON_SUBJECT");
    mvc.perform(post("/api/v1/invitations/accept").with(actor(recipient,true)).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("token",token)))).andExpect(status().isOk());
    mvc.perform(delete(root+"/"+id).with(actor(owner,true))).andExpect(status().isConflict())
        .andExpect(jsonPath("$.errorCode").value("INVITATION_ALREADY_ACCEPTED"));
    mvc.perform(get(root+"/"+id).with(actor(owner,false))).andExpect(status().isOk()).andExpect(jsonPath("$.state").value("ACCEPTED"));
    mvc.perform(get(root).with(actor(owner,false))).andExpect(status().isOk()).andExpect(jsonPath("$.items[0].state").value("ACCEPTED"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND actor_key=? AND revoked_at IS NULL",Integer.class,tenant,ActorKeys.key(recipient))).isEqualTo(1);
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=?",tenant);
    assertThat(query(root,owner,key,body,200).get("invitation").get("state").asText()).isEqualTo("ACCEPTED");
    issue(root,owner,key,body,409);
  }
  @Test void normalizedClassScopeAndIdentityAuthorizationArePreserved() throws Exception {
    String owner="owner-"+UUID.randomUUID(),tenant=tenant(owner,"ORGANIZATION"),root="/api/v1/tenants/"+tenant+"/invitations",key=UUID.randomUUID().toString();
    var ids=new ArrayList<String>();
    for(String name:List.of("A","B")) ids.add(json.readTree(mvc.perform(post("/api/v1/tenants/"+tenant+"/classes")
        .with(actor(owner,true)).header("Idempotency-Key",UUID.randomUUID().toString()).contentType(MediaType.APPLICATION_JSON)
        .content(json.writeValueAsString(Map.of("name",name)))).andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText());
    var body=input("Teacher@example.TEST","TEACHER",ids);
    var first=issue(root,owner,key,body,201);
    Collections.reverse(ids);body.put("classIds",ids);body.put("recipientEmail","Teacher@example.test");
    assertThat(query(root,owner,key,body,200).get("invitation")).isEqualTo(first.get("invitation"));
    body.put("recipientEmail","teacher@example.test");query(root,owner,key,body,409);body.put("recipientEmail","Teacher@example.test");
    for(String role:List.of("ORG_ADMIN","TEACHER","AUDITOR","CHILD")) {
      String other=owner+role;
      db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,?)",tenant,other,ActorKeys.key(other),role);
      query(root,other,key,body,role.equals("ORG_ADMIN")?404:403);
      if(!role.equals("ORG_ADMIN")) issue(root,other,UUID.randomUUID().toString(),body,403);
    }
    query(root,"stranger",key,body,403);
    mvc.perform(post(root+"/issuances").with(actor(owner,false)).header("Idempotency-Key",UUID.randomUUID().toString())
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body))).andExpect(status().isUnauthorized())
        .andExpect(jsonPath("$.errorCode").value("REAUTH_REQUIRED"));
    mvc.perform(post(root+"/issuances").contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body))).andExpect(status().isUnauthorized());
    issue(root,owner,UUID.randomUUID().toString(),input("child@example.test","CHILD",List.of()),400);
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_id=?",tenant,owner);
    query(root,owner,key,body,403);
  }
  @Test void cancellationIsRepeatableAndCannotCrossTenantOrEscalateAdminRole() throws Exception {
    String owner="owner-"+UUID.randomUUID(),tenant=tenant(owner,"ORGANIZATION"),root="/api/v1/tenants/"+tenant+"/invitations";
    var first=issue(root,owner,UUID.randomUUID().toString(),input("admin@example.test","ORG_ADMIN",List.of()),201);
    String id=first.get("invitation").get("id").asText(),admin=owner+"admin";
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'ORG_ADMIN')",tenant,admin,ActorKeys.key(admin));
    mvc.perform(delete(root+"/"+id).with(actor(admin,true))).andExpect(status().isForbidden());
    String otherTenant=tenant(owner,"ORGANIZATION");
    mvc.perform(get("/api/v1/tenants/"+otherTenant+"/invitations/"+id).with(actor(owner,true))).andExpect(status().isForbidden());
    for(int i=0;i<2;i++) mvc.perform(delete(root+"/"+id).with(actor(owner,true))).andExpect(status().isNoContent());
    mvc.perform(get(root+"/"+id).with(actor(owner,true))).andExpect(status().isOk()).andExpect(jsonPath("$.state").value("CANCELLED"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='INVITATION_REVOKED'",Integer.class,tenant)).isEqualTo(1);
  }
}

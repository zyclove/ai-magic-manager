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

@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:invitationacceptance;MODE=MySQL;DATABASE_TO_LOWER=TRUE;DB_CLOSE_DELAY=-1","spring.datasource.username=sa","spring.datasource.password="})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class InvitationAcceptanceTest {
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper json;
  @MockitoBean JwtDecoder decoder;
  RequestPostProcessor actor(String id,boolean adult,boolean recent) {
    var identity=jwt().jwt(t->t.subject(id).claim("email",id+"@example.test").claim("email_verified",true)
        .claim("auth_time",recent?Instant.now().getEpochSecond():1L).claim("amr",recent?List.of("pwd","otp"):List.of("pwd")));
    return adult?identity.authorities(new SimpleGrantedAuthority("SCOPE_tenant:create")):identity.authorities(new SimpleGrantedAuthority("SCOPE_openid"));
  }
  JsonNode postJson(String path,RequestPostProcessor actor,Object body,int expected,String key) throws Exception {
    var request=post(path).with(actor).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(body));
    if(key!=null) request.header("Idempotency-Key",key);
    var result=mvc.perform(request).andExpect(status().is(expected));
    if(expected==200&&path.startsWith("/api/v1/invitations/")) result.andExpect(header().string("Cache-Control","no-store"));
    return json.readTree(result.andReturn().getResponse().getContentAsString());
  }
  String tenant(String owner,String kind) throws Exception {
    return postJson("/api/v1/tenants",actor(owner,true,true),Map.of("name","Invitation acceptance fixture","kind",kind,"timeZone","UTC"),201,null).get("id").asText();
  }
  JsonNode invite(String tenant,String owner,String receiver,String role,String subject,List<String> classes) throws Exception {
    var input=new LinkedHashMap<String,Object>();input.put("recipientEmail",receiver+"@example.test");input.put("role",role);input.put("subjectId",subject);input.put("classIds",classes);
    return postJson("/api/v1/tenants/"+tenant+"/invitations",actor(owner,true,true),input,201,null);
  }
  JsonNode preview(JsonNode invitation,String receiver,boolean adult,int status) throws Exception {
    return postJson("/api/v1/invitations/preview",actor(receiver,adult,false),Map.of("token",invitation.get("token").asText()),status,null);
  }
  JsonNode accept(JsonNode invitation,String receiver,boolean adult,boolean recent,String key,int status) throws Exception {
    return postJson("/api/v1/invitations/acceptances",actor(receiver,adult,recent),Map.of("invitationId",invitation.get("id").asText(),"token",invitation.get("token").asText()),status,key);
  }
  JsonNode query(JsonNode invitation,String receiver,String key,int status) throws Exception {
    var response=mvc.perform(get("/api/v1/invitations/"+invitation.get("id").asText()+"/acceptance-results/"+key)
        .with(actor(receiver,false,false))).andExpect(status().is(status));
    if(status==200) response.andExpect(header().string("Cache-Control","no-store"));
    return json.readTree(response.andReturn().getResponse().getContentAsString());
  }
  @Test void previewDoesNotJoinAndRecoverySeparatesHistoricalSuccessFromRevocationAndRejoin() throws Exception {
    String owner="owner-"+UUID.randomUUID(),receiver="receiver-"+UUID.randomUUID(),tenant=tenant(owner,"ORGANIZATION"),key=UUID.randomUUID().toString();
    String classroom=postJson("/api/v1/tenants/"+tenant+"/classes",actor(owner,true,true),Map.of("name","Class A"),201,UUID.randomUUID().toString()).get("id").asText();
    var invitation=invite(tenant,owner,receiver,"TEACHER",null,List.of(classroom));
    var view=preview(invitation,receiver,true,200);
    assertThat(view.get("classes").get(0).get("name").asText()).isEqualTo("Class A");
    assertThat(view.get("requiresRecentAuthentication").asBoolean()).isTrue();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
    preview(invitation,"wrong",true,403);preview(invitation,receiver,false,403);
    query(invitation,receiver,key,404);
    accept(invitation,receiver,true,false,key,401);
    var accepted=accept(invitation,receiver,true,true,key,200);
    assertThat(accepted.get("accepted").get("memberVersion").asLong()).isZero();
    assertThat(accept(invitation,receiver,true,true,key,200)).isEqualTo(accepted);
    String journal=db.queryForObject("SELECT response_body FROM idempotency_requests WHERE scope_id=? AND operation='invitation.accept'",String.class,tenant);
    assertThat(journal).doesNotContain(invitation.get("token").asText(),receiver+"@example.test","Class A");
    query(invitation,"another-actor",key,404);
    mvc.perform(delete("/api/v1/tenants/"+tenant+"/members/"+ActorKeys.key(receiver)+"/access")
        .with(actor(owner,true,true)).header("If-Match","\"0\"").header("Idempotency-Key",UUID.randomUUID().toString())).andExpect(status().isNoContent());
    var after=query(invitation,receiver,key,200);
    assertThat(after.get("current").get("state").asText()).isEqualTo("REVOKED");
    assertThat(after.get("accepted")).isEqualTo(accepted.get("accepted"));
    assertThat(accept(invitation,receiver,true,true,key,200).get("current").get("state").asText()).isEqualTo("REVOKED");
    var newInvite=invite(tenant,owner,receiver,"AUDITOR",null,List.of());
    accept(newInvite,receiver,true,true,UUID.randomUUID().toString(),200);
    after=query(invitation,receiver,key,200);
    assertThat(after.get("current").get("role").asText()).isEqualTo("AUDITOR");
    assertThat(after.get("current").get("version").asLong()).isEqualTo(2);
    assertThat(after.get("accepted").get("role").asText()).isEqualTo("TEACHER");
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=? AND operation='invitation.accept'",tenant);
    query(invitation,receiver,key,200);accept(invitation,receiver,true,true,key,409);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=? AND action='MEMBER_JOINED'",Integer.class,tenant)).isEqualTo(2);
  }
  @Test void previewAndAcceptanceRevalidateIssuerAndScope() throws Exception {
    String owner="owner-"+UUID.randomUUID(),receiver="receiver-"+UUID.randomUUID(),tenant=tenant(owner,"ORGANIZATION");
    String classroom=postJson("/api/v1/tenants/"+tenant+"/classes",actor(owner,true,true),Map.of("name","Class A"),201,UUID.randomUUID().toString()).get("id").asText();
    var invitation=invite(tenant,owner,receiver,"TEACHER",null,List.of(classroom));
    preview(invitation,receiver,true,200);
    db.update("UPDATE organization_classes SET archived_at=1 WHERE tenant_id=? AND id=?",tenant,classroom);
    preview(invitation,receiver,true,400);accept(invitation,receiver,true,true,UUID.randomUUID().toString(),400);
    db.update("UPDATE organization_classes SET archived_at=NULL WHERE tenant_id=? AND id=?",tenant,classroom);
    db.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_id=?",tenant,owner);
    preview(invitation,receiver,true,403);accept(invitation,receiver,true,true,UUID.randomUUID().toString(),403);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=? AND actor_id=?",Integer.class,tenant,receiver)).isZero();
  }
  @Test void childInvitationUsesAssignedSubjectAndErasedResultsCannotBeRecovered() throws Exception {
    String owner="owner-"+UUID.randomUUID(),child="child-"+UUID.randomUUID(),tenant=tenant(owner,"FAMILY"),key=UUID.randomUUID().toString();
    String subject=postJson("/api/v1/tenants/"+tenant+"/subjects",actor(owner,true,true),Map.of("nickname","Child","ageBand","AGE_7_12"),201,null).get("id").asText();
    var invitation=invite(tenant,owner,child,"CHILD",subject,List.of());
    var view=preview(invitation,child,false,200);assertThat(view.get("subjectName").asText()).isEqualTo("Child");
    assertThat(view.get("requiresRecentAuthentication").asBoolean()).isFalse();
    accept(invitation,child,false,false,key,200);
    assertThat(db.queryForObject("SELECT response_state FROM idempotency_requests WHERE scope_id=? AND operation='invitation.accept'",String.class,tenant)).isEqualTo("SCOPED");
    assertThat(db.queryForObject("SELECT subject_id FROM tenant_members WHERE tenant_id=? AND actor_id=?",String.class,tenant,child)).isEqualTo(subject);
    db.update("UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL WHERE scope_id=? AND operation='invitation.accept'",tenant);
    query(invitation,child,key,410);accept(invitation,child,false,false,key,410);
  }
  @Test void cancelledExpiredWrongTargetAndUnverifiedRecipientCannotJoin() throws Exception {
    String owner="owner-"+UUID.randomUUID(),receiver="receiver-"+UUID.randomUUID(),tenant=tenant(owner,"FAMILY");
    var invitation=invite(tenant,owner,receiver,"GUARDIAN",null,List.of());
    preview(invitation,receiver,true,200);
    postJson("/api/v1/invitations/acceptances",actor(receiver,true,true),Map.of("invitationId",UUID.randomUUID().toString(),"token",invitation.get("token").asText()),403,UUID.randomUUID().toString());
    mvc.perform(post("/api/v1/invitations/preview").with(jwt().jwt(t->t.subject(receiver).claim("email",receiver+"@example.test").claim("email_verified",false)))
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("token",invitation.get("token").asText())))).andExpect(status().isForbidden());
    mvc.perform(delete("/api/v1/tenants/"+tenant+"/invitations/"+invitation.get("id").asText()).with(actor(owner,true,true))).andExpect(status().isNoContent());
    accept(invitation,receiver,true,true,UUID.randomUUID().toString(),409);
    var expired=invite(tenant,owner,receiver,"GUARDIAN",null,List.of());
    db.update("UPDATE member_invitations SET expires_at=0 WHERE id=?",expired.get("id").asText());
    preview(expired,receiver,true,409);accept(expired,receiver,true,true,UUID.randomUUID().toString(),409);
    mvc.perform(post("/api/v1/invitations/preview").contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of("token",invitation.get("token").asText())))).andExpect(status().isUnauthorized());
    assertThat(db.queryForObject("SELECT COUNT(*) FROM tenant_members WHERE tenant_id=?",Integer.class,tenant)).isEqualTo(1);
  }
}

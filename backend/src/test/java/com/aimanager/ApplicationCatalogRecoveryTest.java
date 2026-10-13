package com.aimanager;

import com.aimanager.identity.ActorKeys;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:catalog-recovery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc
class ApplicationCatalogRecoveryTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  private RequestPostProcessor actor(String id) {
    return jwt().jwt(t -> t.subject(id).claim("auth_time", Instant.now().getEpochSecond()).claim("amr", List.of("pwd","otp")))
        .authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  private String[] fixture() throws Exception {
    String owner = UUID.randomUUID().toString();
    var tenant = mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor(owner)).contentType(MediaType.APPLICATION_JSON)
        .content("{\"name\":\"目录验证\",\"kind\":\"FAMILY\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
    return new String[]{owner, tenant, "/api/v1/tenants/" + tenant + "/applications"};
  }
  private Map<String,Object> definition(String digest) {
    return Map.of("displayName","学习应用","platform","ANDROID","profile","PRIMARY","packageName","org.example.Reader","signingDigests",List.of(digest.repeat(64)));
  }
  private JsonNode create(String[] f, String key, Map<String,Object> data) throws Exception {
    return mapper.readTree(mvc.perform(post(f[2]).with(actor(f[0])).header("Idempotency-Key",key).contentType(MediaType.APPLICATION_JSON)
        .content(mapper.writeValueAsString(data))).andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
  }
  @Test void declarationRecoveryMatchesOriginalIdentityAfterIdempotencyExpiry() throws Exception {
    var f = fixture(); String key = UUID.randomUUID().toString(); var data = definition("a"); var app = create(f,key,data);
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=? AND operation='application.create'",f[1]);
    String url = f[2]+"/creation-results/"+key+"/query";
    for (int i=0;i<2;i++) {
      var result = mapper.readTree(mvc.perform(post(url).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(data)))
          .andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store")).andReturn().getResponse().getContentAsString());
      assertThat(result).isEqualTo(app);
    }
    mvc.perform(post(url).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(definition("b"))))
        .andExpect(status().isConflict());
    assertThat(db.queryForObject("SELECT COUNT(*) FROM application_definitions WHERE tenant_id=?",Integer.class,f[1])).isEqualTo(1);
    assertThat(db.queryForObject("SELECT MAX(expires_at) FROM idempotency_requests WHERE scope_id=? AND operation='application.create'",Long.class,f[1])).isZero();
  }
  @Test void classificationRecoverySeparatesHistoricalCategoryFromSharedCurrentState() throws Exception {
    var f = fixture(); var first = create(f,UUID.randomUUID().toString(),definition("a"));
    var second = create(f,UUID.randomUUID().toString(),definition("b"));
    String path = f[2]+"/"+first.get("id").asText()+"/classification", key = UUID.randomUUID().toString();
    mvc.perform(put(path).with(actor(f[0])).header("If-Match","\"0\"").header("Idempotency-Key",key)
        .contentType(MediaType.APPLICATION_JSON).content("{\"category\":\"EDUCATION\"}")).andExpect(status().isOk());
    mvc.perform(put(f[2]+"/"+second.get("id").asText()+"/classification").with(actor(f[0])).header("If-Match","\"1\"")
        .contentType(MediaType.APPLICATION_JSON).content("{\"category\":\"OTHER\"}")).andExpect(status().isOk());
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=? AND operation='application.classification'",f[1]);
    String query = path+"/operation-results/"+key+"/query";
    mvc.perform(post(query).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content("{\"version\":0,\"category\":\"EDUCATION\"}"))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store"))
        .andExpect(jsonPath("$.committed.category").value("EDUCATION")).andExpect(jsonPath("$.committed.version").value(1))
        .andExpect(jsonPath("$.current.category").value("OTHER")).andExpect(jsonPath("$.current.version").value(2));
    mvc.perform(post(query).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content("{\"version\":1,\"category\":\"EDUCATION\"}"))
        .andExpect(status().isConflict());
    mvc.perform(post(f[2]+"/"+second.get("id").asText()+"/classification/operation-results/"+key+"/query").with(actor(f[0]))
        .contentType(MediaType.APPLICATION_JSON).content("{\"version\":0,\"category\":\"EDUCATION\"}")).andExpect(status().isConflict());
    assertThat(db.queryForObject("SELECT MAX(version) FROM application_classifications WHERE tenant_id=?",Long.class,f[1])).isEqualTo(2);
  }
  @Test void lookupsAreScopedToOriginalActorAndCurrentWriteRole() throws Exception {
    var f = fixture(); String key = UUID.randomUUID().toString(); var data = definition("a"); var app = create(f,key,data);
    String create = f[2]+"/creation-results/"+key+"/query";
    String classification = f[2]+"/"+app.get("id").asText()+"/classification";
    mvc.perform(put(classification).with(actor(f[0])).header("If-Match","\"0\"").header("Idempotency-Key",key)
        .contentType(MediaType.APPLICATION_JSON).content("{\"category\":\"GAMES\"}")).andExpect(status().isOk());
    String other = UUID.randomUUID().toString();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",f[1],other,ActorKeys.key(other));
    for (String who : List.of(other,"outsider")) {
      mvc.perform(post(create).with(actor(who)).contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(data)))
          .andExpect(status().is(who.equals(other)?404:403));
      mvc.perform(post(classification+"/operation-results/"+key+"/query").with(actor(who)).contentType(MediaType.APPLICATION_JSON)
          .content("{\"version\":0,\"category\":\"GAMES\"}")).andExpect(status().is(who.equals(other)?404:403));
    }
    var foreign = fixture();
    mvc.perform(post(foreign[2]+"/creation-results/"+key+"/query").with(actor(foreign[0])).contentType(MediaType.APPLICATION_JSON)
        .content(mapper.writeValueAsString(data))).andExpect(status().isNotFound());
    db.update("UPDATE tenant_members SET role='AUDITOR' WHERE tenant_id=? AND actor_key=?",f[1],ActorKeys.key(f[0]));
    mvc.perform(post(create).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(data))).andExpect(status().isForbidden());
    mvc.perform(post(classification+"/operation-results/"+key+"/query").with(actor(f[0])).contentType(MediaType.APPLICATION_JSON)
        .content("{\"version\":0,\"category\":\"GAMES\"}")).andExpect(status().isForbidden());
  }
}

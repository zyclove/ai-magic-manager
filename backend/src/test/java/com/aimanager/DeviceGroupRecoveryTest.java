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

/** Original-result recovery is read-only, scoped and separate from later group changes. */
@SpringBootTest(properties = {
    "spring.datasource.url=jdbc:h2:mem:group-recovery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa", "spring.datasource.password=", "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc
class DeviceGroupRecoveryTest {
  @Autowired MockMvc mvc;
  @Autowired ObjectMapper mapper;
  @Autowired JdbcTemplate db;
  @MockitoBean JwtDecoder decoder;
  private RequestPostProcessor actor(String id) {
    return jwt().jwt(t -> t.subject(id).claim("auth_time", Instant.now().getEpochSecond())
        .claim("amr", List.of("pwd", "otp"))).authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"));
  }
  private String[] fixture() throws Exception {
    String owner = UUID.randomUUID().toString();
    var tenant = mapper.readTree(mvc.perform(post("/api/v1/tenants").with(actor(owner))
        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"机构\",\"kind\":\"ORGANIZATION\",\"timeZone\":\"Asia/Shanghai\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
    return new String[]{owner, tenant, "/api/v1/tenants/" + tenant + "/device-groups"};
  }
  private JsonNode create(String[] f, String key) throws Exception {
    return mapper.readTree(mvc.perform(post(f[2]).with(actor(f[0])).header("Idempotency-Key", key)
        .contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"班级设备\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString());
  }
  private JsonNode query(String[] f, String key, Map<String, ?> body) throws Exception {
    return mapper.readTree(mvc.perform(post(f[2] + "/operation-results/" + key + "/query").with(actor(f[0]))
        .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(body)))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
        .andReturn().getResponse().getContentAsString());
  }
  @Test void recoveryKeepsCommittedAndCurrentVersionsDistinctAfterReplayExpiry() throws Exception {
    var f = fixture(); String key = UUID.randomUUID().toString(); var group = create(f, key);
    String id = group.get("id").asText(), renameKey = UUID.randomUUID().toString();
    mvc.perform(patch(f[2] + "/" + id).with(actor(f[0])).header("If-Match", "\"0\"")
        .header("Idempotency-Key", renameKey).contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"新组名\"}"))
        .andExpect(status().isOk());
    db.update("UPDATE idempotency_requests SET expires_at=0 WHERE scope_id=?", f[1]);
    for (int i=0; i<2; i++) {
      var recovered = query(f, key, Map.of("operation", "CREATE", "name", "班级设备"));
      assertThat(recovered.get("committed")).isEqualTo(group);
      assertThat(recovered.get("current").get("version").asInt()).isEqualTo(1);
      assertThat(recovered.get("current").get("name").asText()).isEqualTo("新组名");
    }
    assertThat(query(f, renameKey, Map.of("operation", "RENAME", "groupId", id, "version", 0, "name", "新组名"))
        .get("committed").get("version").asInt()).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM device_groups WHERE tenant_id=?", Integer.class, f[1])).isEqualTo(1);
    assertThat(db.queryForObject("SELECT MAX(expires_at) FROM idempotency_requests WHERE scope_id=?", Long.class, f[1])).isZero();
  }
  @Test void recoveryRejectsForeignActorTenantPayloadAndDowngradedRole() throws Exception {
    var f = fixture(); String key = UUID.randomUUID().toString(); create(f, key);
    String url = f[2] + "/operation-results/" + key + "/query";
    String body = "{\"operation\":\"CREATE\",\"name\":\"班级设备\"}";
    mvc.perform(post(url).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content(body.replace("班级设备", "别的组")))
        .andExpect(status().isConflict());
    String other = UUID.randomUUID().toString();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'ORG_ADMIN')", f[1], other, ActorKeys.key(other));
    mvc.perform(post(url).with(actor(other)).contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isNotFound());
    mvc.perform(post(url).with(actor("outsider")).contentType(MediaType.APPLICATION_JSON).content(body))
        .andExpect(status().isForbidden());
    var foreign = fixture();
    mvc.perform(post(foreign[2] + "/operation-results/" + key + "/query").with(actor(foreign[0]))
        .contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isNotFound());
    db.update("UPDATE tenant_members SET role='AUDITOR' WHERE tenant_id=? AND actor_key=?", f[1], ActorKeys.key(f[0]));
    mvc.perform(post(url).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content(body)).andExpect(status().isForbidden());
  }
  @Test void batchAddRemoveAndArchiveRecoveryNeverReapplyHistoricalMembership() throws Exception {
    var f = fixture(); String id = create(f, UUID.randomUUID().toString()).get("id").asText();
    String subject = mapper.readTree(mvc.perform(post("/api/v1/tenants/" + f[1] + "/subjects").with(actor(f[0]))
        .contentType(MediaType.APPLICATION_JSON).content("{\"nickname\":\"学生\",\"ageBand\":\"AGE_7_12\"}"))
        .andExpect(status().isCreated()).andReturn().getResponse().getContentAsString()).get("id").asText();
    String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
    db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) "
        + "VALUES(?,?,?,?,?,'ANDROID','14','ACTIVE','{}','fixture',?)", f[1], device, subject, registration, "验证设备", Instant.now().toEpochMilli());
    var targets = List.of(Map.of("deviceId", device, "registrationId", registration));
    String add = UUID.randomUUID().toString(), remove = UUID.randomUUID().toString(), archive = UUID.randomUUID().toString();
    mvc.perform(post(f[2] + "/" + id + "/devices/batches").with(actor(f[0])).header("If-Match", "\"0\"").header("Idempotency-Key", add)
        .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("devices", targets)))).andExpect(status().isOk());
    mvc.perform(post(f[2] + "/" + id + "/devices/removals").with(actor(f[0])).header("If-Match", "\"1\"").header("Idempotency-Key", remove)
        .contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(Map.of("devices", targets)))).andExpect(status().isOk());
    mvc.perform(post(f[2] + "/" + id + "/archive").with(actor(f[0])).header("If-Match", "\"2\"").header("Idempotency-Key", archive))
        .andExpect(status().isOk());
    var added = query(f, add, Map.of("operation", "ADD", "groupId", id, "version", 0, "devices", targets));
    assertThat(added.get("committed").get("deviceCount").asInt()).isEqualTo(1);
    assertThat(added.get("current").get("deviceCount").asInt()).isZero();
    assertThat(added.get("current").get("state").asText()).isEqualTo("ARCHIVED");
    assertThat(query(f, remove, Map.of("operation", "REMOVE", "groupId", id, "version", 1, "devices", targets))
        .get("committed").get("version").asInt()).isEqualTo(2);
    query(f, archive, Map.of("operation", "ARCHIVE", "groupId", id, "version", 2));
    var wrong = List.of(Map.of("deviceId", device, "registrationId", UUID.randomUUID().toString()));
    mvc.perform(post(f[2] + "/operation-results/" + add + "/query").with(actor(f[0])).contentType(MediaType.APPLICATION_JSON)
        .content(mapper.writeValueAsString(Map.of("operation", "ADD", "groupId", id, "version", 0, "devices", wrong))))
        .andExpect(status().isConflict());
    assertThat(db.queryForObject("SELECT COUNT(*) FROM device_group_members WHERE tenant_id=?", Integer.class, f[1])).isZero();
    assertThat(db.queryForObject("SELECT state FROM devices WHERE tenant_id=? AND id=?", String.class, f[1], device)).isEqualTo("ACTIVE");
  }
  @Test void invalidAndMissingQueriesDoNotAllocateOperationJournalRows() throws Exception {
    var f = fixture(); String url = f[2] + "/operation-results/" + UUID.randomUUID() + "/query";
    mvc.perform(post(url).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content("{\"operation\":\"CREATE\",\"name\":\"不存在\"}"))
        .andExpect(status().isNotFound());
    for (var input : List.of(Map.of("operation", "CREATE", "name", "错误", "version", 1),
        Map.of("operation", "ARCHIVE"), Map.of("operation", "ADD", "groupId", UUID.randomUUID().toString(), "version", 0, "devices", List.of()))) {
      mvc.perform(post(url).with(actor(f[0])).contentType(MediaType.APPLICATION_JSON).content(mapper.writeValueAsString(input)))
          .andExpect(status().isBadRequest());
    }
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=? AND operation LIKE 'device.group.%'", Integer.class, f[1])).isZero();
  }
}

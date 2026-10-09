package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.shared.SecretMaterial;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.BadJwtException;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

/** Real opaque credential security chain. Fixtures do not certify OS enforcement or enrollment. */
@SpringBootTest(properties = {
  "spring.datasource.url=${ACCESS_CONTEXT_TEST_DATABASE_URL:jdbc:h2:mem:accesscontext;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE}",
  "spring.datasource.username=${ACCESS_CONTEXT_TEST_DATABASE_USERNAME:sa}",
  "spring.datasource.password=${ACCESS_CONTEXT_TEST_DATABASE_PASSWORD:}",
  "spring.flyway.enabled=true"
})
@AutoConfigureMockMvc(print = MockMvcPrint.NONE)
class DeviceAccessContextJourneyTest {
  private static final String ROUTE = "/api/v1/device-api/access-context";
  @Autowired MockMvc mvc;
  @Autowired JdbcTemplate db;
  @Autowired ObjectMapper mapper;
  @Autowired DeviceCredentials credentials;
  @MockitoBean JwtDecoder decoder;

  @BeforeEach void rejectUserDecoder() {
    when(decoder.decode(anyString())).thenThrow(new BadJwtException("Not a user credential"));
  }

  private Binding binding() {
    String tenant = UUID.randomUUID().toString(), subject = UUID.randomUUID().toString();
    String device = UUID.randomUUID().toString(), registration = UUID.randomUUID().toString();
    String credential = UUID.randomUUID().toString(), token = SecretMaterial.token();
    long now = Instant.now().toEpochMilli();
    db.update("INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'fixture','FAMILY','UTC',?)", tenant, now);
    db.update("INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at) VALUES(?,?,'private nickname','AGE_7_12',?)", tenant, subject, now);
    db.update("INSERT INTO devices(tenant_id,id,subject_id,registration_id,display_name,platform,os_version,state,public_key_jwk,key_thumbprint,created_at) VALUES(?,?,?,?,'private device','ANDROID','14','ACTIVE','{}','fixture',?)", tenant, device, subject, registration, now);
    db.update("INSERT INTO device_credential_scopes(tenant_id,registration_id,device_id,active) VALUES(?,?,?,true)", tenant, registration, device);
    db.update("INSERT INTO device_credentials(id,tenant_id,device_id,registration_id,token_hash,active,issued_at,expires_at) VALUES(?,?,?,?,?,true,?,?)", credential, tenant, device, registration, SecretMaterial.hash(token), now, now + 3600000);
    return new Binding(tenant, subject, device, registration, credential, token);
  }

  @Test void returnsOnlyCredentialBoundFactsAndNeverCachesThem() throws Exception {
    var b = binding(); var other = binding();
    var response = mvc.perform(get(ROUTE).header("Authorization", "Bearer " + b.token())
        .param("tenantId", other.tenant()).param("subjectId", other.subject()).param("deviceId", other.device()))
        .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
        .andReturn().getResponse().getContentAsString();
    var json = mapper.readTree(response);
    var fields = new java.util.HashSet<String>(); json.fieldNames().forEachRemaining(fields::add);
    assertThat(fields).isEqualTo(Set.of("tenantId", "subjectId", "deviceId", "registrationId"));
    assertThat(json.get("tenantId").asText()).isEqualTo(b.tenant());
    assertThat(json.get("subjectId").asText()).isEqualTo(b.subject());
    assertThat(json.get("deviceId").asText()).isEqualTo(b.device());
    assertThat(json.get("registrationId").asText()).isEqualTo(b.registration());
    assertThat(response).doesNotContain("private", b.token(), b.credential(), other.tenant(), other.subject());
  }

  @Test void requiresDeviceCredentialAndDoesNotAcceptAdministratorAuthority() throws Exception {
    mvc.perform(get(ROUTE)).andExpect(status().isUnauthorized());
    mvc.perform(get(ROUTE).with(jwt().authorities(new SimpleGrantedAuthority("SCOPE_tenant:create"))))
        .andExpect(status().isForbidden());
  }

  @Test void pendingRotationCredentialCannotOperate() throws Exception {
    var b = binding();
    var pending = credentials.rotate(new DeviceContext(b.tenant(), b.device(), b.registration(), b.credential()));
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + pending.credential())).andExpect(status().isForbidden());
  }

  @Test void revokedAndExpiredCredentialsAreRejected() throws Exception {
    var b = binding(); db.update("UPDATE device_credentials SET revoked_at=? WHERE id=?", Instant.now().toEpochMilli(), b.credential());
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + b.token())).andExpect(status().isUnauthorized());
    var expired = binding(); db.update("UPDATE device_credentials SET expires_at=1 WHERE id=?", expired.credential());
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + expired.token())).andExpect(status().isUnauthorized());
  }

  @Test void inactiveDeviceAndRevokedRegistrationCannotReadContext() throws Exception {
    var b = binding(); db.update("UPDATE devices SET state='REVOKED' WHERE tenant_id=? AND id=?", b.tenant(), b.device());
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + b.token())).andExpect(status().isForbidden());
    var revoked = binding(); db.update("UPDATE device_credential_scopes SET active=false,revoked_at=? WHERE tenant_id=? AND registration_id=?", Instant.now().toEpochMilli(), revoked.tenant(), revoked.registration());
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + revoked.token())).andExpect(status().isUnauthorized());
  }

  @Test void archivedSubjectIsNotAnActiveAccessBinding() throws Exception {
    var b = binding(); db.update("UPDATE subjects SET archived_at=? WHERE tenant_id=? AND id=?", Instant.now().toEpochMilli(), b.tenant(), b.subject());
    mvc.perform(get(ROUTE).header("Authorization", "Bearer " + b.token())).andExpect(status().isForbidden());
  }

  @Test void endpointIsReadOnly() throws Exception {
    var b = binding();
    mvc.perform(post(ROUTE).header("Authorization", "Bearer " + b.token())).andExpect(status().isMethodNotAllowed());
  }

  private record Binding(String tenant, String subject, String device, String registration, String credential, String token) {}
}

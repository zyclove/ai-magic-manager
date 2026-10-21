package com.aimanager.identityproviders.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import java.time.Instant;
import java.util.List;
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

/** Client operation IDs must be readable by the same strict production guardian parser. */
@SpringBootTest(properties={
    "spring.datasource.url=jdbc:h2:mem:identity-provider-uuid;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa","spring.datasource.password=","manager.exports.worker.enabled=false",
    "manager.report-jobs.worker.enabled=false","manager.diagnostic-packages.worker.enabled=false",
    "manager.identity-providers.environment-id=uuid-test"})
@AutoConfigureMockMvc
class IdentityProviderUuidJourneyTest {
  @DynamicPropertySource static void properties(DynamicPropertyRegistry p){IdentityProviderAdminJourneyTest.properties(p);}
  @Autowired MockMvc mvc;@Autowired JdbcTemplate db;@MockitoBean JwtDecoder decoder;
  @Test void rejectsNilClientIdBeforeAnyPersistedMutation()throws Exception{reject("00000000-0000-0000-0000-000000000000");}
  @Test void rejectsVersionOneClientIdBeforeAnyPersistedMutation()throws Exception{reject("f47ac10b-58cc-11cf-a447-001122334455");}
  private void reject(String id)throws Exception{
    int count=db.queryForObject("SELECT COUNT(*) FROM identity_provider_versions",Integer.class);
    long base=db.queryForObject("SELECT COALESCE(MAX(version),0) FROM identity_provider_heads WHERE environment_id='uuid-test'",Long.class);
    mvc.perform(post("/api/v1/platform/identity-providers/versions").with(jwt().jwt(j->j.subject("uuid-admin").claim("amr",List.of("mfa")).claim("auth_time",Instant.now()))
        .authorities(new SimpleGrantedAuthority("SCOPE_identity-config:manage"))).contentType(MediaType.APPLICATION_JSON)
        .content("{\"id\":\""+id+"\",\"baseVersion\":"+base+",\"settings\":{},\"replacements\":{}}"))
        .andExpect(status().isBadRequest()).andExpect(jsonPath("$.errorCode").value("IDENTITY_PROVIDER_INVALID_INPUT"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_versions",Integer.class)).isEqualTo(count);
  }
}

package com.aimanager.identityproviders.internal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import java.time.Instant;
import java.util.List;
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

@SpringBootTest(properties={
    "spring.datasource.url=jdbc:h2:mem:identity-provider-unavailable;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE",
    "spring.datasource.username=sa","spring.datasource.password=","manager.exports.worker.enabled=false",
    "manager.report-jobs.worker.enabled=false","manager.diagnostic-packages.worker.enabled=false",
    "manager.identity-providers.key-file=","manager.identity-providers.release-directory=",
    "manager.identity-providers.environment-id=isolated-disabled"})
@AutoConfigureMockMvc
class IdentityProviderUnavailableJourneyTest {
  static final String ROOT="/api/v1/platform/identity-providers";
  @Autowired MockMvc mvc;@Autowired JdbcTemplate db;@MockitoBean JwtDecoder decoder;
  @Test void absentVaultAndDirectoryAreAnHonestReadableBlockedState()throws Exception{
    mvc.perform(get(ROOT+"/status").with(jwt().jwt(j->j.subject("admin").claim("amr",List.of("mfa")).claim("auth_time",Instant.now()))
        .authorities(new SimpleGrantedAuthority("SCOPE_identity-config:read"))))
        .andExpect(status().isOk()).andExpect(jsonPath("$.latestVersion").value(0))
        .andExpect(jsonPath("$.capabilities.secretStorageReady").value(false))
        .andExpect(jsonPath("$.capabilities.releasePreparationReady").value(false))
        .andExpect(jsonPath("$.runtimeStatus").value("APPLY_REQUIRED")).andExpect(jsonPath("$.salesAllowed").value(false));
  }
  @Test void missingKeyNeverSavesPlaintextOrAnyVersionOrAudit()throws Exception{
    mvc.perform(post(ROOT+"/versions").with(jwt().jwt(j->j.subject("admin").claim("amr",List.of("mfa")).claim("auth_time",Instant.now()))
        .authorities(new SimpleGrantedAuthority("SCOPE_identity-config:manage"))).contentType(MediaType.APPLICATION_JSON)
        .content("{\"id\":\""+UUID.randomUUID()+"\",\"baseVersion\":0,\"settings\":{},\"replacements\":{}}"))
        .andExpect(status().isServiceUnavailable()).andExpect(jsonPath("$.errorCode").value("IDENTITY_PROVIDER_VAULT_UNAVAILABLE"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_versions",Integer.class)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM identity_provider_audit_events",Integer.class)).isZero();
  }
}

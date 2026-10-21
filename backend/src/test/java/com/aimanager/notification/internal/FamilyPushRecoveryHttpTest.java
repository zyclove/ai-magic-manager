package com.aimanager.notification.internal;

import static org.assertj.core.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import com.aimanager.identity.ActorKeys;
import java.time.Clock;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

@SpringBootTest(properties={"spring.datasource.url=jdbc:h2:mem:family-push-recovery;MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE","spring.datasource.username=sa","spring.datasource.password=","manager.exports.worker.enabled=false","manager.report-jobs.worker.enabled=false","manager.diagnostic-packages.worker.enabled=false"})
@AutoConfigureMockMvc
class FamilyPushRecoveryHttpTest {
  @Autowired MockMvc mvc; @Autowired JdbcTemplate jdbc; @Autowired FamilyPushService push;
  @Autowired PlatformTransactionManager manager; @Autowired Clock clock;
  @MockitoBean JwtDecoder decoder;
  String tenant,owner,installation;
  @BeforeEach void installation() {
    tenant=UUID.randomUUID().toString();owner="push-recovery-"+UUID.randomUUID();installation=UUID.randomUUID().toString();
    jdbc.update("INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'Recovery','FAMILY','Asia/Shanghai',?)",tenant,clock.millis());
    jdbc.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'GUARDIAN')",tenant,owner,ActorKeys.key(owner));
    new TransactionTemplate(manager).executeWithoutResult(status->push.register(tenant,owner,installation,new FamilyPushService.Registration("ALIYUN","ANDROID","token-"+installation,true,true)));
  }
  @Test void formerMemberCanOnlyRevokeOwnInstallationWithoutOldFamilyAuthority()throws Exception {
    jdbc.update("UPDATE tenant_members SET role='CHILD',revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?",tenant,ActorKeys.key(owner));
    mvc.perform(delete(path()).with(jwt().jwt(t->t.subject(owner)))).andExpect(status().isNoContent()).andExpect(header().string("Cache-Control","no-store"));
    assertThat(jdbc.queryForObject("SELECT provider_token FROM family_push_installations WHERE installation_id=?",String.class,installation)).isNull();
    mvc.perform(delete(path()).with(jwt().jwt(t->t.subject(owner)))).andExpect(status().isNoContent());
  }
  @Test void strangerCannotRevokeOrLearnTokenAndAnonymousCannotUseRecoveryRoute()throws Exception {
    mvc.perform(delete(path()).with(jwt().jwt(t->t.subject("stranger")))).andExpect(status().isForbidden());
    assertThat(jdbc.queryForObject("SELECT provider_token FROM family_push_installations WHERE installation_id=?",String.class,installation)).isEqualTo("token-"+installation);
    mvc.perform(delete(path())).andExpect(status().isUnauthorized());
  }
  @Test void unknownInstallationRevocationIsIdempotentAndPreferencesAreNeverCached()throws Exception {
    mvc.perform(delete("/api/v1/notifications/push-installations/"+UUID.randomUUID()).with(jwt().jwt(t->t.subject(owner)))).andExpect(status().isNoContent());
    mvc.perform(get("/api/v1/tenants/"+tenant+"/notification-preferences").with(jwt().jwt(t->t.subject(owner)))).andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store"));
    mvc.perform(get("/api/v1/tenants/"+tenant+"/push-readiness").with(jwt().jwt(t->t.subject(owner)))).andExpect(status().isOk()).andExpect(header().string("Cache-Control","no-store")).andExpect(jsonPath("$.nativeIntegrationVerified").value(false)).andExpect(jsonPath("$.deliveryVerified").value(false));
  }
  String path(){return "/api/v1/notifications/push-installations/"+installation;}
}

package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.aimanager.identity.ActorKeys;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.ResultActions;

class AuditExportRecoveryTest extends AuditExportJourneyTest {
  ResultActions recover(String key, String who, Map<String, Object> selection) throws Exception {
    return mvc.perform(post(root + "/creation-results/" + key + "/query")
        .with(jwt().jwt(j -> j.subject(who))) // Read recovery does not fabricate MFA.
        .contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsBytes(selection)));
  }

  @Test void originalReferenceIsReadWithoutMfaOrNewWritesEvenAfterReplayExpiry() throws Exception {
    String key = UUID.randomUUID().toString();
    String id = body(create(key, input()).andExpect(status().isAccepted())).path("id").asText();
    var auditCount = db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=?", Integer.class, tenant);
    recover(key, owner, input()).andExpect(status().isOk()).andExpect(jsonPath("$.id").value(id));
    clock.value.addAndGet(86400001);
    recover(key, owner, input()).andExpect(status().isOk()).andExpect(jsonPath("$.state").value("EXPIRED"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_exports WHERE tenant_id=?", Integer.class, tenant)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_events WHERE tenant_id=?", Integer.class, tenant)).isEqualTo(auditCount);
  }

  @Test void recoveryBindsCreatorExactSelectionAndCurrentMemberAuthority() throws Exception {
    String key = UUID.randomUUID().toString();
    create(key, input()).andExpect(status().isAccepted());
    recover(key, owner, Map.of("from", NOW - 60001, "to", NOW, "resourceId", RESOURCE)).andExpect(status().isConflict());
    String other = "other-" + UUID.randomUUID();
    db.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,'AUDITOR')", tenant, other, ActorKeys.key(other));
    recover(key, other, input()).andExpect(status().isNotFound());
    db.update("UPDATE tenant_members SET version=version+1 WHERE tenant_id=? AND actor_key=?", tenant, ActorKeys.key(owner));
    recover(key, owner, input()).andExpect(status().isOk()).andExpect(jsonPath("$.state").value("REVOKED"));
    db.update("UPDATE tenant_members SET role='CHILD' WHERE tenant_id=? AND actor_key=?", tenant, ActorKeys.key(owner));
    recover(key, owner, input()).andExpect(status().isForbidden());
  }

  @Test void absentRequestDoesNotCreateAJobOrJournal() throws Exception {
    var count = db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=?", Integer.class, tenant);
    recover(UUID.randomUUID().toString(), owner, input()).andExpect(status().isNotFound())
        .andExpect(jsonPath("$.errorCode").value("EXPORT_CREATION_RESULT_UNAVAILABLE"));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM audit_exports WHERE tenant_id=?", Integer.class, tenant)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests WHERE scope_id=?", Integer.class, tenant)).isEqualTo(count);
  }
}

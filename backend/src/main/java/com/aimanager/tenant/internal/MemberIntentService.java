package com.aimanager.tenant.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.tenant.MembershipAccessChanged;
import com.aimanager.tenant.OwnershipTransferred;
import org.springframework.context.event.EventListener;
import org.springframework.core.annotation.Order;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
class MemberIntentService {
  private final JdbcTemplate jdbc;
  private final AuditService audit;

  MemberIntentService(JdbcTemplate jdbc, AuditService audit) {
    this.jdbc = jdbc;
    this.audit = audit;
  }

  @EventListener
  @Order(-300)
  @Transactional(propagation = Propagation.MANDATORY)
  public void ownership(OwnershipTransferred event) {
    cancel(
        event.tenantId(),
        event.formerOwnerActorId(),
        event.formerOwnerActorKey(),
        event.occurredAt());
  }

  @EventListener
  @Order(-300)
  @Transactional(propagation = Propagation.MANDATORY)
  public void membership(MembershipAccessChanged event) {
    cancel(event.tenantId(), event.actorId(), event.actorKey(), event.occurredAt());
  }

  private void cancel(String tenant, String actor, String actorKey, long now) {
    var candidates =
        jdbc.queryForList(
            "SELECT id,inviter_actor_id FROM member_invitations WHERE tenant_id=? AND"
                + " inviter_actor_id=? AND consumed_at IS NULL AND revoked_at IS NULL ORDER BY id"
                + " FOR UPDATE",
            tenant,
            actor);
    int changed = 0;
    for (var row : candidates) {
      // MySQL's default collation is not the exact OIDC subject namespace.
      if (!actor.equals(row.get("inviter_actor_id"))) continue;
      changed +=
          jdbc.update(
              "UPDATE member_invitations SET revoked_at=? WHERE tenant_id=? AND id=?",
              now,
              tenant,
              row.get("id"));
    }
    if (changed > 0)
      audit.record(tenant, "system:membership", "INVITATIONS_ACCESS_INVALIDATED", actorKey);
  }
}

package com.aimanager.tenant.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import com.aimanager.tenant.MembershipRevoked;
import java.time.Clock;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.tenant.TenantAccess.Role.*;

@Service
class MembershipService {
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final RecentAuthentication recent;
    private final AuditService audit;
    private final Clock clock;
    private final ApplicationEventPublisher events;
    MembershipService(JdbcTemplate jdbc, TenantAccess access, RecentAuthentication recent, AuditService audit, Clock clock, ApplicationEventPublisher events) {
        this.jdbc = jdbc; this.access = access; this.recent = recent; this.audit = audit; this.clock = clock;
        this.events = events;
    }

    @Transactional(timeout = 10)
    public Invitation invite(String tenantId, Jwt actor, String recipientEmail, Role role, String subjectId) {
        var grant = access.requireWriteRole(tenantId, actor.getSubject(), OWNER, ORG_ADMIN);
        recent.require(actor);
        validateGrant(tenantId, grant, role, subjectId);
        String id = UUID.randomUUID().toString();
        String token = InvitationSecrets.issue();
        long expires = clock.instant().plusSeconds(86400).toEpochMilli();
        jdbc.update("INSERT INTO member_invitations(id,tenant_id,inviter_actor_id,recipient_email_hash,role,subject_id,token_hash,expires_at) VALUES(?,?,?,?,?,?,?,?)",
            id, tenantId, actor.getSubject(), InvitationSecrets.emailHash(recipientEmail), role.name(), subjectId,
            InvitationSecrets.tokenHash(token), expires);
        audit.record(tenantId, actor.getSubject(), "MEMBER_INVITED", id);
        return new Invitation(id, token, role, expires);
    }

    private void validateGrant(String tenantId, TenantAccess.Grant grant, Role requested, String subjectId) {
        String kind = jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?", String.class, tenantId);
        if (requested == OWNER || ("FAMILY".equals(kind) && (requested == ORG_ADMIN || requested == TEACHER))
                || ("ORGANIZATION".equals(kind) && requested == GUARDIAN)) {
            throw DomainException.invalid("ROLE_NOT_APPLICABLE");
        }
        if (requested == ORG_ADMIN && grant.role() != OWNER) throw DomainException.denied();
        if (requested == CHILD || requested == TEACHER) {
            if (subjectId == null || jdbc.queryForObject("SELECT COUNT(*) FROM subjects WHERE tenant_id=? AND id=? AND archived_at IS NULL",
                    Integer.class, tenantId, subjectId) != 1) throw DomainException.invalid("SUBJECT_SCOPE_REQUIRED");
        } else if (subjectId != null) {
            throw DomainException.invalid("ROLE_SCOPE_NOT_APPLICABLE");
        }
    }

    @Transactional(timeout = 10)
    public Accepted accept(Jwt actor, boolean adult, String token) {
        var invitations = jdbc.query("SELECT * FROM member_invitations WHERE token_hash=? FOR UPDATE",
            (row, index) -> new Pending(row.getString("id"), row.getString("tenant_id"), row.getString("inviter_actor_id"),
                row.getString("recipient_email_hash"), Role.valueOf(row.getString("role")), row.getString("subject_id"),
                row.getLong("expires_at"), row.getObject("consumed_at") != null, row.getObject("revoked_at") != null),
            InvitationSecrets.tokenHash(token));
        if (invitations.isEmpty()) throw DomainException.denied();
        var invite = invitations.get(0);
        if (invite.consumed() || invite.revoked() || invite.expiresAt() <= clock.millis()) {
            throw new DomainException(HttpStatus.CONFLICT, "INVITATION_UNAVAILABLE");
        }
        String email = actor.getClaimAsString("email");
        if (!Boolean.TRUE.equals(actor.getClaimAsBoolean("email_verified")) || email == null
                || !invite.recipientHash().equals(InvitationSecrets.emailHash(email))) throw DomainException.denied();
        if (invite.role() != CHILD) {
            if (!adult) throw DomainException.denied();
            recent.require(actor);
        }
        // Permission must still exist at acceptance; a stale invite cannot resurrect a removed administrator.
        var inviter = access.requireWriteRole(invite.tenantId(), invite.inviter(), OWNER, ORG_ADMIN);
        validateGrant(invite.tenantId(), inviter, invite.role(), invite.subjectId());
        var existing = jdbc.queryForList("SELECT role,revoked_at FROM tenant_members WHERE tenant_id=? AND actor_key=? FOR UPDATE",
            invite.tenantId(), ActorKeys.key(actor.getSubject()));
        if (!existing.isEmpty() && existing.get(0).get("revoked_at") == null) {
            throw new DomainException(HttpStatus.CONFLICT, "MEMBER_ALREADY_EXISTS");
        }
        if (existing.isEmpty()) {
            jdbc.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role,subject_id) VALUES(?,?,?,?,?)",
                invite.tenantId(), actor.getSubject(), ActorKeys.key(actor.getSubject()), invite.role().name(), invite.subjectId());
        } else {
            jdbc.update("UPDATE tenant_members SET role=?,subject_id=?,revoked_at=NULL WHERE tenant_id=? AND actor_key=?",
                invite.role().name(), invite.subjectId(), invite.tenantId(), ActorKeys.key(actor.getSubject()));
        }
        jdbc.update("UPDATE member_invitations SET consumed_at=? WHERE id=?", clock.millis(), invite.id());
        audit.record(invite.tenantId(), actor.getSubject(), "MEMBER_JOINED", invite.id());
        return new Accepted(invite.tenantId(), invite.role());
    }

    @Transactional(timeout = 10)
    public void revoke(String tenantId, Jwt actor, String memberActor) {
        var grant = access.requireWriteRole(tenantId, actor.getSubject(), OWNER, ORG_ADMIN);
        recent.require(actor);
        var members = jdbc.query("SELECT role FROM tenant_members WHERE tenant_id=? AND actor_key=? AND revoked_at IS NULL FOR UPDATE",
            (row, index) -> Role.valueOf(row.getString("role")), tenantId, ActorKeys.key(memberActor));
        if (members.isEmpty()) throw DomainException.denied();
        if (members.get(0) == OWNER) throw new DomainException(HttpStatus.CONFLICT, "OWNER_TRANSFER_REQUIRED");
        if (members.get(0) == ORG_ADMIN && grant.role() != OWNER) throw DomainException.denied();
        jdbc.update("UPDATE tenant_members SET revoked_at=CURRENT_TIMESTAMP WHERE tenant_id=? AND actor_key=?", tenantId, ActorKeys.key(memberActor));
        audit.record(tenantId, actor.getSubject(), "MEMBERSHIP_REVOKED", memberActor);
        events.publishEvent(new MembershipRevoked(tenantId, ActorKeys.key(memberActor)));
    }

    /** Cancellation is tenant-scoped and idempotent, without returning the invitation token. */
    @Transactional(timeout = 10)
    public void cancelInvitation(String tenantId, Jwt actor, String invitationId) {
        var grant = access.requireWriteRole(tenantId, actor.getSubject(), OWNER, ORG_ADMIN);
        recent.require(actor);
        var roles = jdbc.query("SELECT role FROM member_invitations WHERE tenant_id=? AND id=? FOR UPDATE",
            (row, index) -> Role.valueOf(row.getString("role")), tenantId, invitationId);
        if (roles.isEmpty()) throw DomainException.denied();
        if (roles.get(0) == ORG_ADMIN && grant.role() != OWNER) throw DomainException.denied();
        int changed = jdbc.update("UPDATE member_invitations SET revoked_at=? WHERE tenant_id=? AND id=? AND revoked_at IS NULL",
            clock.millis(), tenantId, invitationId);
        if (changed > 0) audit.record(tenantId, actor.getSubject(), "INVITATION_REVOKED", invitationId);
    }

    record Invitation(String id, String token, Role role, long expiresAt) {}
    record Accepted(String tenantId, Role role) {}
    private record Pending(String id, String tenantId, String inviter, String recipientHash, Role role, String subjectId,
                           long expiresAt, boolean consumed, boolean revoked) {}
}

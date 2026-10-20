package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.idempotency.IdempotencyLookupOutcome;
import com.aimanager.idempotency.ResponseOwnership;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Journal only an immutable invitation reference. Never persist a raw token or recipient email. */
@Service
class InvitationWorkflowService {
  private static final String OPERATION = "invitation.issue";
  private final MembershipService members;
  private final MembershipMutex mutex;
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final IdempotencyService idempotency;
  private final MemberClassScopes classes;
  private final JdbcTemplate db;
  private final Clock clock;
  InvitationWorkflowService(MembershipService members, MembershipMutex mutex, TenantAccess access,
      RecentAuthentication recent, IdempotencyService idempotency, MemberClassScopes classes,
      JdbcTemplate db, Clock clock) {
    this.members=members; this.mutex=mutex; this.access=access; this.recent=recent;
    this.idempotency=idempotency; this.classes=classes; this.db=db; this.clock=clock;
  }

  @Transactional(timeout=10)
  public Issuance issue(String tenant, Jwt actor, String key, InvitationWorkflowController.Issue input) {
    authorize(tenant, actor.getSubject());
    recent.require(actor);
    requireUuid(key);
    var normalized = classes.normalize(input.classIds());
    // A cache hit leaves this empty; only the transaction that creates an invitation sees the token.
    String[] token = new String[1];
    var reference = idempotency.execute(tenant, actor.getSubject(), OPERATION, key,
        fingerprint(input, normalized), Reference.class, () -> {
          var issued = members.invite(tenant, actor, input.recipientEmail(), input.role(), input.subjectId(), normalized);
          token[0] = issued.token();
          return new Reference(issued.id());
        }, ignored -> input.subjectId() == null ? ResponseOwnership.nonSubject()
            : ResponseOwnership.subjects(tenant, List.of(input.subjectId())));
    return new Issuance(key, read(tenant, reference.id()), token[0]);
  }

  @Transactional(timeout=10)
  public IdempotencyLookupOutcome<Issuance> result(String tenant, String actor, String key, InvitationWorkflowController.Issue input) {
    authorize(tenant, actor);
    requireUuid(key);
    return idempotency.findCommitted(tenant, actor, OPERATION, key,
        fingerprint(input, classes.normalize(input.classIds())), Reference.class)
        .requirePresent(() -> new DomainException(HttpStatus.NOT_FOUND, "INVITATION_RESULT_UNAVAILABLE"))
      .map(reference -> {
      return new Issuance(key, read(tenant, reference.id()), null);
      });
  }

  @Transactional(timeout=10)
  public Summary detail(String tenant, String actor, String id) {
    authorize(tenant, actor);
    return read(tenant, id);
  }

  private void authorize(String tenant, String actor) {
    mutex.lock(tenant);
    access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
  }

  private Map<String,Object> fingerprint(InvitationWorkflowController.Issue input, List<String> normalized) {
    var result = new TreeMap<String,Object>();
    result.put("recipientHash", InvitationSecrets.emailHash(input.recipientEmail()));
    result.put("role", input.role());
    result.put("subjectId", input.subjectId() == null ? "" : input.subjectId());
    result.put("classIds", normalized);
    return result;
  }

  private Summary read(String tenant, String id) {
    requireUuid(id);
    var rows = db.query("SELECT id,role,subject_id,expires_at,consumed_at,revoked_at FROM member_invitations WHERE tenant_id=? AND id=? FOR UPDATE",
        (r,n) -> new Summary(r.getString("id"), r.getString("role"), r.getString("subject_id"),
            r.getLong("expires_at"), r.getObject("consumed_at") != null ? "ACCEPTED"
                : r.getObject("revoked_at") != null ? "CANCELLED"
                : r.getLong("expires_at") <= clock.millis() ? "EXPIRED" : "PENDING",
            classes.invitation(tenant, id)), tenant, id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private void requireUuid(String value) {
    if (value == null || !value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
      throw DomainException.invalid("INVALID_INVITATION_REFERENCE");
  }

  record Reference(String id) {}
  record Summary(String id, String role, String subjectId, long expiresAt, String state, List<String> classIds) {}
  record Issuance(String requestId, Summary invitation, String token) {}
}

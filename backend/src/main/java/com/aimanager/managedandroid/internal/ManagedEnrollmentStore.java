package com.aimanager.managedandroid.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.managedandroid.ManagedAndroidGateway.ManagedEnrollmentIdentity;
import com.aimanager.managedandroid.ManagedEnterpriseAuthority;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.regex.Pattern;
import org.slf4j.MDC;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Transactional enrollment ledger. Provider calls are made by the orchestrator outside locks. */
@Service
class ManagedEnrollmentStore {
  private static final Pattern TOKEN_NAME = Pattern.compile(
      "enterprises/[A-Za-z0-9_-]{1,128}/enrollmentTokens/[A-Za-z0-9_-]{1,128}");
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final ManagedEnterpriseAuthority enterprises;
  private final AuditService audit;
  private final Clock clock;

  ManagedEnrollmentStore(
      JdbcTemplate jdbc, TenantAccess access, ManagedEnterpriseAuthority enterprises,
      AuditService audit, Clock clock) {
    this.jdbc = jdbc;
    this.access = access;
    this.enterprises = enterprises;
    this.audit = audit;
    this.clock = clock;
  }

  @Transactional(timeout = 10)
  Intent prepare(String tenant, String actor, String subject, String policy, String nonceHash) {
    access.requireWriteRole(tenant, actor, Role.OWNER, Role.ORG_ADMIN);
    var enterprise = enterprises.requireActive(tenant);
    long lockedBindingVersion = jdbc.queryForObject(
        "SELECT version FROM managed_enterprise_bindings WHERE tenant_id=? FOR UPDATE",
        Long.class, tenant);
    if (lockedBindingVersion != enterprise.bindingVersion())
      throw conflict("MANAGED_ENTERPRISE_CHANGED");
    // Serializes capacity checks across replicas without locking the whole tenant's children.
    var subjectRows = jdbc.queryForList(
        "SELECT id FROM subjects WHERE tenant_id=? AND id=? AND archived_at IS NULL FOR UPDATE",
        tenant, subject);
    if (subjectRows.size() != 1) throw DomainException.denied();
    long now = clock.millis();
    int tenantOutstanding = jdbc.queryForObject(
        "SELECT COUNT(*) FROM managed_enrollment_intents WHERE tenant_id=?"
            + " AND state IN ('PREPARING','ISSUED','CANCEL_PENDING') AND expires_at>?",
        Integer.class, tenant, now);
    if (tenantOutstanding >= 100) throw conflict("MANAGED_ENROLLMENT_CAPACITY_REACHED");
    int outstanding = jdbc.queryForObject(
        "SELECT COUNT(*) FROM managed_enrollment_intents WHERE tenant_id=? AND subject_id=?"
            + " AND state IN ('PREPARING','ISSUED','CANCEL_PENDING') AND expires_at>?",
        Integer.class, tenant, subject, now);
    if (outstanding > 0) throw conflict("MANAGED_ENROLLMENT_ALREADY_PENDING");
    int recent = jdbc.queryForObject(
        "SELECT COUNT(*) FROM managed_enrollment_intents WHERE tenant_id=? AND subject_id=?"
            + " AND created_at>?",
        Integer.class, tenant, subject, now - 3_600_000);
    if (recent >= 10)
      throw new DomainException(HttpStatus.TOO_MANY_REQUESTS, "MANAGED_ENROLLMENT_RATE_LIMITED");
    String id = UUID.randomUUID().toString();
    jdbc.update(
        "INSERT INTO managed_enrollment_intents(tenant_id,id,subject_id,provider,enterprise_id,"
            + "binding_version,policy_id,nonce_hash,state,version,requested_by,created_at,"
            + "expires_at,updated_at) VALUES(?,?,?,?,?,?,?,?, 'PREPARING',1,?,?,?,?)",
        tenant, id, subject, enterprise.provider(), enterprise.enterpriseId(),
        enterprise.bindingVersion(), policy, nonceHash, actor, now, now + 300_000, now);
    Intent intent = required(tenant, id, true);
    event(intent, "PREPARED", actor);
    audit.record(tenant, actor, "MANAGED_ENROLLMENT_PREPARED", id);
    return intent;
  }

  @Transactional(timeout = 10)
  Intent issued(String tenant, String id, String actor, long policyVersion,
      String tokenName, long providerExpiry) {
    access.requireWriteRole(tenant, actor, Role.OWNER, Role.ORG_ADMIN);
    Intent intent = required(tenant, id, true);
    if (!"PREPARING".equals(intent.state()) || !actor.equals(intent.requestedBy()))
      throw conflict("MANAGED_ENROLLMENT_CHANGED");
    var enterprise = enterprises.requireActive(tenant);
    if (!enterprise.provider().equals(intent.provider())
        || !enterprise.enterpriseId().equals(intent.enterpriseId())
        || enterprise.bindingVersion() != intent.bindingVersion())
      throw conflict("MANAGED_ENTERPRISE_CHANGED");
    if (tokenName == null || !TOKEN_NAME.matcher(tokenName).matches()
        || !tokenName.startsWith("enterprises/" + intent.enterpriseId() + "/enrollmentTokens/")
        || policyVersion < 1
        || providerExpiry <= clock.millis()
        || providerExpiry > intent.expiresAt() + 30_000)
      throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_ENROLLMENT_RESPONSE_INVALID");
    jdbc.update(
        "UPDATE managed_enrollment_intents SET state='ISSUED',version=version+1,"
            + "policy_version=?,token_name=?,issued_at=?,expires_at=?,updated_at=?"
            + " WHERE tenant_id=? AND id=?",
        policyVersion, tokenName, clock.millis(), Math.min(providerExpiry, intent.expiresAt()),
        clock.millis(), tenant, id);
    Intent updated = required(tenant, id, true);
    event(updated, "ISSUED", actor);
    audit.record(tenant, actor, "MANAGED_ENROLLMENT_ISSUED", id);
    return updated;
  }

  @Transactional(timeout = 10)
  void failed(String tenant, String id, String actor) {
    Intent intent = required(tenant, id, true);
    if (!"PREPARING".equals(intent.state())) return;
    jdbc.update(
        "UPDATE managed_enrollment_intents SET state='FAILED',version=version+1,updated_at=?"
            + " WHERE tenant_id=? AND id=?", clock.millis(), tenant, id);
    Intent updated = required(tenant, id, true);
    event(updated, "FAILED", actor);
    audit.record(tenant, actor, "MANAGED_ENROLLMENT_FAILED", id);
  }

  @Transactional(readOnly = true, timeout = 10)
  Intent get(String tenant, String id, String actor) {
    access.requireRole(tenant, actor, Role.OWNER, Role.ORG_ADMIN, Role.AUDITOR);
    return required(tenant, id, false);
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<Intent> list(String tenant, String actor, int limit, String cursor) {
    access.requireRole(tenant, actor, Role.OWNER, Role.ORG_ADMIN, Role.AUDITOR);
    ItemPage.validate(limit, cursor);
    var rows = jdbc.query(
        "SELECT * FROM managed_enrollment_intents WHERE tenant_id=? AND id>?"
            + " ORDER BY id LIMIT ?",
        (r, n) -> row(r),
        tenant, cursor == null ? "" : cursor, limit + 1);
    return ItemPage.from(rows, limit, Intent::id);
  }

  @Transactional(readOnly = true, timeout = 10)
  Intent forVerification(String tenant, String id, String actor) {
    access.requireRole(tenant, actor, Role.OWNER, Role.ORG_ADMIN);
    Intent intent = required(tenant, id, false);
    if (!"ISSUED".equals(intent.state())) throw conflict("MANAGED_ENROLLMENT_NOT_ISSUED");
    var enterprise = enterprises.requireActive(tenant);
    if (!enterprise.provider().equals(intent.provider())
        || !enterprise.enterpriseId().equals(intent.enterpriseId())
        || enterprise.bindingVersion() != intent.bindingVersion())
      throw conflict("MANAGED_ENTERPRISE_CHANGED");
    return intent;
  }

  /** Read-only provider check still needs a currently approved enterprise and valid contract. */
  @Transactional(readOnly = true, timeout = 10)
  Intent forProviderStatus(String tenant, String id, String actor) {
    access.requireRole(tenant, actor, Role.OWNER, Role.ORG_ADMIN, Role.AUDITOR);
    Intent intent = required(tenant, id, false);
    if (!"VERIFIED".equals(intent.state()))
      throw conflict("MANAGED_ENROLLMENT_NOT_VERIFIED");
    var enterprise = enterprises.requireActive(tenant);
    if (!enterprise.provider().equals(intent.provider())
        || !enterprise.enterpriseId().equals(intent.enterpriseId())
        || enterprise.bindingVersion() != intent.bindingVersion())
      throw conflict("MANAGED_ENTERPRISE_CHANGED");
    return intent;
  }

  @Transactional(timeout = 10)
  Intent verify(String tenant, String id, String actor, String providerDeviceId,
      ManagedEnrollmentIdentity evidence, long expectedVersion) {
    access.requireWriteRole(tenant, actor, Role.OWNER, Role.ORG_ADMIN);
    Intent intent = required(tenant, id, true);
    ResourceVersions.check(expectedVersion, intent.version());
    if (!"ISSUED".equals(intent.state())) throw conflict("MANAGED_ENROLLMENT_NOT_ISSUED");
    var enterprise = enterprises.requireActive(tenant);
    if (!enterprise.provider().equals(intent.provider())
        || !enterprise.enterpriseId().equals(intent.enterpriseId())
        || enterprise.bindingVersion() != intent.bindingVersion())
      throw conflict("MANAGED_ENTERPRISE_CHANGED");
    requireProvenance(intent, providerDeviceId, evidence);
    jdbc.update(
        "UPDATE managed_enrollment_intents SET state='VERIFIED',version=version+1,"
            + "provider_device_id=?,provider_mode=?,verified_at=?,updated_at=?"
            + " WHERE tenant_id=? AND id=?",
        providerDeviceId, evidence.managementMode(), clock.millis(), clock.millis(), tenant, id);
    Intent updated = required(tenant, id, true);
    event(updated, "VERIFIED", actor);
    audit.record(tenant, actor, "MANAGED_PROVIDER_DEVICE_VERIFIED", id);
    return updated;
  }

  /** Reusable immutable enrollment provenance check; a device ID alone proves nothing. */
  static void requireProvenance(Intent intent, String providerDeviceId,
      ManagedEnrollmentIdentity evidence) {
    if (evidence == null)
      throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_DEVICE_IDENTITY_INVALID");
    long enrolledAt;
    try {
      enrolledAt = Instant.parse(evidence.enrollmentTime()).toEpochMilli();
    } catch (DateTimeParseException | NullPointerException malformed) {
      throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_DEVICE_IDENTITY_INVALID");
    }
    boolean nonceMatches = evidence.enrollmentTokenData() != null
        && MessageDigest.isEqual(
            intent.nonceHash().getBytes(StandardCharsets.US_ASCII),
            SecretMaterial.hash(evidence.enrollmentTokenData()).getBytes(StandardCharsets.US_ASCII));
    if (!nonceMatches
        || !"DEVICE_OWNER".equals(evidence.managementMode())
        || !("enterprises/" + intent.enterpriseId() + "/devices/" + providerDeviceId)
            .equals(evidence.deviceName())
        || !intent.tokenName().equals(evidence.enrollmentTokenName())
        || enrolledAt < intent.issuedAt() - 30_000
        || enrolledAt > intent.expiresAt() + 30_000) {
      throw new DomainException(HttpStatus.CONFLICT, "EMM_DEVICE_IDENTITY_MISMATCH");
    }
  }

  @Transactional(timeout = 10)
  Intent requestCancel(String tenant, String id, String actor, long expected) {
    access.requireWriteRole(tenant, actor, Role.OWNER, Role.ORG_ADMIN);
    Intent intent = required(tenant, id, true);
    ResourceVersions.check(expected, intent.version());
    if ("CANCELLED".equals(intent.state()) || "CANCEL_PENDING".equals(intent.state())) return intent;
    if (!"PREPARING".equals(intent.state()) && !"ISSUED".equals(intent.state()))
      throw conflict("MANAGED_ENROLLMENT_CANNOT_CANCEL");
    jdbc.update(
        "UPDATE managed_enrollment_intents SET state='CANCEL_PENDING',version=version+1,"
            + "updated_at=? WHERE tenant_id=? AND id=?", clock.millis(), tenant, id);
    Intent updated = required(tenant, id, true);
    event(updated, "CANCEL_REQUESTED", actor);
    audit.record(tenant, actor, "MANAGED_ENROLLMENT_CANCEL_REQUESTED", id);
    return updated;
  }

  @Transactional(timeout = 10)
  Intent cancelled(String tenant, String id, String actor) {
    Intent intent = required(tenant, id, true);
    if ("CANCELLED".equals(intent.state())) return intent;
    if (!"CANCEL_PENDING".equals(intent.state())) throw conflict("MANAGED_ENROLLMENT_CHANGED");
    jdbc.update(
        "UPDATE managed_enrollment_intents SET state='CANCELLED',version=version+1,updated_at=?"
            + " WHERE tenant_id=? AND id=?", clock.millis(), tenant, id);
    Intent updated = required(tenant, id, true);
    event(updated, "CANCELLED", actor);
    audit.record(tenant, actor, "MANAGED_ENROLLMENT_CANCELLED", id);
    return updated;
  }

  /** Compare-and-swap leases let several scheduler replicas clean up without double ownership. */
  @Transactional(timeout = 10)
  List<CleanupLease> claimCleanup(int limit, String provider) {
    if (limit < 1 || limit > 100) throw new IllegalArgumentException("Invalid cleanup batch");
    long now = clock.millis();
    var candidates = jdbc.query(
        "SELECT tenant_id,id,enterprise_id,token_name FROM managed_enrollment_intents"
            + " WHERE provider=? AND state='CANCEL_PENDING' AND next_cleanup_at<=?"
            + " AND (cleanup_lease_until IS NULL OR cleanup_lease_until<?)"
            + " ORDER BY next_cleanup_at,id LIMIT ?",
        (r, n) -> new CleanupLease(r.getString(1), r.getString(2), r.getString(3),
            r.getString(4), null), provider, now, now, limit);
    List<CleanupLease> claimed = new ArrayList<>();
    for (var candidate : candidates) {
      String claim = UUID.randomUUID().toString();
      int changed = jdbc.update(
          "UPDATE managed_enrollment_intents SET cleanup_claim_id=?,cleanup_lease_until=?,"
              + "cleanup_attempts=cleanup_attempts+1 WHERE tenant_id=? AND id=?"
              + " AND provider=? AND state='CANCEL_PENDING' AND next_cleanup_at<=?"
              + " AND (cleanup_lease_until IS NULL OR cleanup_lease_until<?)",
          claim, now + 60_000, candidate.tenantId(), candidate.id(), provider, now, now);
      if (changed == 1) claimed.add(new CleanupLease(candidate.tenantId(), candidate.id(),
          candidate.enterpriseId(), candidate.tokenName(), claim));
    }
    return List.copyOf(claimed);
  }

  @Transactional(timeout = 10)
  void completeCleanup(CleanupLease lease) {
    var claims = jdbc.queryForList(
        "SELECT cleanup_claim_id FROM managed_enrollment_intents WHERE tenant_id=? AND id=?"
            + " AND state='CANCEL_PENDING' FOR UPDATE", lease.tenantId(), lease.id());
    if (claims.size() != 1 || !lease.claimId().equals(claims.get(0).get("cleanup_claim_id")))
      return;
    jdbc.update(
        "UPDATE managed_enrollment_intents SET state='CANCELLED',version=version+1,"
            + "cleanup_claim_id=NULL,cleanup_lease_until=NULL,updated_at=?"
            + " WHERE tenant_id=? AND id=?", clock.millis(), lease.tenantId(), lease.id());
    Intent updated = required(lease.tenantId(), lease.id(), true);
    event(updated, "CANCELLED", "system:enrollment-cleanup");
    audit.record(lease.tenantId(), "system:enrollment-cleanup",
        "MANAGED_ENROLLMENT_CANCELLED", lease.id());
  }

  @Transactional(timeout = 10)
  void deferCleanup(CleanupLease lease) {
    var attempts = jdbc.query(
        "SELECT cleanup_attempts FROM managed_enrollment_intents WHERE tenant_id=? AND id=?"
            + " AND state='CANCEL_PENDING' AND cleanup_claim_id=? FOR UPDATE",
        (r, n) -> r.getInt(1), lease.tenantId(), lease.id(), lease.claimId());
    if (attempts.isEmpty()) return;
    long seconds = Math.min(3600L, 30L << Math.min(7, Math.max(0, attempts.get(0) - 1)));
    jdbc.update(
        "UPDATE managed_enrollment_intents SET cleanup_claim_id=NULL,cleanup_lease_until=NULL,"
            + "next_cleanup_at=? WHERE tenant_id=? AND id=?",
        clock.millis() + seconds * 1000, lease.tenantId(), lease.id());
  }

  private Intent required(String tenant, String id, boolean lock) {
    var rows = jdbc.query(
        "SELECT * FROM managed_enrollment_intents WHERE tenant_id=? AND id=?"
            + (lock ? " FOR UPDATE" : ""),
        (r, n) -> row(r),
        tenant, id);
    if (rows.isEmpty()) throw new DomainException(HttpStatus.NOT_FOUND, "MANAGED_ENROLLMENT_NOT_FOUND");
    return rows.get(0);
  }

  private static Intent row(ResultSet r) throws SQLException {
    return new Intent(
        r.getString("tenant_id"), r.getString("id"), r.getString("subject_id"),
        r.getString("provider"), r.getString("enterprise_id"), r.getLong("binding_version"),
        r.getString("policy_id"), r.getLong("policy_version"), r.getString("token_name"),
        r.getString("nonce_hash"), r.getString("provider_device_id"),
        r.getString("provider_mode"), r.getString("state"), r.getLong("version"),
        r.getString("requested_by"), r.getLong("created_at"), r.getLong("issued_at"),
        r.getLong("expires_at"), r.getLong("verified_at"), r.getLong("updated_at"));
  }

  private void event(Intent intent, String action, String actor) {
    String correlation = MDC.get("correlationId");
    jdbc.update(
        "INSERT INTO managed_enrollment_intent_events(tenant_id,intent_id,version,id,action,"
            + "actor_id,correlation_id,occurred_at) VALUES(?,?,?,?,?,?,?,?)",
        intent.tenantId(), intent.id(), intent.version(), UUID.randomUUID().toString(), action,
        actor, correlation == null ? UUID.randomUUID().toString() : correlation, clock.millis());
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  /** Internal only: never serialize nonce digest or provider token name to a browser. */
  record Intent(
      String tenantId, String id, String subjectId, String provider, String enterpriseId,
      long bindingVersion, String policyId, long policyVersion, String tokenName,
      String nonceHash, String providerDeviceId, String providerMode, String state, long version,
      String requestedBy, long createdAt, long issuedAt, long expiresAt, long verifiedAt,
      long updatedAt) {
    @Override public String toString() { return "ManagedEnrollmentIntent[REDACTED]"; }
  }

  record CleanupLease(String tenantId, String id, String enterpriseId,
      String tokenName, String claimId) {}
}

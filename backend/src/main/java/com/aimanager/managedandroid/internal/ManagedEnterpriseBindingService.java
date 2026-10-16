package com.aimanager.managedandroid.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedAndroidUnavailableException;
import com.aimanager.managedandroid.ManagedEnterpriseAuthority;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;
import java.util.regex.Pattern;
import org.slf4j.MDC;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Institution-to-enterprise binding review. A provider read proves reachability only; customer
 * ownership is represented by an independently reviewed external evidence reference.
 */
@Service
class ManagedEnterpriseBindingService implements ManagedEnterpriseAuthority {
  static final String REVIEW_SCOPE = "SCOPE_emm:approve";
  private static final Pattern PROVIDER_CODE = Pattern.compile("[A-Z][A-Z0-9_]{2,31}");
  private static final Pattern PROVIDER_ID = Pattern.compile("[A-Za-z0-9_-]{1,128}");
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final AuditService audit;
  private final ManagedAndroidGateway gateway;
  private final Clock clock;
  private final String targetCountryCode;
  private final String bootstrapPolicyId;

  ManagedEnterpriseBindingService(
      JdbcTemplate jdbc,
      TenantAccess access,
      AuditService audit,
      ManagedAndroidGateway gateway,
      Clock clock,
      @Value("${manager.emm.target-country-code:CN}") String targetCountryCode,
      @Value("${manager.emm.bootstrap-policy-id:${manager.emm.google.bootstrap-policy-id:}}")
          String bootstrapPolicyId) {
    this.jdbc = jdbc;
    this.access = access;
    this.audit = audit;
    this.gateway = gateway;
    this.clock = clock;
    this.targetCountryCode = targetCountryCode;
    this.bootstrapPolicyId = bootstrapPolicyId;
  }

  /** Local provisioning readiness only; no remote liveness or device enforcement claim. */
  @Transactional(readOnly = true, timeout = 10)
  Readiness readiness(String tenantId, String actor) {
    access.requireRole(tenantId, actor, Role.OWNER, Role.ORG_ADMIN, Role.AUDITOR);
    String kind = jdbc.queryForObject("SELECT kind FROM tenants WHERE id=?", String.class, tenantId);
    if (!"ORGANIZATION".equals(kind)) throw DomainException.denied();
    String provider = configuredProvider();
    String reason;
    if ("CN".equals(targetCountryCode) && "GOOGLE_AMAPI".equals(provider))
      reason = "REGION_PROVIDER_UNAVAILABLE";
    else if (!gateway.available()) reason = "PROVIDER_NOT_CONFIGURED";
    else {
      Binding binding = find(tenantId, false);
      if (binding == null) reason = "BINDING_REQUIRED";
      else if ("PENDING".equals(binding.state())) reason = "BINDING_REVIEW_PENDING";
      else if (!"ACTIVE".equals(binding.state())) reason = "BINDING_REVOKED";
      else if (!provider.equals(binding.provider())) reason = "PROVIDER_CHANGED";
      else if (!hasCurrentContract(binding)) reason = "CONTRACT_REQUIRED";
      else if (bootstrapPolicyId.isBlank()) reason = "BOOTSTRAP_POLICY_REQUIRED";
      else reason = "PROVISIONING_CONFIGURED";
    }
    return new Readiness(tenantId, provider, targetCountryCode,
        "PROVISIONING_CONFIGURED".equals(reason), reason);
  }

  /** A tenant administrator may propose; this does not call or authorize the provider. */
  @Transactional(timeout = 10)
  Binding propose(String tenantId, String actor, String enterpriseId, String contractReference) {
    access.requireWriteRole(tenantId, actor, Role.OWNER, Role.ORG_ADMIN);
    String provider = configuredProvider();
    if (!PROVIDER_ID.matcher(String.valueOf(enterpriseId)).matches())
      throw DomainException.invalid("INVALID_ENTERPRISE_ID");
    String contract = text(contractReference, 1, 200, "INVALID_CONTRACT_REFERENCE");
    String kind = jdbc.queryForObject("SELECT kind FROM tenants WHERE id=? FOR UPDATE", String.class, tenantId);
    if (!"ORGANIZATION".equals(kind)) throw DomainException.denied();
    Binding existing = find(tenantId, true);
    if (existing != null) {
      if (existing.state().equals("PENDING")
          && existing.provider().equals(provider)
          && existing.enterpriseId().equals(enterpriseId)
          && existing.contractReference().equals(contract)
          && existing.requestedBy().equals(actor)) return existing;
      throw conflict("ENTERPRISE_BINDING_EXISTS");
    }
    long now = clock.millis();
    // The provider resource has a global unique constraint: one enterprise cannot be claimed by
    // two tenants. The no-op duplicate clause avoids a failed transaction on MySQL/H2 races.
    jdbc.update(
        "INSERT INTO managed_enterprise_bindings(tenant_id,provider,enterprise_id,"
            + "contract_reference,state,version,requested_by,created_at,updated_at)"
            + " VALUES(?,?,?,?,'PENDING',1,?,?,?) ON DUPLICATE KEY UPDATE tenant_id=tenant_id",
        tenantId, provider, enterpriseId, contract, actor, now, now);
    Binding created = find(tenantId, true);
    if (created == null
        || !created.provider().equals(provider)
        || !created.enterpriseId().equals(enterpriseId)
        || !created.contractReference().equals(contract)
        || !created.requestedBy().equals(actor)) throw conflict("ENTERPRISE_BINDING_EXISTS");
    if (jdbc.queryForObject(
            "SELECT COUNT(*) FROM managed_enterprise_binding_events WHERE tenant_id=?",
            Integer.class, tenantId) == 0) {
      event(created, "PROPOSED", actor, null);
      audit.record(tenantId, actor, "MANAGED_ENTERPRISE_PROPOSED", tenantId);
    }
    return created;
  }

  @Transactional(readOnly = true, timeout = 10)
  Binding tenantGet(String tenantId, String actor) {
    access.requireRole(tenantId, actor, Role.OWNER, Role.ORG_ADMIN, Role.AUDITOR);
    return required(tenantId, false);
  }

  @Transactional(readOnly = true, timeout = 10)
  Binding platformGet(Authentication auth, String tenantId) {
    requireReviewer(auth);
    return required(tenantId, false);
  }

  /** Rechecks the current contract on every future managed write, not only at approval time. */
  @Override
  @Transactional(readOnly = true, timeout = 10, noRollbackFor = DomainException.class)
  public EnterpriseAccess requireActive(String tenantId) {
    Binding binding = required(tenantId, false);
    if (!"ACTIVE".equals(binding.state())) throw conflict("ENTERPRISE_BINDING_NOT_ACTIVE");
    requireProvider(binding);
    if (!gateway.available()) throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EMM_UNAVAILABLE");
    requireCurrentContract(binding);
    return new EnterpriseAccess(binding.provider(), binding.enterpriseId(), binding.version());
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<Binding> pending(Authentication auth, int limit, String cursor) {
    requireReviewer(auth);
    ItemPage.validate(limit, cursor);
    List<Binding> rows = jdbc.query(
        "SELECT * FROM managed_enterprise_bindings WHERE state='PENDING' AND tenant_id>?"
            + " ORDER BY tenant_id LIMIT ?",
        (r, n) -> row(r), cursor == null ? "" : cursor, limit + 1);
    return ItemPage.from(rows, limit, Binding::tenantId);
  }

  /** Provider I/O happens outside the approval transaction. The transaction checks version. */
  ManagedAndroidGateway.EnterpriseIdentity inspectProvider(
      Authentication auth, String tenantId, long expectedVersion) {
    requireReviewer(auth);
    Binding binding = required(tenantId, false);
    ResourceVersions.check(expectedVersion, binding.version());
    if (!"PENDING".equals(binding.state())) throw conflict("ENTERPRISE_BINDING_NOT_PENDING");
    requireProvider(binding);
    if (!gateway.available()) throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EMM_UNAVAILABLE");
    try {
      var identity = gateway.readEnterprise(binding.enterpriseId());
      if (identity == null
          || !("enterprises/" + binding.enterpriseId()).equals(identity.enterpriseName()))
        throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_ENTERPRISE_IDENTITY_MISMATCH");
      return identity;
    } catch (ManagedAndroidUnavailableException unavailable) {
      throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EMM_UNAVAILABLE");
    }
  }

  /** The evidence reference is an operator attestation, never inferred from API read access. */
  @Transactional(timeout = 10)
  Binding approve(
      Authentication auth,
      String tenantId,
      String actor,
      long expectedVersion,
      String evidenceReference,
      String reason,
      ManagedAndroidGateway.EnterpriseIdentity providerIdentity) {
    requireReviewer(auth);
    String evidence = text(evidenceReference, 8, 200, "INVALID_OWNERSHIP_EVIDENCE");
    String explanation = text(reason, 5, 500, "INVALID_BINDING_REASON");
    Binding binding = required(tenantId, true);
    ResourceVersions.check(expectedVersion, binding.version());
    if (!"PENDING".equals(binding.state())) throw conflict("ENTERPRISE_BINDING_NOT_PENDING");
    requireProvider(binding);
    if (actor.equals(binding.requestedBy())) throw DomainException.denied();
    if (providerIdentity == null
        || !("enterprises/" + binding.enterpriseId()).equals(providerIdentity.enterpriseName()))
      throw new DomainException(HttpStatus.BAD_GATEWAY, "EMM_ENTERPRISE_IDENTITY_MISMATCH");
    requireCurrentContract(binding);
    String display = providerIdentity.displayName();
    if (display != null && (display.length() > 255 || display.chars().anyMatch(Character::isISOControl)))
      display = null;
    jdbc.update(
        "UPDATE managed_enterprise_bindings SET state='ACTIVE',version=version+1,"
            + "approved_by=?,provider_display_name=?,ownership_evidence_ref=?,updated_at=?"
            + " WHERE tenant_id=?",
        actor, display, evidence, clock.millis(), tenantId);
    Binding approved = required(tenantId, true);
    event(approved, "APPROVED", actor, explanation);
    audit.record(tenantId, actor, "MANAGED_ENTERPRISE_APPROVED", tenantId);
    return approved;
  }

  /** Stops new local managed operations. It does not unenroll an already managed device. */
  @Transactional(timeout = 10)
  Binding revoke(Authentication auth, String tenantId, String actor, long expected, String reason) {
    requireReviewer(auth);
    String explanation = text(reason, 5, 500, "INVALID_BINDING_REASON");
    Binding binding = required(tenantId, true);
    ResourceVersions.check(expected, binding.version());
    if (!"ACTIVE".equals(binding.state())) throw conflict("ENTERPRISE_BINDING_NOT_ACTIVE");
    jdbc.update(
        "UPDATE managed_enterprise_bindings SET state='REVOKED',version=version+1,updated_at=?"
            + " WHERE tenant_id=?", clock.millis(), tenantId);
    Binding revoked = required(tenantId, true);
    event(revoked, "REVOKED", actor, explanation);
    audit.record(tenantId, actor, "MANAGED_ENTERPRISE_REVOKED", tenantId);
    return revoked;
  }

  private void requireCurrentContract(Binding binding) {
    if (!hasCurrentContract(binding)) throw conflict("MANAGED_ANDROID_CONTRACT_REQUIRED");
  }

  private boolean hasCurrentContract(Binding binding) {
    String key = sha256("CONTRACT\u0000" + binding.contractReference());
    int eligible = jdbc.queryForObject(
        "SELECT COUNT(*) FROM commercial_contract_reviews r JOIN commercial_sources s"
            + " ON s.tenant_id=r.tenant_id WHERE r.tenant_id=? AND r.contract_reference=?"
            + " AND r.state='APPLIED' AND s.source_system='CONTRACT' AND s.source_key=?"
            + " AND s.state='ACTIVE' AND s.active_from<=? AND s.expires_at>?"
            + " AND s.features_json LIKE '%\"MANAGED_ANDROID\"%'",
        Integer.class,
        binding.tenantId(), binding.contractReference(), key, clock.millis(), clock.millis());
    return eligible > 0;
  }

  private String configuredProvider() {
    String provider = gateway.providerCode();
    if (provider == null || !PROVIDER_CODE.matcher(provider).matches())
      throw new IllegalStateException("Invalid managed Android provider code");
    return provider;
  }

  private void requireProvider(Binding binding) {
    if (!binding.provider().equals(configuredProvider()))
      throw new DomainException(HttpStatus.SERVICE_UNAVAILABLE, "EMM_PROVIDER_MISMATCH");
  }

  private Binding required(String tenantId, boolean lock) {
    Binding binding = find(tenantId, lock);
    if (binding == null) throw new DomainException(HttpStatus.NOT_FOUND, "ENTERPRISE_BINDING_NOT_FOUND");
    return binding;
  }

  private Binding find(String tenantId, boolean lock) {
    var rows = jdbc.query(
        "SELECT * FROM managed_enterprise_bindings WHERE tenant_id=?" + (lock ? " FOR UPDATE" : ""),
        (r, n) -> row(r), tenantId);
    return rows.isEmpty() ? null : rows.get(0);
  }

  private static Binding row(java.sql.ResultSet r) throws java.sql.SQLException {
    return new Binding(
        r.getString("tenant_id"), r.getString("provider"), r.getString("enterprise_id"),
        r.getString("contract_reference"), r.getString("state"), r.getLong("version"),
        r.getString("requested_by"), r.getString("approved_by"),
        r.getString("provider_display_name"), r.getString("ownership_evidence_ref"),
        r.getLong("created_at"), r.getLong("updated_at"));
  }

  private void event(Binding binding, String action, String actor, String reason) {
    String correlation = MDC.get("correlationId");
    jdbc.update(
        "INSERT INTO managed_enterprise_binding_events(tenant_id,version,id,action,actor_id,"
            + "reason,correlation_id,occurred_at) VALUES(?,?,?,?,?,?,?,?)",
        binding.tenantId(), binding.version(), UUID.randomUUID().toString(), action, actor,
        reason, correlation == null ? UUID.randomUUID().toString() : correlation, clock.millis());
  }

  private static void requireReviewer(Authentication auth) {
    if (auth == null || auth.getAuthorities().stream()
        .noneMatch(a -> REVIEW_SCOPE.equals(a.getAuthority()))) throw DomainException.denied();
  }

  private static String text(String value, int minimum, int maximum, String code) {
    if (value == null || value.strip().length() < minimum || value.strip().length() > maximum
        || value.chars().anyMatch(Character::isISOControl)) throw DomainException.invalid(code);
    return value.strip();
  }

  private static String sha256(String value) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
          .digest(value.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException missing) {
      throw new IllegalStateException("SHA-256 unavailable", missing);
    }
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  record Binding(
      String tenantId, String provider, String enterpriseId, String contractReference,
      String state, long version, String requestedBy, String approvedBy,
      String providerDisplayName, String ownershipEvidenceReference,
      long createdAt, long updatedAt) {}

  record Readiness(
      String tenantId, String provider, String targetCountryCode,
      boolean canIssueEnrollment, String reasonCode) {}
}

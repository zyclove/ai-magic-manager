package com.aimanager.managedandroid.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedExecutionAdmission;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.managedandroid.ManagedPreparationRequested;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.Timestamp;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Objects;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * Records the complete published selection in the caller's transaction. Only local connector
 * capabilities are consulted here; profile reads, compilation and provider writes belong to
 * workers. A returned call means durably queued after commit, never applied on a device.
 */
@Service
class ManagedPreparationAdmission implements ManagedExecutionAdmission {
  private final JdbcTemplate db;
  private final ManagedAgentBindingStore bindings;
  private final ManagedExecutionPublicationAccess publications;
  private final TenantAccess access;
  private final AuditService audit;
  private final ApplicationEventPublisher events;
  private final ManagedAndroidGateway gateway;
  private final ManagedPolicyDocumentCompilers compilers;
  private final ObjectMapper json;
  private final boolean enabled;
  private final long ttlMillis;

  ManagedPreparationAdmission(
      JdbcTemplate db,
      ManagedAgentBindingStore bindings,
      ManagedExecutionPublicationAccess publications,
      TenantAccess access,
      AuditService audit,
      ApplicationEventPublisher events,
      ManagedAndroidGateway gateway,
      ManagedPolicyDocumentCompilers compilers,
      ObjectMapper json,
      @Value("${manager.emm.execution.admission.enabled:false}") boolean enabled,
      @Value("${manager.emm.execution.admission.ttl-seconds:900}") int ttlSeconds) {
    if (ttlSeconds < 60 || ttlSeconds > 3600)
      throw new IllegalArgumentException("Invalid preparation admission TTL");
    this.db = db;
    this.bindings = bindings;
    this.publications = publications;
    this.access = access;
    this.audit = audit;
    this.events = events;
    this.gateway = gateway;
    this.compilers = compilers;
    this.json = json;
    this.enabled = enabled;
    this.ttlMillis = ttlSeconds * 1000L;
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public void accept(String tenant, String actor, String publication) {
    // Direct internal callers must obey the same contract as calls through Spring's proxy.
    if (!TransactionSynchronizationManager.isActualTransactionActive()
        || !Objects.equals(
            TransactionSynchronizationManager.getCurrentTransactionIsolationLevel(),
            TransactionDefinition.ISOLATION_READ_COMMITTED))
      throw new IllegalStateException("Preparation admission requires READ_COMMITTED");
    long authority = access.requireWriteVersion(tenant, actor, Role.OWNER, Role.ORG_ADMIN);
    requireAvailable();
    var snapshot = publications.requireTargets(tenant, actor, publication);
    var selection =
        snapshot.targets().stream()
            .sorted(Comparator.comparing(ManagedExecutionPublicationAccess.Target::deviceId))
            .toList();
    if (selection.isEmpty()
        || selection.size() > 50
        || selection.stream()
                .map(ManagedExecutionPublicationAccess.Target::deviceId)
                .distinct()
                .count()
            != selection.size())
      throw new IllegalStateException("Invalid stored execution publication");

    // Discover candidates without locking binding rows ahead of the established domain lock order.
    // The binding service locks authority, enterprise, subject, device, registration and binding,
    // then verifies every current fact. Stable device order also bounds concurrent batch
    // contention.
    var prepared = new ArrayList<Prepared>();
    for (var target : selection) {
      var candidates =
          db.query(
              "SELECT id,version FROM managed_agent_bindings WHERE tenant_id=? AND device_id=?"
                  + " AND registration_id=? AND active_device_id=? AND state='VERIFIED'",
              (r, n) -> new Binding(r.getString("id"), r.getLong("version")),
              tenant,
              target.deviceId(),
              target.registrationId(),
              target.deviceId());
      if (candidates.size() != 1) throw conflict("MANAGED_BINDING_NOT_VERIFIED");
      var binding = candidates.get(0);
      var context = bindings.requireVerifiedContext(tenant, actor, binding.id(), binding.version());
      if (!tenant.equals(context.tenantId())
          || !actor.equals(context.actorId())
          || authority != context.authorityVersion()
          || !target.deviceId().equals(context.deviceId())
          || !target.registrationId().equals(context.registrationId())
          || !binding.id().equals(context.bindingId())
          || binding.version() != context.bindingVersion()
          || !gateway.providerCode().equals(context.provider()))
        throw conflict("MANAGED_BINDING_CONTEXT_CHANGED");
      prepared.add(new Prepared(context, hash(context)));
    }

    var previous =
        db.query(
            "SELECT"
                + " policy_version_id,device_id,registration_id,binding_id,binding_version,actor_id,authority_version,context_sha256"
                + " FROM managed_policy_preparation_requests WHERE tenant_id=? AND publication_id=?"
                + " ORDER BY device_id LIMIT 51 FOR UPDATE",
            (r, n) ->
                new Existing(
                    r.getString("policy_version_id"),
                    r.getString("device_id"),
                    r.getString("registration_id"),
                    r.getString("binding_id"),
                    r.getLong("binding_version"),
                    r.getString("actor_id"),
                    r.getLong("authority_version"),
                    r.getString("context_sha256")),
            tenant,
            publication);
    if (!previous.isEmpty()) {
      if (previous.size() != prepared.size()) throw conflict("PREPARATION_REQUEST_REUSED");
      for (int i = 0; i < prepared.size(); i++) {
        var current = prepared.get(i);
        var context = current.context();
        var old = previous.get(i);
        if (!Objects.equals(old.version(), snapshot.publication().versionId())
            || !Objects.equals(old.device(), context.deviceId())
            || !Objects.equals(old.registration(), context.registrationId())
            || !Objects.equals(old.binding(), context.bindingId())
            || old.bindingVersion() != context.bindingVersion()
            || !Objects.equals(old.actor(), actor)
            || old.authority() != authority
            || !Objects.equals(old.contextHash(), current.contextHash()))
          throw conflict("PREPARATION_REQUEST_REUSED");
      }
      // Replaying a terminal request cannot restart it, extend its deadline or emit another wakeup.
      return;
    }

    long now = db.queryForObject("SELECT CURRENT_TIMESTAMP(3)", Timestamp.class).getTime();
    for (var item : prepared) {
      var context = item.context();
      requireFreeDevice(tenant, context.deviceId());
      if (db.queryForObject(
              "SELECT COUNT(*) FROM managed_policy_preparation_requests WHERE tenant_id=? AND"
                  + " binding_id=?",
              Long.class,
              tenant,
              context.bindingId())
          >= 100) throw conflict("PREPARATION_BINDING_HISTORY_LIMIT");
      String id = UUID.randomUUID().toString();
      db.update(
          "INSERT INTO"
              + " managed_policy_preparation_requests(tenant_id,id,publication_id,policy_version_id,"
              + "subject_id,device_id,registration_id,binding_id,binding_version,actor_id,authority_version,"
              + "context_sha256,state,reason_code,active_device_id,next_attempt_at,expires_at,created_at,updated_at)"
              + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,'PENDING','QUEUED',?,?,?,?,?)",
          tenant,
          id,
          publication,
          snapshot.publication().versionId(),
          context.subjectId(),
          context.deviceId(),
          context.registrationId(),
          context.bindingId(),
          context.bindingVersion(),
          actor,
          authority,
          item.contextHash(),
          context.deviceId(),
          now,
          now + ttlMillis,
          now,
          now);
      audit.record(tenant, actor, "PREPARATION_ACCEPTED", id);
      events.publishEvent(new ManagedPreparationRequested(tenant, id));
    }
  }

  private void requireAvailable() {
    if (!enabled
        || !gateway.available()
        || !gateway.supportsExecutionProfiles()
        || !gateway.supportsCompletePolicyDocuments()
        || !gateway.supportsPolicyResourceAuthority()
        || gateway.policyResourceAuthorityRevision() == null
        || gateway.policyResourceAuthorityRevision().isBlank()
        || !compilers.supports(gateway.providerCode()))
      throw new DomainException(
          HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_PREPARATION_ADMISSION_UNAVAILABLE");
  }

  private void requireFreeDevice(String tenant, String device) {
    // Same domain locks as execution intake. Separate unique constraints alone cannot protect a
    // shared device slot across these two tables; both directions must check while locks are held.
    if (!db.queryForList(
                "SELECT id FROM managed_policy_preparation_requests WHERE tenant_id=? AND"
                    + " active_device_id=? FOR UPDATE",
                tenant,
                device)
            .isEmpty()
        || !db.queryForList(
                "SELECT id FROM managed_policy_execution_tasks WHERE tenant_id=? AND"
                    + " active_device_id=? FOR UPDATE",
                tenant,
                device)
            .isEmpty()) throw conflict("EXECUTION_DEVICE_BUSY");
  }

  private String hash(ManagedAgentBindingStore.VerifiedBindingContext context) {
    try {
      return SecretMaterial.hash(json.writeValueAsString(context));
    } catch (com.fasterxml.jackson.core.JsonProcessingException failure) {
      throw new IllegalStateException("Cannot serialize verified preparation context", failure);
    }
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private record Binding(String id, long version) {}

  private record Prepared(
      ManagedAgentBindingStore.VerifiedBindingContext context, String contextHash) {
    @Override
    public String toString() {
      return "ManagedPreparation[REDACTED]";
    }
  }

  private record Existing(
      String version,
      String device,
      String registration,
      String binding,
      long bindingVersion,
      String actor,
      long authority,
      String contextHash) {}
}

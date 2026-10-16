package com.aimanager.managedandroid.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.catalog.ApplicationIdentity;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.fleet.FleetPolicyAccess;
import com.aimanager.managedandroid.ManagedPolicyEvidenceAccess;
import com.aimanager.shared.DomainException;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import java.sql.Connection;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Batch lock order: member, enterprise, all subjects, all devices, capacity, binding, evidence. */
@Service
class ManagedPolicyEvidenceReader implements ManagedPolicyEvidenceAccess {
  private static final Set<String> CATALOG_UNAVAILABLE =
      Set.of("APPLICATION_SIGNING_IDENTITY_REQUIRED", "APPLICATION_IDENTITY_METADATA_UNAVAILABLE");
  private static final Set<String> BINDING_UNAVAILABLE =
      Set.of(
          "MANAGED_BINDING_NOT_VERIFIED",
          "MANAGED_BINDING_SUBJECT_INACTIVE",
          "MANAGED_BINDING_DEVICE_MISMATCH",
          "MANAGED_BINDING_REGISTRATION_CHANGED",
          "MANAGED_BINDING_CONTEXT_CHANGED",
          "MANAGED_BINDING_PROVIDER_CHANGED",
          "MANAGED_BINDING_MODE_UNSUPPORTED",
          "MANAGED_BINDING_VERIFICATION_INVALID",
          "MANAGED_BINDING_RELEASE_TRUST_CHANGED",
          "MANAGED_ENROLLMENT_NOT_VERIFIED",
          "MANAGED_ENTERPRISE_CHANGED",
          "MANAGED_ANDROID_CONTRACT_REQUIRED",
          "ENTERPRISE_BINDING_NOT_ACTIVE",
          "ENTERPRISE_BINDING_NOT_FOUND",
          "EMM_PROVIDER_MISMATCH",
          "EMM_UNAVAILABLE",
          "MANAGED_AGENT_BINDING_UNAVAILABLE",
          "MANAGED_BINDING_NOT_FOUND",
          "RESOURCE_VERSION_CONFLICT");
  private final TenantAccess access;
  private final DeviceAccess devices;
  private final FleetPolicyAccess fleet;
  private final SubjectAccess subjects;
  private final ApplicationCatalog catalog;
  private final ManagedAgentBindingStore bindings;
  private final ManagedApplicationEvidenceStore evidence;
  private final JdbcTemplate db;

  ManagedPolicyEvidenceReader(
      TenantAccess access,
      DeviceAccess devices,
      FleetPolicyAccess fleet,
      SubjectAccess subjects,
      ApplicationCatalog catalog,
      ManagedAgentBindingStore bindings,
      ManagedApplicationEvidenceStore evidence,
      JdbcTemplate db) {
    this.access = access;
    this.devices = devices;
    this.fleet = fleet;
    this.subjects = subjects;
    this.catalog = catalog;
    this.bindings = bindings;
    this.evidence = evidence;
    this.db = db;
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public List<Target> snapshot(
      String tenant, String actor, List<String> deviceIds, Set<String> applicationIds) {
    var grant = access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    if (!Objects.equals(
        TransactionSynchronizationManager.getCurrentTransactionIsolationLevel(),
        Connection.TRANSACTION_READ_COMMITTED))
      throw new IllegalStateException("Policy evidence requires an explicit READ_COMMITTED caller");
    if (deviceIds.isEmpty()
        || deviceIds.size() > 50
        || applicationIds.size() > 100
        || deviceIds.stream().distinct().count() != deviceIds.size())
      throw DomainException.invalid("INVALID_POLICY_EVIDENCE_SCOPE");
    boolean managedReader = grant.role() != GUARDIAN && !applicationIds.isEmpty();
    // Take this before any subject/device lock, even if no binding currently exists.
    if (managedReader)
      db.queryForList(
          "SELECT version FROM managed_enterprise_bindings WHERE tenant_id=? FOR UPDATE", tenant);
    var before = new TreeMap<String, Device>();
    for (String id : deviceIds) before.put(id, devices.requireVisible(tenant, actor, id));
    for (String subject :
        before.values().stream().map(Device::subjectId).distinct().sorted().toList())
      subjects.lockForDevice(tenant, subject);
    var targets = new ArrayList<FleetPolicyAccess.Target>();
    for (var prior : before.values()) {
      var target = fleet.snapshot(tenant, actor, prior.id(), true);
      if (!target.device().subjectId().equals(prior.subjectId())
          || !target.device().registrationId().equals(prior.registrationId()))
        throw new DomainException(HttpStatus.CONFLICT, "POLICY_DEVICE_CONTEXT_CHANGED");
      targets.add(target);
    }
    // Declarations are tenant-scoped immutable identities; resolve each at most once per batch.
    var identities = new TreeMap<String, ApplicationIdentity>();
    var invalid = new HashMap<String, String>();
    for (String app : applicationIds.stream().sorted().toList()) {
      try {
        identities.put(app, catalog.requireEvidenceIdentity(tenant, actor, app));
      } catch (DomainException failure) {
        if (!CATALOG_UNAVAILABLE.contains(failure.errorCode())) throw failure;
        invalid.put(app, failure.errorCode());
      }
    }
    var result = new ArrayList<Target>();
    for (var target : targets) {
      var device = target.device();
      var facts = new HashMap<String, ApplicationEvidence>();
      String reason =
          grant.role() == GUARDIAN
              ? "MANAGED_APPLICATION_ADMIN_REQUIRED"
              : "MANAGED_BINDING_REQUIRED";
      if (managedReader && device.state() == Device.State.ACTIVE) {
        var candidates =
            db.query(
                "SELECT id,version,registration_id,subject_id FROM managed_agent_bindings"
                    + " WHERE tenant_id=? AND active_device_id=?",
                (r, n) -> new Binding(r.getString(1), r.getLong(2), r.getString(3), r.getString(4)),
                tenant,
                device.id());
        if (candidates.size() > 1)
          throw new DomainException(HttpStatus.CONFLICT, "MANAGED_BINDING_AMBIGUOUS");
        if (!candidates.isEmpty()) {
          var candidate = candidates.get(0);
          if (!candidate.registration().equals(device.registrationId())
              || !candidate.subject().equals(device.subjectId())) {
            reason = "MANAGED_BINDING_CONTEXT_CHANGED";
          } else {
            ManagedAgentBindingStore.VerifiedBindingContext context = null;
            try {
              context =
                  bindings.requireVerifiedContext(
                      tenant, actor, candidate.id(), candidate.version());
            } catch (DomainException failure) {
              if (!BINDING_UNAVAILABLE.contains(failure.errorCode())) throw failure;
              reason = failure.errorCode();
            }
            if (context != null)
              for (var fact : evidence.forPolicy(context, identities))
                facts.put(fact.applicationId(), fact);
          }
        }
      }
      var ordered = new ArrayList<ApplicationEvidence>();
      for (String app : applicationIds.stream().sorted().toList()) {
        var fact = facts.get(app);
        if (fact == null)
          fact =
              new ApplicationEvidence(
                  device.id(),
                  device.registrationId(),
                  app,
                  null,
                  0,
                  identities.containsKey(app) ? identities.get(app).revision() : null,
                  0,
                  "UNAVAILABLE",
                  invalid.getOrDefault(app, reason),
                  "UNKNOWN",
                  false,
                  null,
                  null,
                  null);
        ordered.add(fact);
      }
      result.add(new Target(target, ordered));
    }
    return List.copyOf(result);
  }

  private record Binding(String id, long version, String registration, String subject) {}
}

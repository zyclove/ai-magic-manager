package com.aimanager.support.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.fleet.*;
import com.aimanager.shared.*;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import org.springframework.stereotype.Component;

/** Trusted transaction-bound scope checks. Never accepts a caller-selected authority principal. */
@Component
class DiagnosticPackageAccess {
  private final TenantAccess access;
  private final SubjectAccess subjects;
  private final DeviceAccess devices;
  private final FleetDiagnosticSource fleet;
  private final SupportGrantStore grants;
  private final DiagnosticPackageStore jobs;
  private final Clock clock;

  DiagnosticPackageAccess(
      TenantAccess access,
      SubjectAccess subjects,
      DeviceAccess devices,
      FleetDiagnosticSource fleet,
      SupportGrantStore grants,
      DiagnosticPackageStore jobs,
      Clock clock) {
    this.access = access;
    this.subjects = subjects;
    this.devices = devices;
    this.fleet = fleet;
    this.grants = grants;
    this.jobs = jobs;
    this.clock = clock;
  }

  DiagnosticPackageStore.Scope admin(
      String tenant, String actor, String device, String registration) {
    long version = access.requireWriteVersion(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    jobs.head(tenant);
    var observed = devices.requireVisible(tenant, actor, device);
    subjects.lockActiveForScope(tenant, actor, observed.subjectId());
    var current = fleet.lockDevice(tenant, actor, device);
    if (!current.subjectId().equals(observed.subjectId())
        || !current.registrationId().equals(registration)
        || current.state() != Device.State.ACTIVE) throw DomainException.denied();
    // Device version is checked inside the idempotent create operation, not when replaying a
    // result.
    return new DiagnosticPackageStore.Scope(
        tenant,
        actor,
        actor,
        version,
        "ADMIN",
        null,
        null,
        device,
        current.subjectId(),
        registration,
        7);
  }

  DiagnosticPackageStore.Scope recipient(String id, String actor) {
    var grant = grants.recipient(id, actor, false);
    active(grant);
    var scope =
        new DiagnosticPackageStore.Scope(
            grant.tenantId(),
            actor,
            grant.creatorActorId(),
            grant.creatorMemberVersion(),
            "SUPPORT_GRANT",
            grant.id(),
            grant.version(),
            grant.deviceId(),
            grant.subjectId(),
            grant.registrationId(),
            grant.typeMask());
    lock(scope);
    return scope;
  }

  SupportGrantStore.Row lock(DiagnosticPackageStore.Scope scope) {
    long version =
        access.requireWriteVersion(scope.tenant(), scope.authority(), OWNER, GUARDIAN, ORG_ADMIN);
    jobs.head(scope.tenant());
    if (version != scope.authorityVersion()) throw DomainException.denied();
    if (scope.mode().equals("ADMIN") && !scope.requester().equals(scope.authority()))
      throw DomainException.denied();
    subjects.lockActiveForScope(scope.tenant(), scope.authority(), scope.subject());
    var device = fleet.lockDevice(scope.tenant(), scope.authority(), scope.device());
    if (device.state() != Device.State.ACTIVE
        || !device.subjectId().equals(scope.subject())
        || !device.registrationId().equals(scope.registration())) throw DomainException.denied();
    if (scope.mode().equals("ADMIN")) return null;
    if (!scope.mode().equals("SUPPORT_GRANT")) throw DomainException.denied();
    var current = grants.recipient(scope.grantId(), scope.requester(), true);
    active(current);
    if (!current.tenantId().equals(scope.tenant())
        || !current.creatorActorId().equals(scope.authority())
        || current.creatorMemberVersion() != scope.authorityVersion()
        || current.version() != scope.grantVersion()
        || !current.deviceId().equals(scope.device())
        || !current.subjectId().equals(scope.subject())
        || !current.registrationId().equals(scope.registration())
        || current.typeMask() != scope.types()) throw DomainException.denied();
    return current;
  }

  void active(SupportGrantStore.Row row) {
    if (!row.state().equals("ACTIVE") || row.expiresAt() <= clock.millis())
      throw DomainException.denied();
  }

  void deviceVersion(DiagnosticPackageStore.Scope scope, long expected) {
    ResourceVersions.check(
        expected, fleet.lockDevice(scope.tenant(), scope.authority(), scope.device()).version());
  }
}

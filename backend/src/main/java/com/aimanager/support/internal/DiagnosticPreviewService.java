package com.aimanager.support.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.delivery.DeliveryDiagnosticSource;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.fleet.FleetDiagnosticSource;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.policy.PolicyDiagnosticHashes;
import com.aimanager.shared.DomainException;
import com.aimanager.subject.SubjectAccess;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.TreeMap;
import org.slf4j.MDC;
import org.springframework.http.HttpStatus;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

@Service
class DiagnosticPreviewService {
  private final TenantAccess access;
  private final RecentAuthentication recent;
  private final DeviceAccess devices;
  private final SubjectAccess subjects;
  private final FleetDiagnosticSource fleet;
  private final DeliveryDiagnosticSource deliveries;
  private final PolicyDiagnosticHashes policies;
  private final DiagnosticProjection projection;
  private final ObjectMapper json;
  private final AuditService audit;
  private final Clock clock;

  DiagnosticPreviewService(
      TenantAccess access,
      RecentAuthentication recent,
      DeviceAccess devices,
      SubjectAccess subjects,
      FleetDiagnosticSource fleet,
      DeliveryDiagnosticSource deliveries,
      PolicyDiagnosticHashes policies,
      DiagnosticProjection projection,
      ObjectMapper json,
      AuditService audit,
      Clock clock) {
    this.access = access;
    this.recent = recent;
    this.devices = devices;
    this.subjects = subjects;
    this.fleet = fleet;
    this.deliveries = deliveries;
    this.policies = policies;
    this.projection = projection;
    this.json = json;
    this.audit = audit;
    this.clock = clock;
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public byte[] preview(String tenant, String device, Jwt actor) {
    String principal = actor.getSubject();
    access.requireWriteRole(tenant, principal, OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    var observed = devices.requireVisible(tenant, principal, device);
    subjects.lockActiveForScope(tenant, principal, observed.subjectId());
    var source = fleet.snapshot(tenant, principal, device);
    if (!observed.subjectId().equals(source.device().subjectId())
        || !observed.registrationId().equals(source.device().registrationId()))
      throw new DomainException(HttpStatus.CONFLICT, "DIAGNOSTIC_SCOPE_CHANGED");
    var configurations = deliveries.forAuthorizedDevice(tenant, source.device());
    var references = new TreeMap<String, String>();
    for (var item : configurations) {
      String previous = references.putIfAbsent(item.versionId(), item.policyId());
      if (previous != null && !previous.equals(item.policyId()))
        throw new DomainException(HttpStatus.BAD_GATEWAY, "DIAGNOSTIC_SOURCE_INVALID");
    }
    var document =
        projection.project(
            tenant,
            source,
            configurations,
            policies.forAuthorizedDiagnostic(tenant, references),
            clock.millis(),
            MDC.get("correlationId"),
            DiagnosticPreviewService.class.getPackage().getImplementationVersion());
    final byte[] bytes;
    try {
      bytes = json.writeValueAsBytes(document);
    } catch (JsonProcessingException failure) {
      throw new DomainException(HttpStatus.BAD_GATEWAY, "DIAGNOSTIC_SERIALIZATION_FAILED");
    }
    if (bytes.length > 512 * 1024)
      throw new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "DIAGNOSTIC_TOO_LARGE");
    audit.record(tenant, principal, "DIAGNOSTIC_PREVIEWED", device);
    return bytes;
  }
}

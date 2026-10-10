package com.aimanager.support.internal;

import com.aimanager.delivery.DeliveryDiagnosticSource;
import com.aimanager.fleet.FleetDiagnosticSource;
import com.aimanager.policy.PolicyDiagnosticHashes;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.slf4j.MDC;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** Called only after the grant and its membership/device scope have been locked and authorized. */
@Component
class SupportDiagnosticReader {
  private final DeliveryDiagnosticSource deliveries;
  private final PolicyDiagnosticHashes hashes;
  private final DiagnosticProjection projection;
  private final ObjectMapper json;
  private final Clock clock;

  SupportDiagnosticReader(
      DeliveryDiagnosticSource deliveries,
      PolicyDiagnosticHashes hashes,
      DiagnosticProjection projection,
      ObjectMapper json,
      Clock clock) {
    this.deliveries = deliveries;
    this.hashes = hashes;
    this.projection = projection;
    this.json = json;
    this.clock = clock;
  }

  byte[] read(SupportGrantStore.Row grant, FleetDiagnosticSource.Snapshot source) {
    boolean status = SupportGrantTypes.has(grant.typeMask(), SupportGrantTypes.STATUS),
        caps = SupportGrantTypes.has(grant.typeMask(), SupportGrantTypes.CAPABILITIES),
        configs = SupportGrantTypes.has(grant.typeMask(), SupportGrantTypes.CONFIGURATIONS);
    var items =
        configs
            ? deliveries.forAuthorizedDevice(grant.tenantId(), source.device())
            : List.<DeliveryDiagnosticSource.Item>of();
    var versions = new TreeMap<String, String>();
    for (var item : items) {
      String previous = versions.putIfAbsent(item.versionId(), item.policyId());
      if (previous != null && !previous.equals(item.policyId()))
        throw new DomainException(HttpStatus.BAD_GATEWAY, "DIAGNOSTIC_SOURCE_INVALID");
    }
    var value =
        projection.project(
            grant.tenantId(),
            source,
            items,
            configs ? hashes.forAuthorizedDiagnostic(grant.tenantId(), versions) : Map.of(),
            clock.millis(),
            MDC.get("correlationId"),
            SupportDiagnosticReader.class.getPackage().getImplementationVersion());
    var result =
        new Preview(
            1,
            grant.id(),
            grant.expiresAt(),
            SupportGrantTypes.list(grant.typeMask()),
            value.generatedAt(),
            value.correlationId(),
            value.scope(),
            status ? value.versions() : null,
            status ? value.device() : null,
            caps ? value.capabilities() : null,
            caps ? value.omittedCapabilityCount() : null,
            configs ? value.configurations() : null,
            value.evidenceStatus());
    try {
      byte[] bytes = json.writeValueAsBytes(result);
      if (bytes.length > 512 * 1024)
        throw new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "DIAGNOSTIC_TOO_LARGE");
      return bytes;
    } catch (JsonProcessingException failure) {
      throw new DomainException(HttpStatus.BAD_GATEWAY, "DIAGNOSTIC_SERIALIZATION_FAILED");
    }
  }

  record Preview(
      int schemaVersion,
      String grantId,
      long grantExpiresAt,
      List<String> diagnosticTypes,
      long generatedAt,
      String correlationId,
      DiagnosticProjection.Scope scope,
      DiagnosticProjection.Versions versions,
      DiagnosticProjection.DeviceStatus device,
      List<DiagnosticProjection.Capability> capabilities,
      Integer omittedCapabilityCount,
      List<DiagnosticProjection.Configuration> configurations,
      String evidenceStatus) {}
}

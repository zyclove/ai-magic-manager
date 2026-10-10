package com.aimanager.support.internal;

import com.aimanager.delivery.DeliveryDiagnosticSource;
import com.aimanager.fleet.FleetDiagnosticSource;
import com.aimanager.shared.DomainException;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** An explicit outbound allowlist, not a general-purpose redactor for arbitrary records or logs. */
@Component
final class DiagnosticProjection {
  private static final long SAFE_INTEGER = 9007199254740991L;
  private static final Set<String> CAPABILITIES =
      Set.of(
          "managed.app_policy",
          "app.install_policy",
          "app.launch_block",
          "permission.runtime",
          "device.lock_task",
          "usage.shared_quota_enforced",
          "usage.report",
          "network.domain_filter");
  private static final Set<String> GRANTS =
      Set.of("GRANTED", "DENIED", "NOT_REQUESTED", "REVOKED", "NOT_APPLICABLE");
  private static final Set<String> CAPABILITY_STATES =
      Set.of("UNSUPPORTED", "UNVERIFIED", "STALE", "UNKNOWN");
  private static final Set<String> SOURCES = Set.of("AGENT_REPORT", "REGISTRATION_MODE");
  private static final Set<String> LIMITATIONS =
      Set.of("MANAGED_REGISTRATION_REQUIRED", "EVIDENCE_NOT_CERTIFIED");
  private static final Set<String> DELIVERY_STATES =
      Set.of(
          "PENDING_SIGNATURE",
          "READY",
          "SERVED",
          "DEVICE_REPORTED_RECEIVED",
          "DEVICE_REPORTED_STORED",
          "DEVICE_REPORTED_REJECTED",
          "EXPIRED_AWAITING_PULL");
  private static final Set<String> REJECTIONS =
      Set.of(
          "UNSUPPORTED_SCHEMA",
          "SIGNATURE_INVALID",
          "IDENTITY_MISMATCH",
          "UNSUPPORTED_RULES",
          "STORAGE_FAILURE",
          "EXPIRED",
          "OLDER_VERSION");

  record Scope(String tenantId, String deviceId, String registrationId) {}

  record Version(String value, String status) {}

  record Versions(Version os, Version agent, Version server) {}

  record DeviceStatus(
      String platform,
      String state,
      String managementMode,
      String controlLevel,
      String observationStatus,
      Long lastHeartbeatAt) {}

  record Capability(
      String key,
      boolean reportedSupported,
      String grantStatus,
      String evidenceSource,
      Long checkedAt,
      String status,
      String limitationCode) {}

  record Configuration(
      String id,
      String policyId,
      String versionId,
      long sourceSequence,
      String action,
      String deliveryState,
      String policyHash,
      String configurationHash,
      Long issuedAt,
      Long deliveryExpiresAt,
      Long receivedReportedAt,
      Long storedReportedAt,
      String rejectionCode) {}

  record Document(
      int schemaVersion,
      long generatedAt,
      String correlationId,
      Scope scope,
      Versions versions,
      DeviceStatus device,
      List<Capability> capabilities,
      int omittedCapabilityCount,
      List<Configuration> configurations,
      String evidenceStatus) {
    Document {
      capabilities = List.copyOf(capabilities);
      configurations = List.copyOf(configurations);
    }
  }

  Document project(
      String tenant,
      FleetDiagnosticSource.Snapshot input,
      List<DeliveryDiagnosticSource.Item> deliveries,
      Map<String, String> policyHashes,
      long now,
      String correlation,
      String serverVersion) {
    if (input == null
        || input.device() == null
        || deliveries == null
        || policyHashes == null
        || now < 0
        || now > SAFE_INTEGER - 30000) throw invalid();
    if (input.capabilities().size() > 70 || deliveries.size() > 100) throw tooLarge();
    var device = input.device();
    var scope = new Scope(id(tenant), id(device.id()), id(device.registrationId()));
    var capabilities = new TreeMap<String, Capability>();
    int omitted = 0;
    for (var item : input.capabilities()) {
      if (item == null || item.key() == null) throw invalid();
      if (!CAPABILITIES.contains(item.key())) {
        omitted++;
        continue;
      }
      Long at = observed(item.checkedAt(), now);
      String status =
          item.checkedAt() != null && at == null
              ? "UNKNOWN"
              : known(item.status(), CAPABILITY_STATES);
      var value =
          new Capability(
              item.key(),
              item.reportedSupported(),
              known(item.grantStatus(), GRANTS),
              known(item.evidenceSource(), SOURCES),
              at,
              status,
              known(item.limitationCode(), LIMITATIONS));
      if (capabilities.putIfAbsent(item.key(), value) != null) throw invalid();
    }
    var configurations = new TreeMap<String, Configuration>();
    for (var item : deliveries) {
      if (item == null || item.sourceSequence() < 1 || item.sourceSequence() > SAFE_INTEGER)
        throw invalid();
      String policy = id(item.policyId()), version = id(item.versionId());
      String state = known(item.deliveryState(), DELIVERY_STATES);
      if (!"UNKNOWN".equals(state)
          && !"DEVICE_REPORTED_REJECTED".equals(state)
          && item.storedReportedAt() == null
          && item.deliveryExpiresAt() <= now) state = "EXPIRED_AWAITING_PULL";
      var value =
          new Configuration(
              id(item.id()),
              policy,
              version,
              item.sourceSequence(),
              known(item.action(), Set.of("UPSERT_CONFIGURATION", "REMOVE_CONFIGURATION")),
              state,
              hash(policyHashes.get(version)),
              hash(item.envelopeHash()),
              observed(item.issuedAt(), now),
              timestamp(item.deliveryExpiresAt()),
              observed(item.receivedReportedAt(), now),
              observed(item.storedReportedAt(), now),
              item.rejectionCode() == null
                  ? null
                  : REJECTIONS.contains(item.rejectionCode())
                      ? item.rejectionCode()
                      : "UNKNOWN_REJECTION");
      if (configurations.putIfAbsent(value.id(), value) != null) throw invalid();
    }
    if (device.platform() == null || device.state() == null) throw invalid();
    return new Document(
        1,
        now,
        id(correlation),
        scope,
        new Versions(
            version(device.osVersion()), version(input.agentVersion()), version(serverVersion)),
        new DeviceStatus(
            device.platform().name(),
            device.state().name(),
            known(
                device.managementMode(),
                Set.of("BYOD", "WORK_PROFILE", "FULLY_MANAGED", "DEDICATED", "UNVERIFIED")),
            known(device.controlLevel(), Set.of("LIMITED", "NONE")),
            known(device.observationStatus(), Set.of("RECENT", "STALE", "REVOKED", "UNKNOWN")),
            observed(device.lastHeartbeatAt(), now)),
        List.copyOf(capabilities.values()),
        omitted,
        List.copyOf(configurations.values()),
        "DEVICE_REPORTS_NOT_EXECUTION_PROOF");
  }

  private Version version(String value) {
    if (value == null || value.isBlank()) return new Version(null, "UNREPORTED");
    if (!value.matches("[0-9]{1,4}(\\.[0-9]{1,4}){0,3}")) return new Version(null, "REDACTED");
    return new Version(value, "REPORTED");
  }

  private String id(String value) {
    if (value == null
        || !value.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
      throw invalid();
    return value;
  }

  private String known(String value, Set<String> allowed) {
    return value != null && allowed.contains(value) ? value : "UNKNOWN";
  }

  private String hash(String value) {
    return value != null && value.matches("[0-9a-f]{64}") ? value : null;
  }

  private Long timestamp(Long value) {
    return value != null && value >= 0 && value <= SAFE_INTEGER ? value : null;
  }

  private Long observed(Long value, long now) {
    return timestamp(value) != null && value <= now + 30000 ? value : null;
  }

  private DomainException invalid() {
    return new DomainException(HttpStatus.BAD_GATEWAY, "DIAGNOSTIC_SOURCE_INVALID");
  }

  private DomainException tooLarge() {
    return new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "DIAGNOSTIC_TOO_LARGE");
  }
}

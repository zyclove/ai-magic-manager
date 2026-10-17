package com.aimanager.managedandroid.internal;

import com.aimanager.managedandroid.*;
import com.aimanager.shared.AndroidRuntimePermissions;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;

/** Pure local qualification checks. No registration, tenant grant, ownership or provider I/O. */
@Component
class ManagedApplicationControlEvaluator {
  private static final int MAX_BYTES = 16 * 1024;
  private final Map<List<Object>, ManagedControlQualification> byDevice;
  private final String catalogRevision;
  private final ManagedPolicyDocumentCompilers compilers;
  private final ManagedDeviceProfileSettings profiles;
  private final Clock clock;
  private final ObjectMapper json =
      new ObjectMapper(
              JsonFactory.builder().enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build())
          .registerModule(new JavaTimeModule())
          .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
          .enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS)
          .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
          .enable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
          .enable(DeserializationFeature.FAIL_ON_NUMBERS_FOR_ENUMS)
          .disable(DeserializationFeature.ACCEPT_FLOAT_AS_INT)
          .disable(MapperFeature.ALLOW_COERCION_OF_SCALARS);

  ManagedApplicationControlEvaluator(
      List<ManagedControlQualification> entries,
      ManagedPolicyDocumentCompilers compilers,
      ManagedDeviceProfileSettings profiles,
      Clock clock) {
    this.compilers = compilers;
    this.profiles = profiles;
    this.clock = clock;
    try {
      if (entries.size() > 1000) throw new IllegalArgumentException();
      var ids = new HashSet<String>();
      var targets = new HashMap<List<Object>, ManagedControlQualification>();
      for (var q : entries) {
        if (q == null
            || !code(q.id())
            || !code(q.revision())
            || q.provider() == null
            || !q.provider().matches("[A-Z][A-Z0-9_]{2,31}")
            || !code(q.reportAdapterRevision())
            || !code(q.compilerRevision())
            || !text(q.manufacturer(), 128)
            || !text(q.model(), 128)
            || !text(q.osBuild(), 512)
            || q.apiLevel() < 30
            || !"DEVICE_OWNER".equals(q.managementMode())
            || q.validFrom() == null
            || q.validUntil() == null
            || q.validFrom().isBefore(Instant.EPOCH)
            || !q.validFrom().isBefore(q.validUntil())
            || Duration.between(q.validFrom(), q.validUntil()).compareTo(Duration.ofDays(366)) > 0
            || !text(q.acceptanceReference(), 256)
            || q.operations().isEmpty()
            || q.operations().size() > 128
            || new HashSet<>(q.operations()).size() != q.operations().size()
            || q.operations().stream().anyMatch(op -> !validOperation(op))
            || !ids.add(q.id())
            || targets.putIfAbsent(
                    List.of(
                        q.provider(),
                        q.reportAdapterRevision(),
                        q.compilerRevision(),
                        q.manufacturer(),
                        q.model(),
                        q.osBuild(),
                        q.apiLevel(),
                        q.managementMode()),
                    q)
                != null) throw new IllegalArgumentException();
      }
      byDevice = Map.copyOf(targets);
      // Immutable deployment metadata is hashed once, not once per application in a batch preview.
      catalogRevision =
          SecretMaterial.hash(
              encodeValue(
                  entries.stream()
                      .sorted(Comparator.comparing(ManagedControlQualification::id))
                      .toList()));
    } catch (RuntimeException invalid) {
      throw new IllegalArgumentException("Invalid managed control qualification configuration");
    }
  }

  /** A change to any approved semantics invalidates cached control facts, never upgrades them. */
  String revision(ManagedAndroidGateway gateway) {
    if (!gateway.supportsApplicationControlReports()) return "identity-only-v1";
    String adapter = gateway.applicationControlReportRevision();
    String compiler = compilers.revision(gateway.providerCode());
    if (!code(adapter) || compiler == null) throw rejected("MANAGED_CONTROL_CONNECTOR_UNSUPPORTED");
    return SecretMaterial.hash(
        encodeValue(
            List.of(
                "managed-control-v1", gateway.providerCode(), adapter, compiler, catalogRevision)));
  }

  Checked verify(
      ManagedAndroidGateway gateway,
      ManagedApplicationIdentityVerifier.Verified identity,
      ManagedApplicationControlReport report,
      Instant retrievedAt) {
    if (!gateway.available() || !gateway.supportsApplicationControlReports())
      throw rejected("MANAGED_CONTROL_CONNECTOR_UNSUPPORTED");
    String adapter = gateway.applicationControlReportRevision();
    String compiler = compilers.revision(gateway.providerCode());
    if (!code(adapter) || compiler == null) throw rejected("MANAGED_CONTROL_CONNECTOR_UNSUPPORTED");
    if (identity == null
        || identity.context() == null
        || report == null
        || report.identity() == null
        || report.device() == null
        || retrievedAt == null) throw rejected("MANAGED_CONTROL_REPORT_INVALID");
    var context = identity.context();
    var app = report.identity();
    Instant now = clock.instant();
    if (!Objects.equals(gateway.providerCode(), context.scope().provider())
        || !Objects.equals(context.scope().providerDeviceName(), app.deviceName())
        || !Objects.equals(context.packageName(), app.packageName())
        || !"DEVICE_OWNER".equals(context.managementMode())
        || !"DEVICE_OWNER".equals(app.managementMode())
        || !"INSTALLED".equals(app.applicationState())
        || !new HashSet<>(app.signingCertificateSha256()).equals(identity.signingCertificates())
        || app.signingCertificateSha256().size() != identity.signingCertificates().size()
        || !now.isBefore(identity.expiresAt())
        || retrievedAt.isAfter(now)
        || retrievedAt.toEpochMilli() != identity.retrievedAt().toEpochMilli()
        || !text(report.manufacturer(), 128)
        || !text(report.model(), 128)
        || !text(report.osBuild(), 512)) throw rejected("MANAGED_CONTROL_REPORT_INVALID");
    if (!"PRIMARY".equals(report.profileScope()))
      throw rejected("MANAGED_CONTROL_PROFILE_UNVERIFIED");
    try {
      // Database identity evidence has millisecond precision; coherent reports use that boundary.
      if (Instant.parse(app.deviceReportedAt()).toEpochMilli()
              != identity.reportedAt().toEpochMilli()
          || Instant.parse(report.device().lastStatusReportTime()).toEpochMilli()
              != identity.reportedAt().toEpochMilli())
        throw rejected("MANAGED_CONTROL_REPORT_INVALID");
    } catch (DateTimeException | NullPointerException invalid) {
      throw rejected("MANAGED_CONTROL_REPORT_INVALID");
    }
    var profile =
        profiles.verifier.verify(
            context.scope().providerDeviceName(),
            context.evidenceNotBefore(),
            report.device(),
            retrievedAt);
    var qualification =
        byDevice.get(
            List.of(
                gateway.providerCode(),
                adapter,
                compiler,
                report.manufacturer(),
                report.model(),
                report.osBuild(),
                profile.apiLevel(),
                profile.managementMode()));
    if (qualification == null) throw rejected("MANAGED_CONTROL_QUALIFICATION_REQUIRED");
    if (now.isBefore(qualification.validFrom())
        || retrievedAt.isBefore(qualification.validFrom())
        || !now.isBefore(qualification.validUntil()))
      throw rejected("MANAGED_CONTROL_QUALIFICATION_EXPIRED");
    Instant expiry =
        Collections.min(
            List.of(identity.expiresAt(), profile.expiresAt(), qualification.validUntil()));
    var operations =
        qualification.operations().stream()
            .sorted(
                Comparator.comparing(
                    op ->
                        op.kind().name()
                            + ":"
                            + op.effect().name()
                            + ":"
                            + Objects.toString(op.permission(), "")))
            .toList();
    return new Checked(qualification.id(), qualification.revision(), operations, expiry);
  }

  String store(ManagedApplicationControlReport report, Instant retrievedAt, Checked checked) {
    String document =
        encodeValue(
            new Stored(
                1,
                checked.qualificationId(),
                checked.qualificationRevision(),
                report,
                retrievedAt.toEpochMilli(),
                checked.expiresAt().toEpochMilli()));
    if (!bounded(document)) throw rejected("MANAGED_CONTROL_REPORT_INVALID");
    return document;
  }

  Checked restore(
      ManagedAndroidGateway gateway,
      ManagedApplicationIdentityVerifier.Verified identity,
      String document) {
    try {
      if (!bounded(document)) throw new IllegalArgumentException();
      var stored = json.readValue(document, Stored.class);
      if (stored == null || stored.schemaVersion() != 1) throw new IllegalArgumentException();
      var checked =
          verify(gateway, identity, stored.report(), Instant.ofEpochMilli(stored.retrievedAt()));
      if (!checked.qualificationId().equals(stored.qualificationId())
          || !checked.qualificationRevision().equals(stored.qualificationRevision())
          || stored.expiresAt() > checked.expiresAt().toEpochMilli()
          || clock.millis() >= stored.expiresAt()) throw new IllegalArgumentException();
      return new Checked(
          checked.qualificationId(),
          checked.qualificationRevision(),
          checked.operations(),
          Instant.ofEpochMilli(stored.expiresAt()));
    } catch (Exception invalid) {
      throw rejected("MANAGED_CONTROL_STORED_EVIDENCE_INVALID");
    }
  }

  private String encodeValue(Object value) {
    try {
      return json.writeValueAsString(value);
    } catch (Exception invalid) {
      throw new IllegalArgumentException("Invalid managed control document");
    }
  }

  private static boolean code(String value) {
    return value != null && value.matches("[A-Za-z0-9._:-]{1,128}");
  }

  private static boolean text(String value, int max) {
    return value != null
        && !value.isBlank()
        && value.length() <= max
        && value.equals(value.strip())
        && value.codePoints().noneMatch(Character::isISOControl);
  }

  private static boolean bounded(String document) {
    return document != null
        && document.length() <= MAX_BYTES
        && document.getBytes(StandardCharsets.UTF_8).length <= MAX_BYTES;
  }

  private static boolean validOperation(ManagedControlOperation operation) {
    if (operation == null || operation.kind() == null || operation.effect() == null) return false;
    return switch (operation.kind()) {
      case APP_LAUNCH, APP_INSTALL ->
          operation.permission() == null
              && (operation.effect() == ManagedControlOperation.Effect.ALLOW
                  || operation.effect() == ManagedControlOperation.Effect.DENY);
      case RUNTIME_PERMISSION ->
          AndroidRuntimePermissions.contains(operation.permission())
              && (operation.effect() == ManagedControlOperation.Effect.DENY
                  || operation.effect() == ManagedControlOperation.Effect.DEFAULT);
    };
  }

  private static DomainException rejected(String code) {
    return new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, code);
  }

  record Checked(
      String qualificationId,
      String qualificationRevision,
      List<ManagedControlOperation> operations,
      Instant expiresAt) {
    Checked {
      operations = List.copyOf(operations);
    }

    @Override
    public String toString() {
      return "CheckedManagedControl[REDACTED]";
    }
  }

  private record Stored(
      int schemaVersion,
      String qualificationId,
      String qualificationRevision,
      ManagedApplicationControlReport report,
      long retrievedAt,
      long expiresAt) {}
}

package com.aimanager.managedandroid.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.catalog.ApplicationIdentity;
import com.aimanager.managedandroid.ManagedAndroidGateway;
import com.aimanager.managedandroid.ManagedApplicationIdentityVerifier;
import com.aimanager.managedandroid.ManagedApplicationReport;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.time.Instant;
import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

/**
 * Short transactions only. Persisted facts never grant policy execution or Android profile scope.
 */
@Service
@Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
class ManagedApplicationEvidenceStore {
  private final ManagedAgentBindingStore bindings;
  private final ManagedEnrollmentStore enrollments;
  private final ApplicationCatalog catalog;
  private final ManagedAndroidGateway gateway;
  private final ManagedApplicationEvidenceSettings settings;
  private final JdbcTemplate db;
  private final ObjectMapper json;
  private final Clock clock;
  private final AuditService audit;

  ManagedApplicationEvidenceStore(
      ManagedAgentBindingStore bindings,
      ManagedEnrollmentStore enrollments,
      ApplicationCatalog catalog,
      ManagedAndroidGateway gateway,
      ManagedApplicationEvidenceSettings settings,
      JdbcTemplate db,
      ObjectMapper json,
      Clock clock,
      AuditService audit) {
    this.bindings = bindings;
    this.enrollments = enrollments;
    this.catalog = catalog;
    this.gateway = gateway;
    this.settings = settings;
    this.db = db;
    this.json = json;
    this.clock = clock;
    this.audit = audit;
  }

  Capture begin(
      String tenant, String actor, String binding, long bindingVersion, String application) {
    var context = current(tenant, actor, binding, bindingVersion, application);
    var previous = stored(context, true);
    long now = clock.millis();
    if (previous != null && "PENDING".equals(previous.state()) && now < previous.attemptExpiresAt())
      throw conflict("MANAGED_APPLICATION_REFRESH_PENDING");
    if (previous != null && now < previous.nextAttemptAt())
      throw new DomainException(
          HttpStatus.TOO_MANY_REQUESTS, "MANAGED_APPLICATION_REFRESH_THROTTLED");
    // The already-held binding lock serializes different applications, including first inserts.
    if (previous == null
        && db.queryForObject(
                "SELECT COUNT(*) FROM managed_application_evidence WHERE tenant_id=? AND"
                    + " binding_id=?",
                Long.class,
                tenant,
                binding)
            >= ManagedApplicationEvidenceSettings.MAX_APPLICATIONS)
      throw conflict("MANAGED_APPLICATION_EVIDENCE_LIMIT");
    if (previous != null && previous.version() >= 9007199254740990L)
      throw conflict("VERSION_EXHAUSTED");
    long version = previous == null ? 1 : previous.version() + 1;
    String id = previous == null ? UUID.randomUUID().toString() : previous.id();
    String attempt = UUID.randomUUID().toString();
    long deadline = Math.addExact(now, ManagedApplicationEvidenceSettings.ATTEMPT_MILLIS);
    long next = Math.addExact(now, ManagedApplicationEvidenceSettings.COOLDOWN_MILLIS);
    if (previous == null) {
      db.update(
          "INSERT INTO"
              + " managed_application_evidence(tenant_id,binding_id,application_id,id,context_revision,state,reason_code,version,attempt_id,attempt_expires_at,next_attempt_at,created_at,updated_at)"
              + " VALUES(?,?,?,?,?,'PENDING','MANAGED_APPLICATION_REFRESH_PENDING',?,?,?,?,?,?)",
          tenant,
          binding,
          application,
          id,
          context.fingerprint(),
          version,
          attempt,
          deadline,
          next,
          now,
          now);
    } else {
      exactlyOne(
          db.update(
              "UPDATE managed_application_evidence SET"
                  + " context_revision=?,state='PENDING',reason_code='MANAGED_APPLICATION_REFRESH_PENDING',version=?,attempt_id=?,attempt_expires_at=?,next_attempt_at=?,signing_digests_json=NULL,reported_at=NULL,retrieved_at=NULL,expires_at=NULL,updated_at=?"
                  + " WHERE tenant_id=? AND binding_id=? AND application_id=? AND version=?",
              context.fingerprint(),
              version,
              attempt,
              deadline,
              next,
              now,
              tenant,
              binding,
              application,
              previous.version()));
    }
    audit.record(tenant, actor, "MANAGED_APPLICATION_REFRESH_REQUESTED", id);
    return new Capture(context, id, version, attempt);
  }

  /** Both success and provider failure use this same current-authority and attempt CAS boundary. */
  View finish(
      Capture captured,
      ManagedAndroidGateway.ManagedEnrollmentIdentity first,
      ManagedAndroidGateway.ManagedEnrollmentIdentity last,
      ManagedApplicationReport report,
      Instant retrievedAt,
      boolean providerFailed) {
    var before = captured.context();
    var binding = before.binding();
    var context =
        current(
            binding.tenantId(),
            binding.actorId(),
            binding.bindingId(),
            binding.bindingVersion(),
            before.application().applicationId());
    // Actor/authority epoch participate in the in-flight comparison but not shared fact identity.
    if (!before.equals(context)) throw conflict("MANAGED_APPLICATION_CONTEXT_CHANGED");
    var row = stored(context, true);
    if (row == null
        || !"PENDING".equals(row.state())
        || row.version() != captured.version()
        || !captured.attemptId().equals(row.attemptId())
        || !captured.id().equals(row.id())) throw conflict("MANAGED_APPLICATION_ATTEMPT_CHANGED");
    if (clock.millis() >= row.attemptExpiresAt())
      throw conflict("MANAGED_APPLICATION_ATTEMPT_EXPIRED");
    String state = "FAILED", reason = "MANAGED_APPLICATION_PROVIDER_UNAVAILABLE";
    ManagedApplicationIdentityVerifier.Verified verified = null;
    if (!providerFailed) {
      try {
        var intent =
            enrollments.forProviderStatus(
                binding.tenantId(), binding.enrollmentId(), binding.actorId());
        ManagedEnrollmentStore.requireProvenance(intent, binding.providerDeviceId(), first);
        ManagedEnrollmentStore.requireProvenance(intent, binding.providerDeviceId(), last);
        if (!first.equals(last)) throw conflict("EMM_DEVICE_IDENTITY_CHANGED");
        if (report == null) {
          state = "WAITING_REPORT";
          reason = "MANAGED_APPLICATION_REPORT_MISSING";
        } else {
          verified =
              settings.verifier.verify(before.identity(), context.identity(), report, retrievedAt);
          state = "VERIFIED";
          reason = "MANAGED_APPLICATION_PROFILE_UNVERIFIED";
        }
      } catch (DomainException rejected) {
        state = "REJECTED";
        reason = rejected.errorCode();
      }
    }
    exactlyOne(
        db.update(
            "UPDATE managed_application_evidence SET"
                + " state=?,reason_code=?,version=version+1,attempt_id=NULL,attempt_expires_at=0,signing_digests_json=?,reported_at=?,retrieved_at=?,expires_at=?,updated_at=?"
                + " WHERE tenant_id=? AND binding_id=? AND application_id=? AND version=? AND"
                + " attempt_id=?",
            state,
            reason,
            verified == null
                ? null
                : encode(verified.signingCertificates().stream().sorted().toList()),
            verified == null ? null : verified.reportedAt().toEpochMilli(),
            verified == null ? null : verified.retrievedAt().toEpochMilli(),
            verified == null ? null : verified.expiresAt().toEpochMilli(),
            clock.millis(),
            binding.tenantId(),
            binding.bindingId(),
            context.application().applicationId(),
            captured.version(),
            captured.attemptId()));
    audit.record(
        binding.tenantId(), binding.actorId(), "MANAGED_APPLICATION_EVIDENCE_" + state, row.id());
    return view(context, stored(context, false));
  }

  View get(String tenant, String actor, String binding, long bindingVersion, String application) {
    var context = current(tenant, actor, binding, bindingVersion, application);
    return view(context, stored(context, false));
  }

  private Context current(
      String tenant, String actor, String binding, long version, String application) {
    var current = bindings.requireVerifiedContext(tenant, actor, binding, version);
    var app = catalog.requireEvidenceIdentity(tenant, actor, application);
    if (current.platform() != app.platform())
      throw conflict("MANAGED_APPLICATION_PLATFORM_MISMATCH");
    String connector = gateway.applicationReportRevision();
    if (!gateway.supportsApplicationReports()
        || connector == null
        || !connector.matches("[A-Za-z0-9._-]{1,128}"))
      throw new DomainException(
          HttpStatus.SERVICE_UNAVAILABLE, "MANAGED_APPLICATION_CONNECTOR_UNSUPPORTED");
    long notBefore =
        Math.max(
            current.registeredAt(),
            Math.max(current.bindingVerifiedAt(), app.establishedAt().toEpochMilli()));
    var scope =
        new ManagedApplicationIdentityVerifier.Scope(
            tenant,
            current.deviceId(),
            current.registrationId(),
            current.keyThumbprint(),
            binding,
            current.bindingVersion(),
            current.provider(),
            "enterprises/" + current.enterpriseId() + "/devices/" + current.providerDeviceId(),
            current.enterpriseBindingVersion(),
            connector);
    var identity =
        new ManagedApplicationIdentityVerifier.Context(
            scope,
            app.applicationId(),
            app.revision(),
            app.packageName(),
            Set.copyOf(app.signingDigests()),
            current.managementMode(),
            Instant.ofEpochMilli(notBefore),
            true);
    // Serialize sorted declaration digests, not the verifier's Set iteration order (which varies by
    // JVM).
    String fingerprint =
        SecretMaterial.hash(
            encode(
                List.of(
                    scope,
                    app,
                    current.managementMode(),
                    notBefore,
                    current.subjectId(),
                    current.enrollmentId(),
                    current.enrollmentVersion(),
                    current.agentPackageName(),
                    current.agentTrustRevision(),
                    current.registeredAt(),
                    settings.revision)));
    return new Context(current, app, identity, fingerprint);
  }

  private Stored stored(Context context, boolean lock) {
    var rows =
        db.query(
            "SELECT * FROM managed_application_evidence WHERE tenant_id=? AND binding_id=? AND"
                + " application_id=?"
                + (lock ? " FOR UPDATE" : ""),
            (row, index) -> row(row),
            context.binding().tenantId(),
            context.binding().bindingId(),
            context.application().applicationId());
    return rows.isEmpty() ? null : rows.get(0);
  }

  private View view(Context context, Stored row) {
    if (row == null) return view(context, null, "ABSENT", "MANAGED_APPLICATION_EVIDENCE_REQUIRED");
    if (!row.contextRevision().equals(context.fingerprint()))
      return view(context, row, "STALE", "MANAGED_APPLICATION_CONTEXT_CHANGED");
    if ("PENDING".equals(row.state()) && clock.millis() >= row.attemptExpiresAt())
      return view(context, row, "STALE", "MANAGED_APPLICATION_ATTEMPT_EXPIRED");
    if (!"VERIFIED".equals(row.state())) return view(context, row, row.state(), row.reason());
    if (row.expiresAt() == null || clock.millis() >= row.expiresAt())
      return view(context, row, "STALE", "MANAGED_APPLICATION_REPORT_STALE");
    try {
      if (row.reportedAt() == null
          || row.retrievedAt() == null
          || row.signers() == null
          || row.signers().length() > 600) throw new IllegalArgumentException();
      var signers = json.readValue(row.signers(), String[].class);
      if (signers == null || Arrays.stream(signers).anyMatch(java.util.Objects::isNull))
        throw new IllegalArgumentException();
      var report =
          new ManagedApplicationReport(
              context.identity().scope().providerDeviceName(),
              context.binding().managementMode(),
              context.application().packageName(),
              "INSTALLED",
              Arrays.asList(signers),
              Instant.ofEpochMilli(row.reportedAt()).toString());
      var verified =
          settings.verifier.verify(
              context.identity(),
              context.identity(),
              report,
              Instant.ofEpochMilli(row.retrievedAt()));
      if (row.expiresAt() > verified.expiresAt().toEpochMilli())
        throw new IllegalArgumentException();
    } catch (JsonProcessingException | IllegalArgumentException | DomainException invalid) {
      return view(context, row, "STALE", "MANAGED_APPLICATION_STORED_EVIDENCE_INVALID");
    }
    return view(context, row, "VERIFIED_IDENTITY", "MANAGED_APPLICATION_PROFILE_UNVERIFIED");
  }

  private View view(Context context, Stored row, String state, String reason) {
    boolean valid = state.equals("VERIFIED_IDENTITY");
    return new View(
        context.binding().bindingId(),
        context.application().applicationId(),
        state,
        reason,
        row == null ? 0 : row.version(),
        "UNKNOWN",
        false,
        valid ? row.reportedAt() : null,
        valid ? row.retrievedAt() : null,
        valid ? row.expiresAt() : null,
        row == null ? null : row.nextAttemptAt());
  }

  private Stored row(ResultSet row) throws SQLException {
    return new Stored(
        row.getString("id"),
        row.getString("context_revision"),
        row.getString("state"),
        row.getString("reason_code"),
        row.getLong("version"),
        row.getString("attempt_id"),
        row.getLong("attempt_expires_at"),
        row.getLong("next_attempt_at"),
        row.getString("signing_digests_json"),
        row.getObject("reported_at", Long.class),
        row.getObject("retrieved_at", Long.class),
        row.getObject("expires_at", Long.class));
  }

  private String encode(Object value) {
    try {
      return json.writeValueAsString(value);
    } catch (JsonProcessingException invalid) {
      throw new IllegalStateException("Application evidence serialization failed");
    }
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private static void exactlyOne(int rows) {
    if (rows != 1) throw conflict("MANAGED_APPLICATION_ATTEMPT_CHANGED");
  }

  record Capture(Context context, String id, long version, String attemptId) {
    @Override
    public String toString() {
      return "ApplicationEvidenceCapture[REDACTED]";
    }
  }

  record Context(
      ManagedAgentBindingStore.VerifiedBindingContext binding,
      ApplicationIdentity application,
      ManagedApplicationIdentityVerifier.Context identity,
      String fingerprint) {
    @Override
    public String toString() {
      return "ApplicationEvidenceContext[REDACTED]";
    }
  }

  private record Stored(
      String id,
      String contextRevision,
      String state,
      String reason,
      long version,
      String attemptId,
      long attemptExpiresAt,
      long nextAttemptAt,
      String signers,
      Long reportedAt,
      Long retrievedAt,
      Long expiresAt) {
    @Override
    public String toString() {
      return "ApplicationEvidenceRow[REDACTED]";
    }
  }

  record View(
      String bindingId,
      String applicationId,
      String state,
      String reasonCode,
      long version,
      String profileScope,
      boolean systemControlAvailable,
      Long reportedAt,
      Long retrievedAt,
      Long expiresAt,
      Long nextRefreshAt) {
    @Override
    public String toString() {
      return "ApplicationEvidenceView[REDACTED]";
    }
  }
}

package com.aimanager.policy.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.managedandroid.ManagedDesiredPolicy;
import com.aimanager.managedandroid.ManagedExecutionPublicationAccess;
import com.aimanager.policy.PolicySnapshot;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Reads immutable published inputs, never changes CONFIGURE_ONLY into an execution request. */
@Service
class ManagedExecutionPublicationReader implements ManagedExecutionPublicationAccess {
  private final JdbcTemplate db;
  private final ObjectMapper json;
  private final TenantAccess access;

  ManagedExecutionPublicationReader(JdbcTemplate db, ObjectMapper json, TenantAccess access) {
    this.db = db;
    this.json =
        json.copy()
            .disable(com.fasterxml.jackson.databind.MapperFeature.ALLOW_COERCION_OF_SCALARS)
            .enable(com.fasterxml.jackson.core.JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
            .enable(
                com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES)
            .enable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_NUMBERS_FOR_ENUMS)
            .disable(com.fasterxml.jackson.databind.DeserializationFeature.ACCEPT_FLOAT_AS_INT)
            .enable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
    this.access = access;
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY, noRollbackFor = DomainException.class)
  public Publication requireTarget(
      String tenant, String actor, String publication, String device, String registration) {
    return load(tenant, actor, publication, device, registration).publication();
  }

  /**
   * Returns the entire immutable selection, never a live device search or a partial valid subset.
   * Binding, current registration and provider eligibility are checked separately during admission.
   */
  @Override
  @Transactional(propagation = Propagation.MANDATORY, noRollbackFor = DomainException.class)
  public Targets requireTargets(String tenant, String actor, String publication) {
    if (!TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Execution publication snapshot requires a transaction");
    var loaded = loadSnapshot(tenant, actor, publication);
    var source = loaded.snapshot().targets();
    if (source.isEmpty() || source.size() > 50) throw invalidPublication();
    var devices = new HashSet<String>();
    var targets = new ArrayList<Target>(source.size());
    for (var target : source) {
      if (target == null
          || !canonicalId(target.deviceId())
          || !canonicalId(target.registrationId())
          || !devices.add(target.deviceId())) throw invalidPublication();
      targets.add(new Target(target.deviceId(), target.registrationId()));
    }
    targets.sort(Comparator.comparing(Target::deviceId));
    return new Targets(loaded.publication(), targets);
  }

  private static boolean canonicalId(String id) {
    try {
      return id != null && UUID.fromString(id).toString().equals(id);
    } catch (IllegalArgumentException malformed) {
      return false;
    }
  }

  private static IllegalStateException invalidPublication() {
    return new IllegalStateException("Invalid stored execution publication");
  }

  private Loaded load(
      String tenant, String actor, String publication, String device, String registration) {
    var loaded = loadSnapshot(tenant, actor, publication);
    var targets =
        loaded.snapshot().targets().stream()
            .filter(t -> t != null && device.equals(t.deviceId()))
            .toList();
    if (targets.size() != 1 || !registration.equals(targets.get(0).registrationId()))
      throw new DomainException(HttpStatus.CONFLICT, "EXECUTION_PUBLICATION_TARGET_MISMATCH");
    return new Loaded(loaded.publication(), loaded.snapshot(), targets.get(0));
  }

  private Snapshot loadSnapshot(String tenant, String actor, String publication) {
    access.requireWriteRole(tenant, actor, OWNER, ORG_ADMIN);
    var rows =
        db.query(
            "SELECT v.id,v.mode,v.preview_hash,v.snapshot_json,v.created_at FROM"
                + " policy_publications p JOIN policy_versions v ON v.tenant_id=p.tenant_id AND"
                + " v.id=p.version_id WHERE p.tenant_id=? AND p.id=?",
            (r, n) ->
                new Row(
                    r.getString(1), r.getString(2), r.getString(3), r.getString(4), r.getLong(5)),
            tenant,
            publication);
    if (rows.size() != 1) throw DomainException.denied();
    var row = rows.get(0);
    if (!"ENFORCE".equals(row.mode()))
      throw new DomainException(HttpStatus.CONFLICT, "EXECUTION_PUBLICATION_REQUIRED");
    final PolicySnapshot snapshot;
    try {
      if (row.snapshot() == null || row.snapshot().length() > 4 * 1024 * 1024)
        throw new IllegalStateException();
      snapshot = json.readValue(row.snapshot(), PolicySnapshot.class);
    } catch (Exception malformed) {
      throw new IllegalStateException("Invalid stored execution publication");
    }
    if (snapshot == null || snapshot.schemaVersion() != 1 || snapshot.targets() == null)
      throw new IllegalStateException("Invalid stored execution publication");
    return new Snapshot(new Publication(row.id(), row.hash(), row.createdAt()), snapshot);
  }

  private record Snapshot(Publication publication, PolicySnapshot snapshot) {}

  private record Loaded(
      Publication publication, PolicySnapshot snapshot, PolicySnapshot.Target target) {}

  private record Row(String id, String mode, String hash, String snapshot, long createdAt) {}

  @Override
  @Transactional(propagation = Propagation.MANDATORY, noRollbackFor = DomainException.class)
  public ManagedDesiredPolicy requireDesiredTarget(
      String tenant, String actor, String publication, String device, String registration) {
    var loaded = load(tenant, actor, publication, device, registration);
    return new ManagedDesiredPolicyResolver()
        .resolve(loaded.publication(), loaded.snapshot(), loaded.target());
  }
}

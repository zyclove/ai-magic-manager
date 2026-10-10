package com.aimanager.commerce.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.commerce.internal.CommercialFact.CapacityKind;
import com.aimanager.commerce.internal.CommercialFact.Feature;
import com.aimanager.commerce.internal.CommercialFact.State;
import com.aimanager.shared.DomainException;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Stores normalized, already-verified commercial facts. No public API calls {@link #apply}; a
 * future certified payment or contract adapter must verify its source before invoking it.
 */
@Service
class CommercialLedger {
  private static final Pattern PRODUCT_KEY = Pattern.compile("[A-Z0-9_]{1,80}");
  private static final Pattern SHA256 = Pattern.compile("[0-9a-f]{64}");
  private static final int MAX_CAPACITY = 1_000_000;
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final AuditService audit;
  private final ObjectMapper json;
  private final Clock clock;

  CommercialLedger(
      JdbcTemplate jdbc, TenantAccess access, AuditService audit, ObjectMapper json, Clock clock) {
    this.jdbc = jdbc;
    this.access = access;
    this.audit = audit;
    this.json = json;
    this.clock = clock;
  }

  /**
   * Idempotent for the same source revision and payload. A changed or stale revision is rejected;
   * accepted revisions atomically update current state, immutable history, account version and
   * audit.
   */
  @Transactional(timeout = 10)
  ApplyResult apply(CommercialFact fact) {
    validate(fact);
    String sourceKey = sha256(fact.sourceSystem().name() + "\u0000" + fact.sourceReference());
    List<String> features = fact.features().stream().map(Enum::name).sorted().toList();
    String featuresJson = encode(features);
    String payloadHash =
        sha256(
            String.join(
                "\u0000",
                List.of(
                    fact.sourceSystem().name(),
                    sourceKey,
                    Long.toString(fact.sourceRevision()),
                    fact.productKey(),
                    fact.capacityKind().name(),
                    Integer.toString(fact.deviceCapacity()),
                    featuresJson,
                    Long.toString(fact.activeFrom()),
                    Long.toString(fact.expiresAt()),
                    fact.state().name(),
                    fact.evidenceHash(),
                    fact.verifiedBy())));
    if (jdbc.queryForObject(
            "SELECT COUNT(*) FROM tenants WHERE id=?", Integer.class, fact.tenantId())
        == 0) {
      throw DomainException.invalid("UNKNOWN_COMMERCIAL_TENANT");
    }
    // MySQL and H2 MySQL mode both support this idempotent account creation. It serializes all
    // sources of one tenant without locking the shared tenant parent row for the full operation.
    jdbc.update(
        "INSERT INTO commercial_accounts(tenant_id,version) VALUES(?,0)"
            + " ON DUPLICATE KEY UPDATE tenant_id=tenant_id",
        fact.tenantId());
    long version =
        jdbc.queryForObject(
            "SELECT version FROM commercial_accounts WHERE tenant_id=? FOR UPDATE",
            Long.class,
            fact.tenantId());
    List<Existing> previous =
        jdbc.query(
            "SELECT source_revision,payload_hash FROM commercial_sources"
                + " WHERE tenant_id=? AND source_system=? AND source_key=? FOR UPDATE",
            (row, index) -> new Existing(row.getLong(1), row.getString(2)),
            fact.tenantId(),
            fact.sourceSystem().name(),
            sourceKey);
    if (!previous.isEmpty()) {
      Existing old = previous.get(0);
      if (fact.sourceRevision() == old.revision() && payloadHash.equals(old.payloadHash())) {
        return new ApplyResult(version, false);
      }
      if (fact.sourceRevision() <= old.revision()) {
        throw new DomainException(HttpStatus.CONFLICT, "COMMERCIAL_SOURCE_REVISION_CONFLICT");
      }
      jdbc.update(
          "UPDATE commercial_sources SET source_revision=?,product_key=?,capacity_kind=?,"
              + "device_capacity=?,features_json=?,active_from=?,expires_at=?,state=?,"
              + "payload_hash=?,evidence_hash=?,verified_by=?,verified_at=? WHERE tenant_id=? AND"
              + " source_system=? AND source_key=?",
          fact.sourceRevision(),
          fact.productKey(),
          fact.capacityKind().name(),
          fact.deviceCapacity(),
          featuresJson,
          fact.activeFrom(),
          fact.expiresAt(),
          fact.state().name(),
          payloadHash,
          fact.evidenceHash(),
          fact.verifiedBy(),
          clock.millis(),
          fact.tenantId(),
          fact.sourceSystem().name(),
          sourceKey);
    } else {
      jdbc.update(
          "INSERT INTO commercial_sources(tenant_id,source_system,source_key,source_revision,"
              + "product_key,capacity_kind,device_capacity,features_json,active_from,expires_at,state,payload_hash,evidence_hash,verified_by,verified_at)"
              + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
          fact.tenantId(),
          fact.sourceSystem().name(),
          sourceKey,
          fact.sourceRevision(),
          fact.productKey(),
          fact.capacityKind().name(),
          fact.deviceCapacity(),
          featuresJson,
          fact.activeFrom(),
          fact.expiresAt(),
          fact.state().name(),
          payloadHash,
          fact.evidenceHash(),
          fact.verifiedBy(),
          clock.millis());
    }
    jdbc.update(
        "INSERT INTO commercial_source_events(tenant_id,source_system,source_key,source_revision,"
            + "id,product_key,capacity_kind,device_capacity,features_json,active_from,expires_at,state,payload_hash,evidence_hash,verified_by,verified_at)"
            + " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        fact.tenantId(),
        fact.sourceSystem().name(),
        sourceKey,
        fact.sourceRevision(),
        UUID.randomUUID().toString(),
        fact.productKey(),
        fact.capacityKind().name(),
        fact.deviceCapacity(),
        featuresJson,
        fact.activeFrom(),
        fact.expiresAt(),
        fact.state().name(),
        payloadHash,
        fact.evidenceHash(),
        fact.verifiedBy(),
        clock.millis());
    jdbc.update(
        "UPDATE commercial_accounts SET version=version+1 WHERE tenant_id=?", fact.tenantId());
    audit.record(fact.tenantId(), fact.verifiedBy(), "COMMERCIAL_FACT_ACCEPTED", sourceKey);
    return new ApplyResult(version + 1, true);
  }

  @Transactional(readOnly = true, timeout = 10)
  CommercialEntitlementView read(String tenantId, String actorId) {
    access.requireRole(tenantId, actorId, Role.OWNER, Role.GUARDIAN, Role.ORG_ADMIN, Role.AUDITOR);
    long now = clock.millis();
    List<Row> rows =
        jdbc.query(
            "SELECT COALESCE(a.version,0) AS account_version,s.capacity_kind,s.device_capacity,"
                + "s.features_json,s.active_from,s.expires_at,s.state FROM tenants t"
                + " LEFT JOIN commercial_accounts a ON a.tenant_id=t.id"
                + " LEFT JOIN commercial_sources s ON s.tenant_id=t.id AND s.state='ACTIVE'"
                + " AND s.active_from<=? AND s.expires_at>? WHERE t.id=?",
            (r, i) ->
                new Row(
                    r.getLong("account_version"),
                    r.getString("capacity_kind"),
                    r.getInt("device_capacity"),
                    r.getString("features_json"),
                    r.getLong("active_from"),
                    r.getLong("expires_at"),
                    r.getString("state")),
            now,
            now,
            tenantId);
    long version = rows.isEmpty() ? 0 : rows.get(0).version();
    long base = 0;
    long addOn = 0;
    int active = 0;
    Set<String> baseFeatures = new HashSet<>();
    Set<String> addOnFeatures = new HashSet<>();
    for (Row row : rows) {
      if (!State.ACTIVE.name().equals(row.state())
          || row.activeFrom() > now
          || row.expiresAt() <= now) continue;
      active++;
      if (CapacityKind.BASE.name().equals(row.capacityKind())) {
        base = Math.max(base, row.deviceCapacity());
        baseFeatures.addAll(decode(row.featuresJson()));
      } else if (CapacityKind.ADD_ON.name().equals(row.capacityKind())) {
        addOn = Math.addExact(addOn, row.deviceCapacity());
        addOnFeatures.addAll(decode(row.featuresJson()));
      }
    }
    // Add-ons require a live base plan; commercial expiry never disables basic safety controls.
    long effectiveAddOn = base > 0 ? addOn : 0;
    long total = Math.addExact(base, effectiveAddOn);
    if (base > 0) baseFeatures.addAll(addOnFeatures);
    return new CommercialEntitlementView(
        tenantId,
        version,
        now,
        active,
        base,
        effectiveAddOn,
        total,
        baseFeatures.stream().sorted(Comparator.naturalOrder()).toList(),
        true);
  }

  private void validate(CommercialFact fact) {
    if (fact == null
        || fact.tenantId() == null
        || fact.sourceSystem() == null
        || fact.sourceReference() == null
        || fact.sourceReference().isBlank()
        || fact.sourceReference().length() > 200
        || fact.sourceRevision() < 1
        || fact.productKey() == null
        || !PRODUCT_KEY.matcher(fact.productKey()).matches()
        || fact.capacityKind() == null
        || fact.deviceCapacity() < 0
        || fact.deviceCapacity() > MAX_CAPACITY
        || fact.features() == null
        || fact.features().stream().anyMatch(Objects::isNull)
        || fact.activeFrom() < 0
        || fact.expiresAt() <= fact.activeFrom()
        || fact.state() == null
        || fact.evidenceHash() == null
        || !SHA256.matcher(fact.evidenceHash()).matches()
        || fact.verifiedBy() == null
        || fact.verifiedBy().isBlank()
        || fact.verifiedBy().length() > 255
        || fact.verifiedBy().chars().anyMatch(Character::isISOControl)) {
      throw DomainException.invalid("INVALID_COMMERCIAL_FACT");
    }
  }

  private String encode(List<String> values) {
    try {
      return json.writeValueAsString(values);
    } catch (JsonProcessingException error) {
      throw new IllegalStateException("Unable to encode entitlement", error);
    }
  }

  private List<String> decode(String value) {
    if (value == null) return List.of();
    try {
      String[] entries = json.readValue(value, String[].class);
      List<String> output = new ArrayList<>();
      for (String entry : entries) output.add(Feature.valueOf(entry).name());
      return List.copyOf(output);
    } catch (JsonProcessingException | IllegalArgumentException error) {
      throw new IllegalStateException("Invalid stored entitlement features", error);
    }
  }

  private static String sha256(String value) {
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException impossible) {
      throw new IllegalStateException("SHA-256 unavailable", impossible);
    }
  }

  record ApplyResult(long accountVersion, boolean changed) {}

  private record Existing(long revision, String payloadHash) {}

  private record Row(
      long version,
      String capacityKind,
      int deviceCapacity,
      String featuresJson,
      long activeFrom,
      long expiresAt,
      String state) {}
}

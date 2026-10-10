package com.aimanager.catalog.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.*;
import com.aimanager.fleet.Device;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.shared.*;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
class ClassificationService implements ApplicationCategories {
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private final ApplicationCatalog catalog;
  private final IdempotencyService idempotency;
  private final AuditService audit;
  private final Clock clock;

  ClassificationService(
      JdbcTemplate jdbc,
      TenantAccess access,
      ApplicationCatalog catalog,
      IdempotencyService idempotency,
      AuditService audit,
      Clock clock) {
    this.jdbc = jdbc;
    this.access = access;
    this.catalog = catalog;
    this.idempotency = idempotency;
    this.audit = audit;
    this.clock = clock;
  }

  Classification read(String tenant, String actor, String applicationId) {
    var app = catalog.requireDeclared(tenant, actor, applicationId);
    return current(tenant, identity(app), false);
  }

  @Transactional(timeout = 10)
  public Classification update(
      String tenant,
      String actor,
      String applicationId,
      long expected,
      String key,
      Category category) {
    access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
    var identity = identity(catalog.requireKnownIdentity(tenant, applicationId));
    return idempotency.execute(
        tenant,
        actor,
        "application.classification",
        key,
        Map.of("applicationId", applicationId, "expectedVersion", expected, "category", category),
        Classification.class,
        () -> {
          // Atomic creation obtains a write lock even for the first update. No shared gap-lock
          // upgrade.
          jdbc.update(
              "INSERT INTO"
                  + " application_classifications(tenant_id,identity_hash,platform,profile,package_name,category,version)"
                  + " VALUES(?,?,?,?,?,'UNCLASSIFIED',0) ON DUPLICATE KEY UPDATE"
                  + " identity_hash=identity_hash",
              tenant,
              hash(identity),
              identity.platform().name(),
              identity.profile().name(),
              identity.packageName());
          var before = current(tenant, identity, true);
          ResourceVersions.check(expected, before.version());
          if (before.version() >= 9007199254740991L)
            throw DomainException.invalid("VERSION_EXHAUSTED");
          long now = clock.millis(), version = before.version() + 1;
          jdbc.update(
              "UPDATE application_classifications SET category=?,version=?,updated_at=? WHERE"
                  + " tenant_id=? AND identity_hash=?",
              category.name(),
              version,
              now,
              tenant,
              hash(identity));
          audit.record(tenant, actor, "APPLICATION_CLASSIFICATION_CHANGED", applicationId);
          return new Classification(identity, category, "ADMIN_DECLARED", version, now);
        });
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public Map<Identity, Classification> forAuthorizedUsageReport(
      String tenant, Set<Identity> identities) {
    if (identities == null
        || identities.size() > 2000
        || identities.stream().anyMatch(Objects::isNull))
      throw DomainException.invalid("INVALID_REPORT_SELECTION");
    var requested = new TreeMap<String, Identity>();
    identities.forEach(identity -> requested.put(hash(identity), identity));
    var result = new HashMap<Identity, Classification>();
    identities.forEach(identity -> result.put(identity, Classification.unclassified(identity)));
    var hashes = new ArrayList<>(requested.keySet());
    for (int offset = 0; offset < hashes.size(); offset += 250) {
      var chunk = hashes.subList(offset, Math.min(offset + 250, hashes.size()));
      var args = new ArrayList<Object>();
      args.add(tenant);
      args.addAll(chunk);
      var rows =
          jdbc.query(
              "SELECT platform,profile,package_name,category,version,updated_at FROM"
                  + " application_classifications WHERE tenant_id=? AND identity_hash IN ("
                  + String.join(",", Collections.nCopies(chunk.size(), "?"))
                  + ")",
              (row, index) ->
                  new Classification(
                      new Identity(
                          Device.Platform.valueOf(row.getString(1)),
                          ApplicationDefinition.Profile.valueOf(row.getString(2)),
                          row.getString(3)),
                      Category.valueOf(row.getString(4)),
                      row.getLong(5) == 0 ? "NONE" : "ADMIN_DECLARED",
                      row.getLong(5),
                      row.getObject(6) == null ? null : row.getLong(6)),
              args.toArray());
      for (var row : rows) {
        if (!identities.contains(row.identity()))
          throw new IllegalStateException("Classification identity mismatch");
        result.put(row.identity(), row);
      }
    }
    return Map.copyOf(result);
  }

  private Classification current(String tenant, Identity identity, boolean lock) {
    var rows =
        jdbc.query(
            "SELECT platform,profile,package_name,category,version,updated_at FROM"
                + " application_classifications WHERE tenant_id=? AND identity_hash=?"
                + (lock ? " FOR UPDATE" : ""),
            (row, index) -> {
              var actual =
                  new Identity(
                      Device.Platform.valueOf(row.getString(1)),
                      ApplicationDefinition.Profile.valueOf(row.getString(2)),
                      row.getString(3));
              if (!actual.equals(identity))
                throw new IllegalStateException("Classification identity mismatch");
              long version = row.getLong(5);
              return new Classification(
                  actual,
                  Category.valueOf(row.getString(4)),
                  version == 0 ? "NONE" : "ADMIN_DECLARED",
                  version,
                  row.getObject(6) == null ? null : row.getLong(6));
            },
            tenant,
            hash(identity));
    return rows.isEmpty() ? Classification.unclassified(identity) : rows.get(0);
  }

  private Identity identity(ApplicationDefinition app) {
    return new Identity(app.platform(), app.profile(), app.packageName());
  }

  private String hash(Identity identity) {
    return SecretMaterial.hash(
        identity.platform().name()
            + "|"
            + identity.profile().name()
            + "|"
            + identity.packageName());
  }
}

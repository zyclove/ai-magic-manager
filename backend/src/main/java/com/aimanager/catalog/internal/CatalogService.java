package com.aimanager.catalog.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.catalog.ApplicationIdentity;
import com.aimanager.fleet.Device;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.SecretMaterial;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.time.Clock;
import java.time.Instant;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Propagation;
import static com.aimanager.tenant.TenantAccess.Role.*;

@Service
class CatalogService implements ApplicationCatalog {
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final IdempotencyService idempotency;
    private final Clock clock;
    CatalogService(JdbcTemplate jdbc, TenantAccess access, ObjectMapper mapper, AuditService audit, IdempotencyService idempotency, Clock clock) {
        this.jdbc = jdbc; this.access = access; this.mapper = mapper; this.audit = audit; this.idempotency = idempotency;
        this.clock = clock;
    }

    @Transactional(timeout = 10)
    public ApplicationDefinition create(String tenant, String actor, CatalogController.CreateApplication input, String key) {
        access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
        if (input.signingDigests().stream().distinct().count() != input.signingDigests().size())
            throw DomainException.invalid("DUPLICATE_SIGNING_DIGEST");
        var digests = input.signingDigests().stream().sorted().toList();
        return idempotency.execute(tenant, actor, "application.create", key, Map.of("input", input), ApplicationDefinition.class, () -> {
            String identity = json(List.of(input.platform(), input.packageName(), input.profile(), digests));
            String id = UUID.randomUUID().toString();
            try {
                jdbc.update("INSERT INTO application_definitions(tenant_id,id,identity_hash,definition_json,created_at) VALUES(?,?,?,?,?)",
                    tenant, id, SecretMaterial.hash(identity), json(new ApplicationDefinition(id, input.displayName().strip(),
                        input.platform(), input.packageName(), input.profile(), digests, "ADMIN_DECLARED")), clock.millis());
            } catch (DuplicateKeyException duplicate) {
                throw new DomainException(HttpStatus.CONFLICT, "APPLICATION_IDENTITY_EXISTS");
            }
            audit.record(tenant, actor, "APPLICATION_DECLARED", id);
            return requireDeclared(tenant, actor, id);
        });
    }

    @Override public ApplicationDefinition requireDeclared(String tenant, String actor, String id) {
        access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
        return requireKnownIdentity(tenant,id);
    }
    @Transactional(timeout = 10)
    ApplicationDefinition creationResult(String tenant, String actor, String key, CatalogController.CreateApplication input) {
        access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
        if (key == null || !key.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
            throw DomainException.invalid("INVALID_CREATION_RESULT_REFERENCE");
        var result = idempotency.findCommitted(tenant, actor, "application.create", key,
            Map.of("input", input), ApplicationDefinition.class)
            .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "APPLICATION_CREATION_RESULT_UNAVAILABLE"));
        var current = requireDeclared(tenant, actor, result.id());
        var expected = new ApplicationDefinition(result.id(), input.displayName().strip(), input.platform(),
            input.packageName(), input.profile(), input.signingDigests().stream().sorted().toList(), "ADMIN_DECLARED");
        if (!current.equals(expected)) throw new IllegalStateException("Immutable application journal mismatch");
        return current;
    }
    @Override public ApplicationDefinition requireKnownIdentity(String tenant, String id) {
        var rows = jdbc.query("SELECT definition_json FROM application_definitions WHERE tenant_id=? AND id=?",
            (row, index) -> read(row.getString(1)), tenant, id);
        if (rows.isEmpty()) throw DomainException.denied();
        return rows.get(0);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public ApplicationIdentity requireEvidenceIdentity(String tenant, String actor, String id) {
        access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
        var rows = jdbc.query(
            "SELECT definition_json,identity_hash,created_at FROM application_definitions WHERE tenant_id=? AND id=?",
            (row, index) -> evidenceIdentity(id, row.getString(1), row.getString(2), row.getObject(3, Long.class)),
            tenant, id);
        if (rows.isEmpty()) throw DomainException.denied();
        return rows.get(0);
    }

    /** No raw record, parse exception or unsupported legacy timestamp escapes this boundary. */
    private ApplicationIdentity evidenceIdentity(String id, String raw, String revision, Long createdAt) {
        if (createdAt == null || createdAt < 0 || createdAt > clock.millis()
            || raw == null || raw.length() > 4096) throw unavailableIdentity();
        final ApplicationDefinition app;
        try { app = mapper.readValue(raw, ApplicationDefinition.class); }
        catch (JsonProcessingException malformed) { throw unavailableIdentity(); }
        if (app == null || !id.equals(app.id()) || app.platform() == null || app.profile() == null
            || app.packageName() == null || app.packageName().length() > 255
            || !app.packageName().matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")
            || app.signingDigests() == null || app.signingDigests().size() > 8
            || app.signingDigests().stream().anyMatch(digest -> digest == null || !digest.matches("[0-9a-f]{64}"))
            || app.signingDigests().stream().distinct().count() != app.signingDigests().size())
            throw unavailableIdentity();
        var digests = app.signingDigests().stream().sorted().toList();
        String actual = SecretMaterial.hash(json(List.of(app.platform(), app.packageName(), app.profile(), digests)));
        if (!actual.equals(revision)) throw unavailableIdentity();
        if (digests.isEmpty()) throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "APPLICATION_SIGNING_IDENTITY_REQUIRED");
        return new ApplicationIdentity(id, app.platform(), app.packageName(), app.profile(), digests,
            actual, Instant.ofEpochMilli(createdAt));
    }

    private DomainException unavailableIdentity() {
        return new DomainException(HttpStatus.CONFLICT, "APPLICATION_IDENTITY_METADATA_UNAVAILABLE");
    }

    ItemPage<ApplicationDefinition> list(String tenant, String actor, int limit, String cursor) {
        access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
        ItemPage.validate(limit, cursor);
        return ItemPage.from(jdbc.query("SELECT definition_json FROM application_definitions WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",
            (row, index) -> read(row.getString(1)), tenant, cursor == null ? "" : cursor, limit + 1), limit, ApplicationDefinition::id);
    }
    private ApplicationDefinition read(String json) {
        try { return mapper.readValue(json, ApplicationDefinition.class); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Application definition unreadable", failure); }
    }
    private String json(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Application serialization failed", failure); }
    }
}

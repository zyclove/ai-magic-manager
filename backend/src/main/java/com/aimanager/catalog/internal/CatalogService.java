package com.aimanager.catalog.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.ApplicationCatalog;
import com.aimanager.catalog.ApplicationDefinition;
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
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.tenant.TenantAccess.Role.*;

@Service
class CatalogService implements ApplicationCatalog {
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final IdempotencyService idempotency;
    CatalogService(JdbcTemplate jdbc, TenantAccess access, ObjectMapper mapper, AuditService audit, IdempotencyService idempotency) {
        this.jdbc = jdbc; this.access = access; this.mapper = mapper; this.audit = audit; this.idempotency = idempotency;
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
                jdbc.update("INSERT INTO application_definitions(tenant_id,id,identity_hash,definition_json) VALUES(?,?,?,?)",
                    tenant, id, SecretMaterial.hash(identity), json(new ApplicationDefinition(id, input.displayName().strip(),
                        input.platform(), input.packageName(), input.profile(), digests, "ADMIN_DECLARED")));
            } catch (DuplicateKeyException duplicate) {
                throw new DomainException(HttpStatus.CONFLICT, "APPLICATION_IDENTITY_EXISTS");
            }
            audit.record(tenant, actor, "APPLICATION_DECLARED", id);
            return requireDeclared(tenant, actor, id);
        });
    }

    @Override public ApplicationDefinition requireDeclared(String tenant, String actor, String id) {
        access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
        var rows = jdbc.query("SELECT definition_json FROM application_definitions WHERE tenant_id=? AND id=?",
            (row, index) -> read(row.getString(1)), tenant, id);
        if (rows.isEmpty()) throw DomainException.denied();
        return rows.get(0);
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

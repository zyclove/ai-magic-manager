package com.aimanager.tenant.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.tenant.Tenant;
import java.time.Clock;
import java.time.DateTimeException;
import java.time.ZoneId;
import java.util.UUID;
import java.util.Map;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class TenantService {
    private final JdbcTemplate jdbc;
    private final AuditService audit;
    private final Clock clock;
    private final IdempotencyService idempotency;
    private final com.aimanager.identity.IdentityProfiles profiles;
    TenantService(JdbcTemplate jdbc, AuditService audit, Clock clock, IdempotencyService idempotency, com.aimanager.identity.IdentityProfiles profiles) {
        this.jdbc = jdbc; this.audit = audit; this.clock = clock; this.idempotency = idempotency;
        this.profiles = profiles;
    }

    @Transactional(timeout = 10)
    public Tenant create(org.springframework.security.oauth2.jwt.Jwt identity, String name, Tenant.Kind kind, String timeZone, String key) {
        String actor = identity.getSubject();
        profiles.observe(identity);
        try { ZoneId.of(timeZone); } catch (DateTimeException failure) { throw DomainException.invalid("INVALID_TIME_ZONE"); }
        return idempotency.execute("bootstrap", actor, "tenant.create", key,
            Map.of("name", name, "kind", kind, "timeZone", timeZone), Tenant.class,
            () -> insert(actor, name, kind, timeZone));
    }

    private Tenant insert(String actor, String name, Tenant.Kind kind, String timeZone) {
        var tenant = new Tenant(UUID.randomUUID().toString(), name.strip(), kind, timeZone, 0);
        jdbc.update("INSERT INTO tenants(id,name,kind,time_zone,created_at,version) VALUES(?,?,?,?,?,?)",
            tenant.id(), tenant.name(), kind.name(), timeZone, clock.millis(), 0);
        jdbc.update("INSERT INTO ownership_heads(tenant_id) VALUES(?)", tenant.id());
        jdbc.update("INSERT INTO tenant_members(tenant_id,actor_id,actor_key,role) VALUES(?,?,?,?)", tenant.id(), actor, ActorKeys.key(actor), "OWNER");
        audit.record(tenant.id(), actor, "TENANT_CREATED", tenant.id());
        return tenant;
    }

    public ItemPage<Tenant> list(String actor, int limit, String cursor) {
        ItemPage.validate(limit, cursor);
        var rows = jdbc.query("SELECT t.* FROM tenants t JOIN tenant_members m ON m.tenant_id=t.id "
                + "WHERE m.actor_key=? AND m.revoked_at IS NULL AND t.id>? ORDER BY t.id LIMIT ?",
            (row, index) -> new Tenant(row.getString("id"), row.getString("name"), Tenant.Kind.valueOf(row.getString("kind")),
                row.getString("time_zone"), row.getLong("version")), ActorKeys.key(actor), cursor == null ? "" : cursor, limit + 1);
        return ItemPage.from(rows, limit, Tenant::id);
    }
}

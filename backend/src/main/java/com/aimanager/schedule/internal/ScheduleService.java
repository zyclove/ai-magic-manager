package com.aimanager.schedule.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.schedule.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.tenant.TenantAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.tenant.TenantAccess.Role.*;

@Service
class ScheduleService implements ScheduleCatalog {
    private final JdbcTemplate jdbc;
    private final TenantAccess access;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final IdempotencyService idempotency;
    ScheduleService(JdbcTemplate jdbc, TenantAccess access, ObjectMapper mapper, AuditService audit, IdempotencyService idempotency) {
        this.jdbc = jdbc; this.access = access; this.mapper = mapper; this.audit = audit; this.idempotency = idempotency;
    }
    @Transactional(timeout = 10)
    public ScheduleEntry create(String tenant, String actor, ScheduleController.CreateSchedule input, String key) {
        access.requireWriteRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN);
        ScheduleEngine.validate(input.definition());
        return idempotency.execute(tenant, actor, "schedule.create", key, Map.of("input", input), ScheduleEntry.class, () -> {
            var entry = new ScheduleEntry(UUID.randomUUID().toString(), input.name().strip(), input.definition());
            jdbc.update("INSERT INTO schedule_definitions(tenant_id,id,definition_json) VALUES(?,?,?)", tenant, entry.id(), json(entry));
            audit.record(tenant, actor, "SCHEDULE_CREATED", entry.id());
            return entry;
        });
    }
    @Override public ScheduleEntry requireDefinition(String tenant, String actor, String id) {
        access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
        var rows = jdbc.query("SELECT definition_json FROM schedule_definitions WHERE tenant_id=? AND id=?", (row, index) -> read(row.getString(1)), tenant, id);
        if (rows.isEmpty()) throw DomainException.denied();
        return rows.get(0);
    }
    ItemPage<ScheduleEntry> list(String tenant, String actor, int limit, String cursor) {
        access.requireRole(tenant, actor, OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
        ItemPage.validate(limit, cursor);
        return ItemPage.from(jdbc.query("SELECT definition_json FROM schedule_definitions WHERE tenant_id=? AND id>? ORDER BY id LIMIT ?",
            (row, index) -> read(row.getString(1)), tenant, cursor == null ? "" : cursor, limit + 1), limit, ScheduleEntry::id);
    }
    private ScheduleEntry read(String value) {
        try { return mapper.readValue(value, ScheduleEntry.class); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Schedule unreadable", failure); }
    }
    private String json(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Schedule serialization failed", failure); }
    }
}

package com.aimanager.catalog.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.catalog.*;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class InventoryService {
    private final JdbcTemplate jdbc;
    private final DeviceAccess devices;
    private final DeviceCredentials credentials;
    private final ObjectMapper mapper;
    private final Clock clock;
    private final AuditService audit;
    private final long maxAgeMillis;
    InventoryService(JdbcTemplate jdbc, DeviceAccess devices, DeviceCredentials credentials, ObjectMapper mapper, Clock clock,
                     AuditService audit, @Value("${manager.catalog.inventory-max-age-seconds:900}") long maxAge) {
        if (maxAge < 30 || maxAge > 86400) throw new IllegalArgumentException("Invalid inventory lifetime");
        this.jdbc = jdbc; this.devices = devices; this.credentials = credentials; this.mapper = mapper;
        this.clock = clock; this.audit = audit; this.maxAgeMillis = maxAge * 1000;
    }
    @Transactional(timeout = 10)
    public Accepted report(DeviceContext identity, InventoryController.InventoryReport input) {
        // Match fleet's device -> credential lock order; credential revocation is rechecked inside this transaction.
        devices.lockActive(identity); credentials.requireActive(identity);
        var normalizedApps = new ArrayList<ReportedApplication>();
        var identities = new HashSet<String>();
        for (var app : input.applications()) {
            if (!identities.add(app.packageName() + "|" + app.profile())) throw DomainException.invalid("DUPLICATE_APPLICATION_INSTANCE");
            if (app.signingDigests().stream().distinct().count() != app.signingDigests().size()) throw DomainException.invalid("DUPLICATE_SIGNING_DIGEST");
            normalizedApps.add(new ReportedApplication(app.packageName(), app.displayName().strip(), app.profile(),
                app.signingDigests().stream().sorted().toList(), app.versionCode(), app.systemApplication()));
        }
        normalizedApps.sort(Comparator.comparing(ReportedApplication::packageName).thenComparing(a -> a.profile().name()));
        var normalized = new InventoryController.InventoryReport(input.sequence(), input.visibility(), List.copyOf(normalizedApps));
        String encoded = json(normalized), hash = SecretMaterial.hash(encoded);
        var rows = jdbc.query("SELECT sequence_number,request_hash,received_at FROM application_inventory_snapshots "
                + "WHERE tenant_id=? AND device_id=? AND registration_id=? FOR UPDATE",
            (row, index) -> new Head(row.getLong(1), row.getString(2), row.getLong(3)), identity.tenantId(), identity.deviceId(), identity.registrationId());
        if (!rows.isEmpty()) {
            var previous = rows.get(0);
            if (input.sequence() == previous.sequence()) {
                if (!hash.equals(previous.hash())) throw new DomainException(HttpStatus.CONFLICT, "INVENTORY_SEQUENCE_CONFLICT");
                return new Accepted(identity.registrationId(), previous.sequence(), previous.receivedAt());
            }
            if (input.sequence() < previous.sequence()) throw new DomainException(HttpStatus.CONFLICT, "INVENTORY_STALE_SEQUENCE");
        }
        long now = clock.millis();
        if (rows.isEmpty()) {
            jdbc.update("INSERT INTO application_inventory_snapshots(tenant_id,device_id,registration_id,sequence_number,request_hash,snapshot_json,received_at) VALUES(?,?,?,?,?,?,?)",
                identity.tenantId(), identity.deviceId(), identity.registrationId(), input.sequence(), hash, encoded, now);
        } else {
            jdbc.update("UPDATE application_inventory_snapshots SET sequence_number=?,request_hash=?,snapshot_json=?,received_at=? WHERE tenant_id=? AND device_id=? AND registration_id=?",
                input.sequence(), hash, encoded, now, identity.tenantId(), identity.deviceId(), identity.registrationId());
        }
        audit.record(identity.tenantId(), "device:" + identity.registrationId(), "APPLICATION_INVENTORY_REPORTED", identity.deviceId());
        return new Accepted(identity.registrationId(), input.sequence(), now);
    }
    ApplicationInventory read(String tenant, String actor, String deviceId) {
        var device = devices.requireVisible(tenant, actor, deviceId);
        var rows = jdbc.query("SELECT snapshot_json,received_at FROM application_inventory_snapshots WHERE tenant_id=? AND device_id=? AND registration_id=?",
            (row, index) -> new Stored(parse(row.getString(1)), row.getLong(2)), tenant, deviceId, device.registrationId());
        if (rows.isEmpty()) return new ApplicationInventory(deviceId, device.registrationId(), 0, null, "UNKNOWN",
            device.state() == Device.State.REVOKED ? "REVOKED" : "UNKNOWN", "AGENT_REPORTED_UNVERIFIED", List.of());
        var entry = rows.get(0); String state = device.state() == Device.State.REVOKED ? "REVOKED"
            : clock.millis() - entry.receivedAt() > maxAgeMillis ? "STALE" : "RECENT";
        return new ApplicationInventory(deviceId, device.registrationId(), entry.report().sequence(), entry.receivedAt(),
            entry.report().visibility().name(), state, "AGENT_REPORTED_UNVERIFIED", entry.report().applications());
    }
    private String json(Object value) {
        try { return mapper.writeValueAsString(value); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Inventory serialization failed", failure); }
    }
    private InventoryController.InventoryReport parse(String value) {
        try { return mapper.readValue(value, InventoryController.InventoryReport.class); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Inventory snapshot unreadable", failure); }
    }
    record Accepted(String registrationId, long sequence, long receivedAt) {}
    private record Head(long sequence, String hash, long receivedAt) {}
    private record Stored(InventoryController.InventoryReport report, long receivedAt) {}
}

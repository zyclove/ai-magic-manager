package com.aimanager.fleet.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.SecretMaterial;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.util.Comparator;
import java.util.HashSet;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
class HeartbeatService {
    private final JdbcTemplate jdbc;
    private final DeviceCredentials credentials;
    private final Clock clock;
    private final ObjectMapper mapper;
    HeartbeatService(JdbcTemplate jdbc, DeviceCredentials credentials, Clock clock, ObjectMapper mapper) {
        this.jdbc = jdbc; this.credentials = credentials; this.clock = clock; this.mapper = mapper;
    }

    /** Sequence is persisted across reboots by the agent; replay must not make old evidence look fresh. */
    @Transactional(timeout = 10)
    public Accepted accept(DeviceContext identity, DeviceController.Heartbeat input) {
        var rows = jdbc.queryForList("SELECT state,heartbeat_sequence,heartbeat_hash,last_heartbeat_at FROM devices "
            + "WHERE tenant_id=? AND id=? AND registration_id=? FOR UPDATE", identity.tenantId(), identity.deviceId(), identity.registrationId());
        if (rows.size() != 1 || !"ACTIVE".equals(rows.get(0).get("state"))) throw DomainException.denied();
        credentials.requireActive(identity);
        var keys = new HashSet<String>();
        for (var observation : input.capabilities()) if (!keys.add(observation.key())) throw DomainException.invalid("DUPLICATE_CAPABILITY");
        var normalized = new DeviceController.Heartbeat(input.sequence(), input.agentVersion(), input.capabilities().stream()
            .sorted(Comparator.comparing(DeviceController.CapabilityReport::key)).toList());
        String hash;
        try { hash = SecretMaterial.hash(mapper.writeValueAsString(normalized)); }
        catch (JsonProcessingException failure) { throw new IllegalStateException("Heartbeat fingerprint failed", failure); }
        long previous = ((Number) rows.get(0).get("heartbeat_sequence")).longValue();
        if (input.sequence() == previous) {
            if (!hash.equals(rows.get(0).get("heartbeat_hash"))) throw new DomainException(HttpStatus.CONFLICT, "HEARTBEAT_SEQUENCE_CONFLICT");
            return new Accepted(identity.registrationId(), previous, ((Number) rows.get(0).get("last_heartbeat_at")).longValue());
        }
        if (input.sequence() < previous) throw new DomainException(HttpStatus.CONFLICT, "HEARTBEAT_STALE_SEQUENCE");
        long now = clock.millis();
        jdbc.update("UPDATE devices SET last_heartbeat_at=?,heartbeat_sequence=?,heartbeat_hash=?,agent_version=? WHERE tenant_id=? AND id=?",
            now, input.sequence(), hash, input.agentVersion(), identity.tenantId(), identity.deviceId());
        // This payload is a full snapshot. Missing/withdrawn grants replace the previous observation atomically.
        jdbc.update("DELETE FROM device_capabilities WHERE tenant_id=? AND device_id=?", identity.tenantId(), identity.deviceId());
        jdbc.batchUpdate("INSERT INTO device_capabilities(tenant_id,device_id,capability_key,reported_supported,grant_status,checked_at) VALUES(?,?,?,?,?,?)",
            normalized.capabilities(), 64, (statement, report) -> {
                statement.setString(1, identity.tenantId()); statement.setString(2, identity.deviceId());
                statement.setString(3, report.key()); statement.setBoolean(4, report.reportedSupported());
                statement.setString(5, report.grantStatus().name()); statement.setLong(6, now);
            });
        return new Accepted(identity.registrationId(), input.sequence(), now);
    }

    record Accepted(String registrationId, long sequence, long receivedAt) {}
}

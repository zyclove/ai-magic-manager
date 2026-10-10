package com.aimanager.observation.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.deviceidentity.DeviceCredentials;
import com.aimanager.fleet.Device;
import com.aimanager.fleet.DeviceAccess;
import com.aimanager.fleet.DeviceRegistrationRevoked;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.observation.*;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.TenantAccess;
import java.time.Clock;
import java.util.Map;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.context.event.EventListener;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import static com.aimanager.tenant.TenantAccess.Role.*;

@Service
class ObservationSettingsService implements ObservationAuthorization {
    private static final long MAX_SAFE_VERSION = 9007199254740991L;
    private final JdbcTemplate jdbc;
    private final DeviceAccess devices;
    private final DeviceCredentials credentials;
    private final TenantAccess access;
    private final RecentAuthentication recent;
    private final IdempotencyService idempotency;
    private final AuditService audit;
    private final Clock clock;
    private final ApplicationEventPublisher events;

    ObservationSettingsService(JdbcTemplate jdbc, DeviceAccess devices, DeviceCredentials credentials,
            TenantAccess access, RecentAuthentication recent, IdempotencyService idempotency,
            AuditService audit, Clock clock, ApplicationEventPublisher events) {
        this.jdbc = jdbc; this.devices = devices; this.credentials = credentials;
        this.access = access; this.recent = recent; this.idempotency = idempotency;
        this.audit = audit; this.clock = clock; this.events = events;
    }

    ObservationSettings read(String tenant, String actor, String deviceId) {
        var device = devices.requireVisible(tenant, actor, deviceId);
        return current(tenant, deviceId, device.registrationId(), false);
    }

    @Transactional(timeout = 10)
    public ObservationSettings device(DeviceContext identity) {
        devices.lockActive(identity);
        credentials.requireActive(identity);
        return current(identity.tenantId(), identity.deviceId(), identity.registrationId(), true);
    }

    @Transactional(timeout = 10)
    public ObservationSettings update(String tenant, Jwt actor, String deviceId, long expected,
            String key, ObservationController.Update input) {
        access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
        recent.require(actor);
        var device = devices.lockVisibleActive(tenant, actor.getSubject(), deviceId);
        return idempotency.execute(tenant, actor.getSubject(), "observation.update", key,
            Map.of("deviceId", deviceId, "expectedVersion", expected, "input", input),
            ObservationSettings.class, () -> change(tenant, actor.getSubject(), device, expected, input));
    }

    private ObservationSettings change(String tenant, String actor, Device device, long expected,
            ObservationController.Update input) {
        var before = current(tenant, device.id(), device.registrationId(), true);
        ResourceVersions.check(expected, before.version());
        if (before.version() >= MAX_SAFE_VERSION) throw DomainException.invalid("VERSION_EXHAUSTED");
        long version = before.version() + 1, now = clock.millis();
        if (before.version() == 0) {
            jdbc.update("INSERT INTO device_observation_settings(tenant_id,device_id,registration_id,version,"
                + "inventory_enabled,usage_enabled,updated_at,last_reason) VALUES(?,?,?,?,?,?,?,?)",
                tenant, device.id(), device.registrationId(), version, input.inventoryEnabled(),
                input.usageEnabled(), now, input.reason().strip());
        } else {
            jdbc.update("UPDATE device_observation_settings SET version=?,inventory_enabled=?,usage_enabled=?,"
                + "updated_at=?,last_reason=? WHERE tenant_id=? AND device_id=? AND registration_id=?",
                version, input.inventoryEnabled(), input.usageEnabled(), now, input.reason().strip(),
                tenant, device.id(), device.registrationId());
        }
        events.publishEvent(new ObservationAuthorizationChanged(tenant, device.id(), device.registrationId(),
            input.inventoryEnabled(), input.usageEnabled()));
        audit.record(tenant, actor, "DEVICE_OBSERVATION_AUTHORIZATION_CHANGED", device.id());
        return new ObservationSettings(device.id(), device.registrationId(), version,
            input.inventoryEnabled(), input.usageEnabled(), now);
    }

    ObservationSettings current(String tenant, String device, String registration, boolean lock) {
        var rows = jdbc.query("SELECT version,inventory_enabled,usage_enabled,updated_at FROM device_observation_settings "
                + "WHERE tenant_id=? AND device_id=? AND registration_id=?" + (lock ? " FOR UPDATE" : ""),
            (row, index) -> new ObservationSettings(device, registration, row.getLong(1),
                row.getBoolean(2), row.getBoolean(3), row.getLong(4)), tenant, device, registration);
        return rows.isEmpty() ? new ObservationSettings(device, registration, 0, false, false, null) : rows.get(0);
    }

    @Override
    public boolean inventoryEnabled(String tenant, String device, String registration) {
        return current(tenant, device, registration, false).inventoryEnabled();
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireInventory(DeviceContext identity, long authorizationVersion) {
        require(identity, authorizationVersion, true);
    }

    void requireUsage(DeviceContext identity, long authorizationVersion) {
        require(identity, authorizationVersion, false);
    }

    private void require(DeviceContext identity, long version, boolean inventory) {
        var value = current(identity.tenantId(), identity.deviceId(), identity.registrationId(), true);
        if (!(inventory ? value.inventoryEnabled() : value.usageEnabled())) {
            throw new DomainException(HttpStatus.FORBIDDEN, "OBSERVATION_NOT_AUTHORIZED");
        }
        if (value.version() != version) {
            throw new DomainException(HttpStatus.CONFLICT, "OBSERVATION_AUTHORIZATION_CHANGED");
        }
    }

    @EventListener
    @Transactional(propagation = Propagation.MANDATORY)
    public void revoked(DeviceRegistrationRevoked event) {
        jdbc.update("DELETE FROM device_observation_settings WHERE tenant_id=? AND device_id=? AND registration_id=?",
            event.tenantId(), event.deviceId(), event.registrationId());
        events.publishEvent(new ObservationAuthorizationChanged(event.tenantId(), event.deviceId(),
            event.registrationId(), false, false));
    }
}

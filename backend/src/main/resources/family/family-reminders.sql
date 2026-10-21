-- Current device attention episodes, separate from opaque lock-screen events.
CREATE TABLE family_notification_device_states (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    was_healthy BOOLEAN NOT NULL DEFAULT FALSE,
    condition_code VARCHAR(40) NULL,
    condition_anchor BIGINT NULL,
    episode BIGINT NOT NULL DEFAULT 0,
    event_id VARCHAR(36) NULL,
    updated_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,device_id),
    CONSTRAINT fk_family_notice_device FOREIGN KEY(tenant_id,device_id) REFERENCES devices(tenant_id,id)
);
CREATE INDEX ix_family_notice_device_event ON family_notification_device_states(tenant_id,event_id);

CREATE TABLE family_notification_subscription_states (
    tenant_id VARCHAR(36) NOT NULL,
    boundary_key VARCHAR(64) NOT NULL,
    event_kind VARCHAR(40) NOT NULL,
    period_end BIGINT NOT NULL,
    trigger_at BIGINT NOT NULL,
    event_id VARCHAR(36) NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,boundary_key),
    CONSTRAINT uq_family_notice_subscription_event UNIQUE(tenant_id,event_id),
    CONSTRAINT fk_family_notice_subscription_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

CREATE TABLE family_notification_scan_cursors (
    scope_key VARCHAR(20) NOT NULL PRIMARY KEY,
    last_tenant_id VARCHAR(36) NOT NULL,
    last_entity_id VARCHAR(36) NOT NULL,
    updated_at BIGINT NOT NULL
);

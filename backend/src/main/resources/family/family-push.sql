-- FAMILY adult push: tokens never enter the immutable event or delivery attempt records.
CREATE TABLE family_push_installations (
    installation_id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    provider VARCHAR(20) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    provider_token VARCHAR(256) NULL,
    token_hash VARCHAR(64) NULL,
    notification_consent BOOLEAN NOT NULL,
    permission_granted BOOLEAN NOT NULL,
    member_version BIGINT NOT NULL,
    version BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    revoked_at BIGINT NULL,
    CONSTRAINT uq_family_push_token UNIQUE(token_hash),
    CONSTRAINT fk_family_push_member FOREIGN KEY(tenant_id,actor_key) REFERENCES tenant_members(tenant_id,actor_key)
);
CREATE INDEX ix_family_push_recipient ON family_push_installations(tenant_id,actor_key,revoked_at);

CREATE TABLE family_notification_preferences (
    tenant_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    requests_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    device_attention_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    rule_expiry_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,actor_key),
    CONSTRAINT fk_family_push_preference_member FOREIGN KEY(tenant_id,actor_key) REFERENCES tenant_members(tenant_id,actor_key)
);

CREATE TABLE family_push_events (
    tenant_id VARCHAR(36) NOT NULL,
    event_id VARCHAR(36) NOT NULL,
    kind VARCHAR(40) NOT NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,event_id),
    CONSTRAINT fk_family_push_event_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

CREATE TABLE family_push_outbox (
    delivery_id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    event_id VARCHAR(36) NOT NULL,
    installation_id VARCHAR(36) NOT NULL,
    installation_version BIGINT NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    state VARCHAR(20) NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at BIGINT NOT NULL,
    lease_id VARCHAR(36) NULL,
    lease_until BIGINT NULL,
    provider_message_id VARCHAR(128) NULL,
    last_error VARCHAR(60) NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT uq_family_push_event_installation UNIQUE(tenant_id,event_id,installation_id),
    CONSTRAINT fk_family_push_outbox_event FOREIGN KEY(tenant_id,event_id) REFERENCES family_push_events(tenant_id,event_id),
    CONSTRAINT fk_family_push_outbox_installation FOREIGN KEY(installation_id) REFERENCES family_push_installations(installation_id)
);
CREATE INDEX ix_family_push_dispatch ON family_push_outbox(state,next_attempt_at,lease_until,delivery_id);

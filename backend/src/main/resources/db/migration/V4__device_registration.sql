CREATE TABLE device_enrollments (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    creator_actor_id VARCHAR(255) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    requested_mode VARCHAR(30) NOT NULL,
    token_hash VARCHAR(64) NOT NULL,
    state VARCHAR(30) NOT NULL,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    device_id VARCHAR(36) NULL,
    pairing_hash VARCHAR(64) NULL,
    pairing_failures INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id,id),
    CONSTRAINT uq_enrollment_id UNIQUE(id),
    CONSTRAINT uq_enrollment_token UNIQUE(token_hash),
    CONSTRAINT fk_enrollment_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);
CREATE INDEX ix_enrollment_expiry ON device_enrollments(state,expires_at);

-- One immutable registration cycle per logical device row. Re-enrollment creates a new cycle.
CREATE TABLE devices (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    display_name VARCHAR(100) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    os_version VARCHAR(100) NOT NULL,
    state VARCHAR(30) NOT NULL,
    public_key_jwk TEXT NOT NULL,
    key_thumbprint VARCHAR(64) NOT NULL,
    created_at BIGINT NOT NULL,
    last_heartbeat_at BIGINT NULL,
    heartbeat_sequence BIGINT NOT NULL DEFAULT 0,
    heartbeat_hash VARCHAR(64) NULL,
    agent_version VARCHAR(60) NULL,
    version BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_device_registration UNIQUE(tenant_id,id,registration_id),
    CONSTRAINT fk_device_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);
CREATE INDEX ix_device_subject ON devices(tenant_id,subject_id,id);

ALTER TABLE device_enrollments ADD CONSTRAINT fk_enrollment_device
    FOREIGN KEY(tenant_id,device_id) REFERENCES devices(tenant_id,id);

CREATE TABLE device_credentials (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    token_hash VARCHAR(64) NOT NULL,
    active BOOLEAN NOT NULL,
    issued_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    revoked_at BIGINT NULL,
    CONSTRAINT uq_device_token UNIQUE(token_hash),
    CONSTRAINT fk_credential_registration FOREIGN KEY(tenant_id,device_id,registration_id)
        REFERENCES devices(tenant_id,id,registration_id)
);
CREATE INDEX ix_credential_registration ON device_credentials(tenant_id,registration_id,active);

CREATE TABLE device_capabilities (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    capability_key VARCHAR(64) NOT NULL,
    reported_supported BOOLEAN NOT NULL,
    grant_status VARCHAR(30) NOT NULL,
    checked_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,device_id,capability_key),
    CONSTRAINT fk_capability_device FOREIGN KEY(tenant_id,device_id) REFERENCES devices(tenant_id,id)
);

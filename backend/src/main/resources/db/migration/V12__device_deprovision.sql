-- Independent cleanup namespace remains available after ordinary device credentials are revoked.
CREATE TABLE deprovision_previews (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    device_version BIGINT NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    preview_hash VARCHAR(64) NOT NULL,
    expires_at BIGINT NOT NULL,
    operation_id VARCHAR(36) NULL,
    PRIMARY KEY(tenant_id,id)
);
CREATE INDEX ix_deprovision_preview_expiry ON deprovision_previews(expires_at);
CREATE TABLE deprovision_operations (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    command_id VARCHAR(36) NOT NULL,
    key_thumbprint VARCHAR(64) NOT NULL,
    compact_jws TEXT NOT NULL,
    command_hash VARCHAR(64) NOT NULL,
    state VARCHAR(40) NOT NULL,
    local_evidence VARCHAR(40) NOT NULL,
    reason_code VARCHAR(60) NULL,
    issued_at BIGINT NOT NULL,
    absolute_not_after BIGINT NOT NULL,
    served_at BIGINT NULL,
    updated_at BIGINT NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_cleanup_command UNIQUE(tenant_id,command_id)
);
CREATE INDEX ix_deprovision_device ON deprovision_operations(tenant_id,device_id,id);
CREATE INDEX ix_deprovision_expiry ON deprovision_operations(state,absolute_not_after);
CREATE TABLE deprovision_heads (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    operation_id VARCHAR(36) NULL,
    PRIMARY KEY(tenant_id,device_id,registration_id)
);
CREATE TABLE cleanup_receipts (
    tenant_id VARCHAR(36) NOT NULL,
    operation_id VARCHAR(36) NOT NULL,
    receipt_id VARCHAR(36) NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    stage VARCHAR(30) NOT NULL,
    received_at BIGINT NOT NULL,
    response_json TEXT NOT NULL,
    PRIMARY KEY(tenant_id,operation_id,receipt_id),
    CONSTRAINT fk_cleanup_receipt FOREIGN KEY(tenant_id,operation_id) REFERENCES deprovision_operations(tenant_id,id)
);

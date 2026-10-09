-- These are delivery-owned aggregates. Lifecycle authorization always uses Fleet/DeviceCredentials.
CREATE TABLE configuration_device_heads (
    tenant_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    next_cursor BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,registration_id),
    CONSTRAINT fk_configuration_head_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);
CREATE TABLE configuration_deliveries (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    publication_id VARCHAR(36) NOT NULL,
    version_id VARCHAR(36) NOT NULL,
    policy_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    source_sequence BIGINT NOT NULL,
    device_cursor BIGINT NOT NULL,
    action VARCHAR(32) NOT NULL,
    document_json MEDIUMTEXT NULL,
    issued_at BIGINT NOT NULL,
    delivery_expires_at BIGINT NOT NULL,
    state VARCHAR(40) NOT NULL,
    compact_jws MEDIUMTEXT NULL,
    envelope_hash VARCHAR(64) NULL,
    signing_key_id VARCHAR(64) NULL,
    first_served_at BIGINT NULL,
    received_reported_at BIGINT NULL,
    stored_reported_at BIGINT NULL,
    rejection_code VARCHAR(50) NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_configuration_delivery_head FOREIGN KEY(tenant_id,registration_id) REFERENCES configuration_device_heads(tenant_id,registration_id),
    CONSTRAINT fk_configuration_delivery_version FOREIGN KEY(tenant_id,version_id) REFERENCES policy_versions(tenant_id,id),
    CONSTRAINT fk_configuration_delivery_publication FOREIGN KEY(tenant_id,publication_id) REFERENCES policy_publications(tenant_id,id)
);
CREATE INDEX ix_configuration_publication ON configuration_deliveries(tenant_id,publication_id,id);
CREATE TABLE configuration_streams (
    tenant_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    policy_id VARCHAR(36) NOT NULL,
    delivery_id VARCHAR(36) NOT NULL,
    PRIMARY KEY(tenant_id,registration_id,policy_id),
    CONSTRAINT fk_configuration_stream_head FOREIGN KEY(tenant_id,registration_id) REFERENCES configuration_device_heads(tenant_id,registration_id),
    CONSTRAINT fk_configuration_stream_delivery FOREIGN KEY(tenant_id,delivery_id) REFERENCES configuration_deliveries(tenant_id,id)
);
CREATE TABLE configuration_receipts (
    tenant_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    delivery_id VARCHAR(36) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    response_json TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,registration_id,id),
    CONSTRAINT fk_configuration_receipt_head FOREIGN KEY(tenant_id,registration_id) REFERENCES configuration_device_heads(tenant_id,registration_id),
    CONSTRAINT fk_configuration_receipt_delivery FOREIGN KEY(tenant_id,delivery_id) REFERENCES configuration_deliveries(tenant_id,id)
);

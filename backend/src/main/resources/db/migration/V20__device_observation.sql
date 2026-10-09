-- Registration-bound, separately authorized observations. No enforcement or quota charge is implied.
CREATE TABLE device_observation_settings (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    version BIGINT NOT NULL,
    inventory_enabled BOOLEAN NOT NULL,
    usage_enabled BOOLEAN NOT NULL,
    updated_at BIGINT NOT NULL,
    last_reason VARCHAR(300) NOT NULL,
    PRIMARY KEY (tenant_id, device_id),
    CONSTRAINT fk_observation_settings_device FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);

CREATE TABLE usage_observation_heads (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    sequence_number BIGINT NOT NULL,
    report_id VARCHAR(36) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, device_id),
    CONSTRAINT fk_usage_head_device FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);

CREATE TABLE usage_observation_batches (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    sequence_number BIGINT NOT NULL,
    report_id VARCHAR(36) NOT NULL,
    authorization_version BIGINT NOT NULL,
    payload_json MEDIUMTEXT NOT NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, device_id, sequence_number),
    CONSTRAINT uq_usage_report UNIQUE (tenant_id, device_id, report_id),
    CONSTRAINT fk_usage_batch_device FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);
CREATE INDEX ix_usage_observation_retention ON usage_observation_batches(received_at);

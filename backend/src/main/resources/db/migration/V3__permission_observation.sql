CREATE TABLE device_permission_observation_settings (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    version BIGINT NOT NULL,
    enabled BOOLEAN NOT NULL,
    updated_at BIGINT NOT NULL,
    last_reason VARCHAR(300) NOT NULL,
    PRIMARY KEY (tenant_id, device_id),
    CONSTRAINT fk_permission_observation_settings_device
        FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);

-- One on-demand application snapshot per registered device. Sequence rejects old replays.
CREATE TABLE device_permission_observation_snapshots (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    sequence_number BIGINT NOT NULL,
    report_id VARCHAR(36) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    authorization_version BIGINT NOT NULL,
    package_name VARCHAR(255) NOT NULL,
    profile VARCHAR(16) NOT NULL,
    snapshot_json TEXT NOT NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, device_id),
    CONSTRAINT fk_permission_observation_snapshot_device
        FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);
CREATE INDEX ix_permission_observation_retention
    ON device_permission_observation_snapshots(received_at);

CREATE TABLE device_permission_observation_rate (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    window_started_at BIGINT NOT NULL,
    report_count INTEGER NOT NULL,
    PRIMARY KEY (tenant_id, device_id),
    CONSTRAINT fk_permission_observation_rate_device
        FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);
CREATE INDEX ix_permission_observation_rate_retention
    ON device_permission_observation_rate(window_started_at);

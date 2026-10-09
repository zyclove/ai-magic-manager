-- Credential-bound agent observation, not a claim that Android package visibility covers all installed apps.
CREATE TABLE application_inventory_snapshots (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    sequence_number BIGINT NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    snapshot_json MEDIUMTEXT NOT NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,device_id),
    CONSTRAINT fk_inventory_registration FOREIGN KEY(tenant_id,device_id,registration_id)
        REFERENCES devices(tenant_id,id,registration_id)
);

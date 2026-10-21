-- Fresh baseline fragment, not a development database upgrade migration.
CREATE TABLE IF NOT EXISTS family_device_access_accounts (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    version BIGINT NOT NULL DEFAULT 0,
    projection_hash VARCHAR(64) NULL,
    selected_device_id VARCHAR(36) NULL,
    selected_registration_id VARCHAR(36) NULL,
    selection_anchor BIGINT NULL,
    CONSTRAINT fk_family_device_access_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

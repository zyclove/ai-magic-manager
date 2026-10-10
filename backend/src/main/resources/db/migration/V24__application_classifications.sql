-- Reporting labels only. These rows neither verify signing identity nor change enforcement.
-- The digest preserves case-sensitive package identity on all supported database collations.
CREATE TABLE application_classifications (
    tenant_id VARCHAR(36) NOT NULL,
    identity_hash VARCHAR(64) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    profile VARCHAR(20) NOT NULL,
    package_name VARCHAR(255) NOT NULL,
    category VARCHAR(24) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NULL,
    PRIMARY KEY(tenant_id,identity_hash),
    CONSTRAINT fk_application_classification_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

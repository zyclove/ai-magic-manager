-- A proposal never grants device-management capability. Approval needs a live provider read.
CREATE TABLE managed_enterprise_bindings (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    provider VARCHAR(32) NOT NULL,
    enterprise_id VARCHAR(128) NOT NULL,
    contract_reference VARCHAR(200) NOT NULL,
    state VARCHAR(16) NOT NULL,
    version BIGINT NOT NULL,
    requested_by VARCHAR(255) NOT NULL,
    approved_by VARCHAR(255),
    provider_display_name VARCHAR(255),
    ownership_evidence_ref VARCHAR(200),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT uq_managed_enterprise_resource UNIQUE(provider, enterprise_id),
    CONSTRAINT fk_managed_enterprise_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id),
    CONSTRAINT ck_managed_enterprise_state CHECK(state IN ('PENDING','ACTIVE','REVOKED'))
);
CREATE INDEX ix_managed_enterprise_queue ON managed_enterprise_bindings(state, tenant_id);

CREATE TABLE managed_enterprise_binding_events (
    tenant_id VARCHAR(36) NOT NULL,
    version BIGINT NOT NULL,
    id VARCHAR(36) NOT NULL,
    action VARCHAR(24) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    reason VARCHAR(500),
    correlation_id VARCHAR(36) NOT NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id, version),
    CONSTRAINT uq_managed_enterprise_event UNIQUE(id),
    CONSTRAINT fk_managed_enterprise_event FOREIGN KEY(tenant_id)
      REFERENCES managed_enterprise_bindings(tenant_id)
);

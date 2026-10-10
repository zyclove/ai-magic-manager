-- Commercial facts are tenant scoped and source versioned. No payment data or secrets are stored.
CREATE TABLE commercial_accounts (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    version BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT fk_commercial_account_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE TABLE commercial_sources (
    tenant_id VARCHAR(36) NOT NULL,
    source_system VARCHAR(30) NOT NULL,
    source_key VARCHAR(64) NOT NULL,
    source_revision BIGINT NOT NULL,
    product_key VARCHAR(80) NOT NULL,
    capacity_kind VARCHAR(10) NOT NULL,
    device_capacity INTEGER NOT NULL,
    features_json TEXT NOT NULL,
    active_from BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    state VARCHAR(10) NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    evidence_hash VARCHAR(64) NOT NULL,
    verified_by VARCHAR(255) NOT NULL,
    verified_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, source_system, source_key),
    CONSTRAINT fk_commercial_source_account FOREIGN KEY (tenant_id) REFERENCES commercial_accounts(tenant_id)
);
CREATE INDEX ix_commercial_source_expiry ON commercial_sources(expires_at, state);
CREATE INDEX ix_commercial_source_active ON commercial_sources(tenant_id, state, active_from, expires_at);

-- The immutable history is needed for refund/cancellation reconciliation and support audits.
CREATE TABLE commercial_source_events (
    tenant_id VARCHAR(36) NOT NULL,
    source_system VARCHAR(30) NOT NULL,
    source_key VARCHAR(64) NOT NULL,
    source_revision BIGINT NOT NULL,
    id VARCHAR(36) NOT NULL,
    product_key VARCHAR(80) NOT NULL,
    capacity_kind VARCHAR(10) NOT NULL,
    device_capacity INTEGER NOT NULL,
    features_json TEXT NOT NULL,
    active_from BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    state VARCHAR(10) NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    evidence_hash VARCHAR(64) NOT NULL,
    verified_by VARCHAR(255) NOT NULL,
    verified_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, source_system, source_key, source_revision),
    CONSTRAINT uq_commercial_event_id UNIQUE(id),
    CONSTRAINT fk_commercial_event_source FOREIGN KEY (tenant_id, source_system, source_key)
      REFERENCES commercial_sources(tenant_id, source_system, source_key)
);
CREATE INDEX ix_commercial_event_time ON commercial_source_events(tenant_id, verified_at, id);

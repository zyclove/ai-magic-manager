-- Separate export mutex: acquired after the creator's membership, before any export job.
CREATE TABLE audit_export_heads (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    CONSTRAINT fk_export_head_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

CREATE TABLE audit_exports (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    creator_key VARCHAR(64) NOT NULL,
    member_version BIGINT NOT NULL,
    state VARCHAR(20) NOT NULL,
    range_from BIGINT NOT NULL,
    range_to BIGINT NOT NULL,
    requested_to BIGINT NOT NULL,
    action_filter VARCHAR(100),
    resource_filter VARCHAR(100),
    correlation_filter VARCHAR(36),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    next_attempt_at BIGINT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    claim_token VARCHAR(36),
    lease_until BIGINT,
    record_count INTEGER,
    byte_count BIGINT,
    failure_code VARCHAR(60),
    artifact LONGTEXT,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_export_creator FOREIGN KEY(tenant_id,creator_key) REFERENCES tenant_members(tenant_id,actor_key)
);
CREATE INDEX ix_export_creator_time ON audit_exports(tenant_id,creator_key,created_at,id);
CREATE INDEX ix_export_queue ON audit_exports(state,next_attempt_at,created_at,id);
CREATE INDEX ix_export_lease ON audit_exports(state,lease_until);
CREATE INDEX ix_export_expiry ON audit_exports(expires_at,state);

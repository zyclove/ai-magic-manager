ALTER TABLE tenant_members ADD COLUMN version BIGINT NOT NULL DEFAULT 0;

-- One tenant-level mutex shared by membership and ownership commands.
CREATE TABLE ownership_heads (
    tenant_id VARCHAR(36) PRIMARY KEY,
    pending_transfer_id VARCHAR(36),
    CONSTRAINT fk_ownership_head_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);
INSERT INTO ownership_heads(tenant_id) SELECT id FROM tenants;

CREATE TABLE ownership_transfers (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    source_actor_id VARCHAR(255) NOT NULL,
    source_actor_key VARCHAR(64) NOT NULL,
    target_actor_id VARCHAR(255) NOT NULL,
    target_actor_key VARCHAR(64) NOT NULL,
    source_member_version BIGINT NOT NULL,
    target_member_version BIGINT NOT NULL,
    target_role VARCHAR(30) NOT NULL,
    former_owner_role VARCHAR(30) NOT NULL,
    tenant_version BIGINT NOT NULL,
    state VARCHAR(30) NOT NULL,
    reason VARCHAR(50),
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT fk_ownership_transfer_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);
CREATE INDEX ix_ownership_target ON ownership_transfers(tenant_id,target_actor_key,id);

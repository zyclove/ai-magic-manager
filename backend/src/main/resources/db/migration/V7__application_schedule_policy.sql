-- JSON is an application schema serialized into portable TEXT, not an engine-specific JSON contract.
CREATE TABLE application_definitions (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    identity_hash VARCHAR(64) NOT NULL,
    definition_json TEXT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_application_identity UNIQUE(tenant_id,identity_hash),
    CONSTRAINT fk_application_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);
CREATE TABLE schedule_definitions (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    definition_json MEDIUMTEXT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_schedule_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);
CREATE TABLE policy_drafts (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    name VARCHAR(100) NOT NULL,
    kind VARCHAR(20) NOT NULL,
    revision BIGINT NOT NULL DEFAULT 0,
    next_sequence BIGINT NOT NULL DEFAULT 0,
    rules_json MEDIUMTEXT NOT NULL,
    source_version_id VARCHAR(36) NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_policy_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);
CREATE TABLE policy_previews (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    policy_id VARCHAR(36) NOT NULL,
    draft_revision BIGINT NOT NULL,
    hash VARCHAR(64) NOT NULL,
    snapshot_json MEDIUMTEXT NOT NULL,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_preview_draft FOREIGN KEY(tenant_id,policy_id) REFERENCES policy_drafts(tenant_id,id)
);
CREATE INDEX ix_preview_expiry ON policy_previews(expires_at);
CREATE TABLE policy_versions (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    policy_id VARCHAR(36) NOT NULL,
    draft_revision BIGINT NOT NULL,
    sequence_number BIGINT NOT NULL,
    preview_id VARCHAR(36) NOT NULL,
    preview_hash VARCHAR(64) NOT NULL,
    mode VARCHAR(30) NOT NULL,
    snapshot_json MEDIUMTEXT NOT NULL,
    source_version_id VARCHAR(36) NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_policy_sequence UNIQUE(tenant_id,policy_id,sequence_number),
    CONSTRAINT fk_version_draft FOREIGN KEY(tenant_id,policy_id) REFERENCES policy_drafts(tenant_id,id),
    CONSTRAINT fk_version_preview FOREIGN KEY(tenant_id,preview_id) REFERENCES policy_previews(tenant_id,id),
    CONSTRAINT fk_version_source FOREIGN KEY(tenant_id,source_version_id) REFERENCES policy_versions(tenant_id,id)
);
ALTER TABLE policy_drafts ADD CONSTRAINT fk_draft_source FOREIGN KEY(tenant_id,source_version_id) REFERENCES policy_versions(tenant_id,id);
CREATE TABLE policy_publications (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    version_id VARCHAR(36) NOT NULL,
    state VARCHAR(40) NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_publication_version UNIQUE(tenant_id,version_id),
    CONSTRAINT fk_publication_version FOREIGN KEY(tenant_id,version_id) REFERENCES policy_versions(tenant_id,id)
);
CREATE TABLE policy_outbox (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    publication_id VARCHAR(36) NOT NULL,
    event_type VARCHAR(64) NOT NULL,
    payload_json MEDIUMTEXT NOT NULL,
    created_at BIGINT NOT NULL,
    delivered_at BIGINT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_outbox_publication FOREIGN KEY(tenant_id,publication_id) REFERENCES policy_publications(tenant_id,id)
);
CREATE INDEX ix_policy_outbox_pending ON policy_outbox(delivered_at,created_at,id);

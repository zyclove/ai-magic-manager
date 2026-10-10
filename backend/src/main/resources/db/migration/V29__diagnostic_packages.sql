CREATE TABLE diagnostic_package_heads (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    CONSTRAINT fk_diagnostic_package_head FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);
CREATE TABLE diagnostic_packages (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    requester_actor_id VARCHAR(255) NOT NULL,
    requester_key VARCHAR(64) NOT NULL,
    authority_actor_id VARCHAR(255) NOT NULL,
    authority_key VARCHAR(64) NOT NULL,
    authority_version BIGINT NOT NULL,
    access_mode VARCHAR(20) NOT NULL,
    grant_id VARCHAR(36),
    grant_version BIGINT,
    device_id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    type_mask INTEGER NOT NULL,
    state VARCHAR(20) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at BIGINT NOT NULL,
    next_validation_at BIGINT NOT NULL,
    claim_token VARCHAR(36),
    lease_until BIGINT,
    generated_at BIGINT,
    byte_count BIGINT,
    artifact_sha256 VARCHAR(64),
    artifact MEDIUMTEXT,
    failure_code VARCHAR(64),
    CONSTRAINT uq_diagnostic_package_tenant UNIQUE(tenant_id,id),
    CONSTRAINT fk_diagnostic_package_authority FOREIGN KEY(tenant_id,authority_key) REFERENCES tenant_members(tenant_id,actor_key),
    CONSTRAINT fk_diagnostic_package_device FOREIGN KEY(tenant_id,device_id) REFERENCES devices(tenant_id,id),
    CONSTRAINT fk_diagnostic_package_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id),
    CONSTRAINT fk_diagnostic_package_grant FOREIGN KEY(tenant_id,grant_id) REFERENCES support_grants(tenant_id,id),
    CONSTRAINT ck_diagnostic_package_scope CHECK (
      (access_mode='ADMIN' AND grant_id IS NULL AND grant_version IS NULL AND type_mask=7)
      OR (access_mode='SUPPORT_GRANT' AND grant_id IS NOT NULL AND grant_version IS NOT NULL AND type_mask BETWEEN 1 AND 7)
    ),
    CONSTRAINT ck_diagnostic_package_state CHECK (state IN ('QUEUED','RUNNING','READY','CANCELLED','EXPIRED','REVOKED','FAILED')),
    CONSTRAINT ck_diagnostic_package_deadline CHECK (expires_at>created_at AND expires_at-created_at<=1800000)
);
CREATE INDEX ix_diagnostic_package_owner ON diagnostic_packages(requester_key,access_mode,id);
CREATE INDEX ix_diagnostic_package_capacity ON diagnostic_packages(tenant_id,state,expires_at,id);
CREATE INDEX ix_diagnostic_package_queue ON diagnostic_packages(state,next_attempt_at,lease_until,id);
CREATE INDEX ix_diagnostic_package_cleanup ON diagnostic_packages(state,next_validation_at,id);

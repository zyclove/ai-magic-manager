CREATE TABLE usage_report_job_heads (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    CONSTRAINT fk_report_job_head FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);
CREATE TABLE usage_report_jobs (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    creator_key VARCHAR(64) NOT NULL,
    member_version BIGINT NOT NULL,
    state VARCHAR(20) NOT NULL,
    selection_json TEXT NOT NULL,
    selection_hash VARCHAR(64) NOT NULL,
    total_devices INTEGER NOT NULL,
    completed_devices INTEGER NOT NULL DEFAULT 0,
    byte_count BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    next_attempt_at BIGINT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    claim_token VARCHAR(36),
    lease_until BIGINT,
    failure_code VARCHAR(60),
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_report_job_creator FOREIGN KEY(tenant_id,creator_key) REFERENCES tenant_members(tenant_id,actor_key)
);
CREATE INDEX ix_report_job_creator ON usage_report_jobs(tenant_id,creator_key,created_at,id);
CREATE INDEX ix_report_job_queue ON usage_report_jobs(state,next_attempt_at,created_at,id);
CREATE INDEX ix_report_job_expiry ON usage_report_jobs(expires_at,state);
CREATE TABLE usage_report_parts (
    tenant_id VARCHAR(36) NOT NULL,
    job_id VARCHAR(36) NOT NULL,
    ordinal INTEGER NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    authorization_version BIGINT NOT NULL,
    usage_enabled BOOLEAN NOT NULL,
    byte_count BIGINT,
    generated_at BIGINT,
    artifact LONGTEXT,
    PRIMARY KEY(tenant_id,job_id,ordinal),
    CONSTRAINT uq_report_part_device UNIQUE(tenant_id,job_id,device_id),
    CONSTRAINT fk_report_part_job FOREIGN KEY(tenant_id,job_id) REFERENCES usage_report_jobs(tenant_id,id)
);

-- 尚未发布的初始化基线片段；不得用于清空或重置已有本机数据库。
CREATE TABLE IF NOT EXISTS family_commerce_work (
    job_key VARCHAR(80) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    kind VARCHAR(12) NOT NULL,
    entity_id VARCHAR(36) NOT NULL,
    generation BIGINT NOT NULL DEFAULT 0,
    lease_until BIGINT NOT NULL DEFAULT 0,
    next_attempt_at BIGINT NOT NULL DEFAULT 0,
    attempts INTEGER NOT NULL DEFAULT 0,
    state VARCHAR(20) NOT NULL,
    last_code VARCHAR(80) NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT fk_family_commerce_work_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id),
    INDEX ix_family_commerce_work_due (state,next_attempt_at,lease_until)
);

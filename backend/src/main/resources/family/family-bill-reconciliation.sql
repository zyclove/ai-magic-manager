-- 未发布初始化片段；仅新库，不作为已有数据升级脚本执行。
CREATE TABLE IF NOT EXISTS family_bill_tasks (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    merchant_key VARCHAR(64) NOT NULL,
    bill_date VARCHAR(10) NOT NULL,
    status VARCHAR(30) NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0,
    latest_attempt_id VARCHAR(36) NULL,
    lease_token VARCHAR(36) NULL,
    lease_until BIGINT NULL,
    next_attempt_at BIGINT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    INDEX idx_family_bill_work (status,next_attempt_at,lease_until),
    CONSTRAINT uq_family_bill_day UNIQUE (merchant_key,bill_date)
);

CREATE TABLE IF NOT EXISTS family_bill_attempts (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    task_id VARCHAR(36) NOT NULL,
    attempt_number INTEGER NOT NULL,
    status VARCHAR(30) NOT NULL,
    bill_hash VARCHAR(40) NULL,
    row_count INTEGER NOT NULL DEFAULT 0,
    matched_count INTEGER NOT NULL DEFAULT 0,
    ignored_count INTEGER NOT NULL DEFAULT 0,
    difference_count INTEGER NOT NULL DEFAULT 0,
    error_code VARCHAR(80) NULL,
    created_at BIGINT NOT NULL,
    completed_at BIGINT NULL,
    CONSTRAINT uq_family_bill_attempt UNIQUE (task_id,attempt_number),
    CONSTRAINT fk_family_bill_attempt_task FOREIGN KEY (task_id) REFERENCES family_bill_tasks(id)
);

CREATE TABLE IF NOT EXISTS family_bill_differences (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    task_id VARCHAR(36) NOT NULL,
    attempt_id VARCHAR(36) NOT NULL,
    kind VARCHAR(80) NOT NULL,
    tenant_id VARCHAR(36) NULL,
    order_id VARCHAR(36) NULL,
    refund_id VARCHAR(36) NULL,
    provider_reference VARCHAR(128) NULL,
    row_hash VARCHAR(64) NULL,
    expected_minor BIGINT NULL,
    actual_minor BIGINT NULL,
    state VARCHAR(30) NOT NULL,
    note VARCHAR(200) NULL,
    acknowledged_by VARCHAR(64) NULL,
    acknowledged_at BIGINT NULL,
    created_at BIGINT NOT NULL,
    INDEX idx_family_bill_difference_page (task_id,attempt_id,id),
    CONSTRAINT fk_family_bill_difference_task FOREIGN KEY (task_id) REFERENCES family_bill_tasks(id),
    CONSTRAINT fk_family_bill_difference_attempt FOREIGN KEY (attempt_id) REFERENCES family_bill_attempts(id)
);

CREATE TABLE IF NOT EXISTS family_bill_cursors (
    merchant_key VARCHAR(64) NOT NULL PRIMARY KEY,
    last_scheduled_date VARCHAR(10) NULL,
    updated_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS family_bill_audit_events (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    task_id VARCHAR(36) NOT NULL,
    difference_id VARCHAR(36) NULL,
    action VARCHAR(80) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    evidence_hash VARCHAR(64) NOT NULL,
    occurred_at BIGINT NOT NULL,
    CONSTRAINT fk_family_bill_audit_task FOREIGN KEY (task_id) REFERENCES family_bill_tasks(id),
    CONSTRAINT fk_family_bill_audit_difference FOREIGN KEY (difference_id) REFERENCES family_bill_differences(id)
);

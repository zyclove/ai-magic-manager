-- Merge into the initial baseline for new databases. This fragment is not an upgrade migration.
-- No tenant FK: a claimed trial must not reset when a family is erased/recreated.
CREATE TABLE IF NOT EXISTS family_trial_claims (
    identity_key VARCHAR(100) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NULL,
    claimed_at BIGINT NULL,
    evidence_hash VARCHAR(64) NULL
);

CREATE TABLE IF NOT EXISTS family_subscription_accounts (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    trial_started_at BIGINT NULL,
    trial_ends_at BIGINT NULL,
    trial_device_id VARCHAR(36) NULL,
    trial_evidence_hash VARCHAR(64) NULL,
    version BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT fk_family_account_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE TABLE IF NOT EXISTS family_orders (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    key_hash VARCHAR(64) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    plan_key VARCHAR(40) NOT NULL,
    status VARCHAR(30) NOT NULL,
    price_minor INTEGER NOT NULL,
    offer_version BIGINT NOT NULL DEFAULT 1,
    currency VARCHAR(3) NOT NULL,
    period_start BIGINT NOT NULL,
    period_end BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    provider_transaction_id VARCHAR(80) NULL,
    paid_at BIGINT NULL,
    CONSTRAINT uq_family_order_request UNIQUE (tenant_id, actor_key, key_hash),
    CONSTRAINT uq_family_provider_transaction UNIQUE (provider_transaction_id),
    INDEX ix_family_order_maintenance (status,expires_at,id),
    CONSTRAINT fk_family_order_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE TABLE IF NOT EXISTS family_payment_attempts (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    order_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    key_hash VARCHAR(64) NOT NULL,
    status VARCHAR(30) NOT NULL,
    provider_payload TEXT NULL,
    created_at BIGINT NOT NULL,
    CONSTRAINT uq_family_attempt_request UNIQUE (tenant_id, actor_key, key_hash),
    CONSTRAINT uq_family_attempt_order UNIQUE (order_id),
    CONSTRAINT fk_family_attempt_order FOREIGN KEY (order_id) REFERENCES family_orders(id)
);

CREATE TABLE IF NOT EXISTS family_refund_requests (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    order_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    key_hash VARCHAR(64) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    reason VARCHAR(200) NOT NULL,
    status VARCHAR(30) NOT NULL,
    price_minor INTEGER NOT NULL,
    reviewed_by VARCHAR(64) NULL,
    reviewed_at BIGINT NULL,
    created_at BIGINT NOT NULL,
    provider_refund_id VARCHAR(80) NULL,
    provider_accepted_at BIGINT NULL,
    refunded_at BIGINT NULL,
    CONSTRAINT uq_family_refund_request UNIQUE (tenant_id, actor_key, key_hash),
    CONSTRAINT uq_family_refund_order UNIQUE (order_id),
    CONSTRAINT uq_family_provider_refund UNIQUE (provider_refund_id),
    INDEX ix_family_refund_maintenance (status,created_at,id),
    CONSTRAINT fk_family_refund_order FOREIGN KEY (order_id) REFERENCES family_orders(id)
);

CREATE TABLE IF NOT EXISTS family_payment_inbox (
    event_id VARCHAR(100) NOT NULL PRIMARY KEY,
    event_type VARCHAR(30) NOT NULL,
    order_id VARCHAR(36) NOT NULL,
    evidence_hash VARCHAR(64) NOT NULL,
    accepted_at BIGINT NOT NULL,
    CONSTRAINT fk_family_inbox_order FOREIGN KEY (order_id) REFERENCES family_orders(id)
);

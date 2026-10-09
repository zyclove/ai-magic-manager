CREATE TABLE quota_calendars (
    tenant_id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    time_zone VARCHAR(100) NOT NULL,
    PRIMARY KEY(tenant_id,subject_id),
    CONSTRAINT fk_quota_calendar_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);
CREATE TABLE quota_pools (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    name VARCHAR(100) NOT NULL,
    scope_key VARCHAR(50) NOT NULL,
    application_id VARCHAR(36) NULL,
    period_id VARCHAR(10) NOT NULL,
    time_zone VARCHAR(100) NOT NULL,
    period_start BIGINT NOT NULL,
    period_end BIGINT NOT NULL,
    limit_seconds BIGINT NOT NULL,
    used_seconds BIGINT NOT NULL DEFAULT 0,
    reserved_seconds BIGINT NOT NULL DEFAULT 0,
    version BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_quota_period UNIQUE(tenant_id,subject_id,scope_key,period_id),
    CONSTRAINT fk_quota_pool_calendar FOREIGN KEY(tenant_id,subject_id) REFERENCES quota_calendars(tenant_id,subject_id),
    CONSTRAINT fk_quota_pool_app FOREIGN KEY(tenant_id,application_id) REFERENCES application_definitions(tenant_id,id),
    CONSTRAINT ck_quota_balance CHECK(limit_seconds >= 0 AND used_seconds >= 0 AND reserved_seconds >= 0 AND used_seconds + reserved_seconds <= limit_seconds),
    CONSTRAINT ck_quota_period CHECK(period_end > period_start)
);
CREATE INDEX ix_quota_pool_subject ON quota_pools(tenant_id,subject_id,period_start,period_end);
CREATE TABLE quota_leases (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    application_id VARCHAR(36) NOT NULL,
    request_id VARCHAR(36) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    boot_id VARCHAR(36) NOT NULL,
    session_id VARCHAR(36) NOT NULL,
    start_tick_millis BIGINT NOT NULL,
    reserved_seconds BIGINT NOT NULL,
    used_seconds BIGINT NOT NULL DEFAULT 0,
    last_sequence BIGINT NOT NULL DEFAULT 0,
    last_tick_millis BIGINT NOT NULL,
    last_report_hash VARCHAR(64) NULL,
    state VARCHAR(24) NOT NULL DEFAULT 'ACTIVE',
    issued_at BIGINT NOT NULL,
    not_after BIGINT NOT NULL,
    signed_lease TEXT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_quota_lease_request UNIQUE(tenant_id,registration_id,request_id),
    CONSTRAINT fk_quota_lease_calendar FOREIGN KEY(tenant_id,subject_id) REFERENCES quota_calendars(tenant_id,subject_id),
    CONSTRAINT fk_quota_lease_device FOREIGN KEY(tenant_id,device_id) REFERENCES devices(tenant_id,id),
    CONSTRAINT ck_quota_lease_balance CHECK(used_seconds >= 0 AND used_seconds <= reserved_seconds)
);
CREATE INDEX ix_quota_lease_device ON quota_leases(tenant_id,device_id,id);
CREATE INDEX ix_quota_lease_app_period ON quota_leases(tenant_id,subject_id,application_id,issued_at);
CREATE TABLE quota_lease_pools (
    tenant_id VARCHAR(36) NOT NULL,
    lease_id VARCHAR(36) NOT NULL,
    pool_id VARCHAR(36) NOT NULL,
    PRIMARY KEY(tenant_id,lease_id,pool_id),
    CONSTRAINT fk_quota_allocation_lease FOREIGN KEY(tenant_id,lease_id) REFERENCES quota_leases(tenant_id,id),
    CONSTRAINT fk_quota_allocation_pool FOREIGN KEY(tenant_id,pool_id) REFERENCES quota_pools(tenant_id,id)
);
CREATE TABLE quota_ledger (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    pool_id VARCHAR(36) NOT NULL,
    lease_id VARCHAR(36) NULL,
    kind VARCHAR(24) NOT NULL,
    limit_delta BIGINT NOT NULL,
    used_delta BIGINT NOT NULL,
    reserved_delta BIGINT NOT NULL,
    sequence_number BIGINT NULL,
    reason VARCHAR(40) NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_quota_ledger_pool FOREIGN KEY(tenant_id,pool_id) REFERENCES quota_pools(tenant_id,id)
);
CREATE INDEX ix_quota_ledger_pool ON quota_ledger(tenant_id,pool_id,id);
CREATE TABLE quota_outbox (
    id VARCHAR(36) PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    aggregate_id VARCHAR(36) NOT NULL,
    event_type VARCHAR(40) NOT NULL,
    event_json TEXT NOT NULL,
    occurred_at BIGINT NOT NULL
);

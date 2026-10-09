-- Tenant-owned relationships include tenant_id in their keys and foreign keys.
-- UTC instants are stored as epoch milliseconds; local schedules retain IANA zones.
CREATE TABLE tenants (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    kind VARCHAR(20) NOT NULL,
    time_zone VARCHAR(100) NOT NULL,
    created_at BIGINT NOT NULL,
    version BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE subjects (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    nickname VARCHAR(60) NOT NULL,
    age_band VARCHAR(20) NOT NULL,
    created_at BIGINT NOT NULL,
    archived_at BIGINT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT fk_subject_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);
CREATE INDEX ix_subject_tenant_created ON subjects(tenant_id, created_at, id);

CREATE TABLE tenant_members (
    tenant_id VARCHAR(36) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    role VARCHAR(30) NOT NULL,
    subject_id VARCHAR(36) NULL,
    revoked_at TIMESTAMP(6) NULL,
    PRIMARY KEY (tenant_id, actor_key),
    CONSTRAINT fk_member_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id),
    CONSTRAINT fk_member_subject FOREIGN KEY (tenant_id, subject_id) REFERENCES subjects(tenant_id, id)
);
CREATE INDEX ix_member_actor ON tenant_members(actor_key, revoked_at, tenant_id);

CREATE TABLE audit_events (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    action VARCHAR(100) NOT NULL,
    resource_id VARCHAR(100) NOT NULL,
    correlation_id VARCHAR(36) NOT NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT fk_audit_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);
CREATE INDEX ix_audit_tenant_time ON audit_events(tenant_id, occurred_at, id);

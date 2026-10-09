CREATE TABLE quota_plans (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    scope_key VARCHAR(50) NOT NULL,
    application_id VARCHAR(36) NULL,
    time_zone VARCHAR(100) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    next_materialize_at BIGINT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_quota_plan_scope UNIQUE(tenant_id,subject_id,scope_key),
    CONSTRAINT fk_quota_plan_calendar FOREIGN KEY(tenant_id,subject_id) REFERENCES quota_calendars(tenant_id,subject_id),
    CONSTRAINT fk_quota_plan_application FOREIGN KEY(tenant_id,application_id) REFERENCES application_definitions(tenant_id,id)
);
CREATE INDEX ix_quota_plan_due ON quota_plans(next_materialize_at,id);
CREATE TABLE quota_plan_revisions (
    tenant_id VARCHAR(36) NOT NULL,
    plan_id VARCHAR(36) NOT NULL,
    version BIGINT NOT NULL,
    effective_from VARCHAR(10) NOT NULL,
    configuration_json TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,plan_id,version),
    CONSTRAINT fk_quota_revision_plan FOREIGN KEY(tenant_id,plan_id) REFERENCES quota_plans(tenant_id,id)
);
CREATE INDEX ix_quota_revision_period ON quota_plan_revisions(tenant_id,plan_id,effective_from,version);
ALTER TABLE quota_pools ADD COLUMN plan_id VARCHAR(36) NULL;
ALTER TABLE quota_pools ADD COLUMN plan_version BIGINT NULL;
ALTER TABLE quota_pools ADD CONSTRAINT fk_quota_pool_revision FOREIGN KEY(tenant_id,plan_id,plan_version)
    REFERENCES quota_plan_revisions(tenant_id,plan_id,version);
ALTER TABLE quota_pools ADD CONSTRAINT ck_quota_pool_source CHECK(
    (plan_id IS NULL AND plan_version IS NULL) OR (plan_id IS NOT NULL AND plan_version IS NOT NULL));

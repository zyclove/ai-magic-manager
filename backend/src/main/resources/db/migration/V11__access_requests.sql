-- Approval is a server authority fact; neither this row nor its decision proves device execution.
CREATE TABLE access_requests (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    policy_id VARCHAR(36) NOT NULL,
    base_version_id VARCHAR(36) NOT NULL,
    base_sequence BIGINT NOT NULL,
    application_id VARCHAR(36) NOT NULL,
    rule_ids_json TEXT NOT NULL,
    requester_actor_id VARCHAR(255) NOT NULL,
    requester_actor_key VARCHAR(64) NOT NULL,
    requested_window_seconds BIGINT NOT NULL,
    child_reason VARCHAR(300) NULL,
    state VARCHAR(40) NOT NULL,
    request_expires_at BIGINT NOT NULL,
    granted_window_seconds BIGINT NULL,
    issued_at BIGINT NULL,
    absolute_not_after BIGINT NULL,
    approver_actor_id VARCHAR(255) NULL,
    approver_actor_key VARCHAR(64) NULL,
    reason_code VARCHAR(60) NULL,
    version BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_access_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id),
    CONSTRAINT fk_access_policy FOREIGN KEY(tenant_id,policy_id) REFERENCES policy_drafts(tenant_id,id),
    CONSTRAINT fk_access_version FOREIGN KEY(tenant_id,base_version_id) REFERENCES policy_versions(tenant_id,id),
    CONSTRAINT fk_access_application FOREIGN KEY(tenant_id,application_id) REFERENCES application_definitions(tenant_id,id)
);
CREATE INDEX ix_access_subject ON access_requests(tenant_id,subject_id,id);
CREATE INDEX ix_access_baseline ON access_requests(tenant_id,policy_id,state,base_sequence);
CREATE INDEX ix_access_expiry ON access_requests(state,request_expires_at);
CREATE INDEX ix_access_grant_expiry ON access_requests(state,absolute_not_after);
CREATE INDEX ix_access_approver ON access_requests(tenant_id,approver_actor_key,state);
CREATE INDEX ix_access_requester ON access_requests(tenant_id,requester_actor_key,state);
CREATE TABLE access_request_slots (
    tenant_id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    application_id VARCHAR(36) NOT NULL,
    last_request_id VARCHAR(36) NULL,
    next_allowed_at BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,subject_id,registration_id,application_id),
    CONSTRAINT fk_access_slot_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);
CREATE TABLE access_request_decisions (
    tenant_id VARCHAR(36) NOT NULL,
    request_id VARCHAR(36) NOT NULL,
    decision VARCHAR(20) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    granted_window_seconds BIGINT NULL,
    absolute_not_after BIGINT NULL,
    reason_code VARCHAR(60) NULL,
    decided_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,request_id),
    CONSTRAINT fk_access_decision FOREIGN KEY(tenant_id,request_id) REFERENCES access_requests(tenant_id,id)
);

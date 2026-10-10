-- AI Manager 1.0.0: complete schema for a new, empty application database.
-- This baseline does not upgrade development databases from earlier iterations.
-- Persistent event publication is initialized by the vendor-specific second script.

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
    version BIGINT NOT NULL DEFAULT 0,
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

CREATE TABLE member_invitations (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    inviter_actor_id VARCHAR(255) NOT NULL,
    recipient_email_hash VARCHAR(64) NOT NULL,
    role VARCHAR(30) NOT NULL,
    subject_id VARCHAR(36) NULL,
    token_hash VARCHAR(64) NOT NULL,
    expires_at BIGINT NOT NULL,
    consumed_at BIGINT NULL,
    revoked_at BIGINT NULL,
    CONSTRAINT uq_invitation_token UNIQUE (token_hash),
    CONSTRAINT fk_invitation_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id),
    CONSTRAINT fk_invitation_subject FOREIGN KEY (tenant_id, subject_id) REFERENCES subjects(tenant_id, id)
);

CREATE INDEX ix_invitation_tenant_expiry ON member_invitations(tenant_id, expires_at);

CREATE TABLE idempotency_requests (
    scope_id VARCHAR(100) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    operation VARCHAR(80) NOT NULL,
    key_hash VARCHAR(64) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    response_body TEXT NULL,
    expires_at BIGINT NOT NULL,
    PRIMARY KEY (scope_id, actor_key, operation, key_hash)
);

CREATE INDEX ix_idempotency_expiry ON idempotency_requests(expires_at);

CREATE TABLE device_enrollments (
    recovery_attempts INTEGER NOT NULL DEFAULT 0,
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    creator_actor_id VARCHAR(255) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    requested_mode VARCHAR(30) NOT NULL,
    token_hash VARCHAR(64) NOT NULL,
    state VARCHAR(30) NOT NULL,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    device_id VARCHAR(36) NULL,
    pairing_hash VARCHAR(64) NULL,
    pairing_failures INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id,id),
    CONSTRAINT uq_enrollment_id UNIQUE(id),
    CONSTRAINT uq_enrollment_token UNIQUE(token_hash),
    CONSTRAINT fk_enrollment_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);

CREATE INDEX ix_enrollment_expiry ON device_enrollments(state,expires_at);

CREATE TABLE devices (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    display_name VARCHAR(100) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    os_version VARCHAR(100) NOT NULL,
    state VARCHAR(30) NOT NULL,
    public_key_jwk TEXT NOT NULL,
    key_thumbprint VARCHAR(64) NOT NULL,
    created_at BIGINT NOT NULL,
    last_heartbeat_at BIGINT NULL,
    heartbeat_sequence BIGINT NOT NULL DEFAULT 0,
    heartbeat_hash VARCHAR(64) NULL,
    agent_version VARCHAR(60) NULL,
    version BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_device_registration UNIQUE(tenant_id,id,registration_id),
    CONSTRAINT fk_device_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);

CREATE INDEX ix_device_subject ON devices(tenant_id,subject_id,id);

ALTER TABLE device_enrollments ADD CONSTRAINT fk_enrollment_device
    FOREIGN KEY(tenant_id,device_id) REFERENCES devices(tenant_id,id);

CREATE TABLE device_credentials (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    token_hash VARCHAR(64) NOT NULL,
    active BOOLEAN NOT NULL,
    issued_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    revoked_at BIGINT NULL,
    CONSTRAINT uq_device_token UNIQUE(token_hash),
    CONSTRAINT fk_credential_registration FOREIGN KEY(tenant_id,device_id,registration_id)
        REFERENCES devices(tenant_id,id,registration_id)
);

CREATE INDEX ix_credential_registration ON device_credentials(tenant_id,registration_id,active);

CREATE TABLE device_capabilities (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    capability_key VARCHAR(64) NOT NULL,
    reported_supported BOOLEAN NOT NULL,
    grant_status VARCHAR(30) NOT NULL,
    checked_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,device_id,capability_key),
    CONSTRAINT fk_capability_device FOREIGN KEY(tenant_id,device_id) REFERENCES devices(tenant_id,id)
);

CREATE TABLE device_credential_scopes (
    tenant_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    active BOOLEAN NOT NULL,
    revoked_at BIGINT NULL,
    PRIMARY KEY(tenant_id,registration_id),
    CONSTRAINT fk_credential_scope_device FOREIGN KEY(tenant_id,device_id,registration_id)
        REFERENCES devices(tenant_id,id,registration_id)
);

CREATE TABLE device_credential_rotations (
    parent_id VARCHAR(36) NOT NULL PRIMARY KEY,
    new_id VARCHAR(36) NOT NULL,
    expires_at BIGINT NOT NULL,
    confirmed_at BIGINT NULL,
    cancelled_at BIGINT NULL,
    CONSTRAINT uq_rotation_new UNIQUE(new_id),
    CONSTRAINT fk_rotation_parent FOREIGN KEY(parent_id) REFERENCES device_credentials(id),
    CONSTRAINT fk_rotation_new FOREIGN KEY(new_id) REFERENCES device_credentials(id)
);

CREATE TABLE enrollment_proofs (
    tenant_id VARCHAR(36) NOT NULL,
    enrollment_id VARCHAR(36) NOT NULL,
    purpose VARCHAR(60) NOT NULL,
    jti_hash VARCHAR(64) NOT NULL,
    consumed_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,enrollment_id,purpose,jti_hash),
    CONSTRAINT fk_proof_enrollment FOREIGN KEY(tenant_id,enrollment_id) REFERENCES device_enrollments(tenant_id,id)
);

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
    creator_actor_key VARCHAR(64),
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

CREATE TABLE application_inventory_snapshots (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    sequence_number BIGINT NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    snapshot_json MEDIUMTEXT NOT NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,device_id),
    CONSTRAINT fk_inventory_registration FOREIGN KEY(tenant_id,device_id,registration_id)
        REFERENCES devices(tenant_id,id,registration_id)
);

CREATE TABLE configuration_device_heads (
    tenant_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    next_cursor BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,registration_id),
    CONSTRAINT fk_configuration_head_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

CREATE TABLE configuration_deliveries (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    publication_id VARCHAR(36) NOT NULL,
    version_id VARCHAR(36) NOT NULL,
    policy_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    source_sequence BIGINT NOT NULL,
    device_cursor BIGINT NOT NULL,
    action VARCHAR(32) NOT NULL,
    document_json MEDIUMTEXT NULL,
    issued_at BIGINT NOT NULL,
    delivery_expires_at BIGINT NOT NULL,
    state VARCHAR(40) NOT NULL,
    compact_jws MEDIUMTEXT NULL,
    envelope_hash VARCHAR(64) NULL,
    signing_key_id VARCHAR(64) NULL,
    first_served_at BIGINT NULL,
    received_reported_at BIGINT NULL,
    stored_reported_at BIGINT NULL,
    rejection_code VARCHAR(50) NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_configuration_delivery_head FOREIGN KEY(tenant_id,registration_id) REFERENCES configuration_device_heads(tenant_id,registration_id),
    CONSTRAINT fk_configuration_delivery_version FOREIGN KEY(tenant_id,version_id) REFERENCES policy_versions(tenant_id,id),
    CONSTRAINT fk_configuration_delivery_publication FOREIGN KEY(tenant_id,publication_id) REFERENCES policy_publications(tenant_id,id)
);

CREATE INDEX ix_configuration_publication ON configuration_deliveries(tenant_id,publication_id,id);

CREATE TABLE configuration_streams (
    tenant_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    policy_id VARCHAR(36) NOT NULL,
    delivery_id VARCHAR(36) NOT NULL,
    PRIMARY KEY(tenant_id,registration_id,policy_id),
    CONSTRAINT fk_configuration_stream_head FOREIGN KEY(tenant_id,registration_id) REFERENCES configuration_device_heads(tenant_id,registration_id),
    CONSTRAINT fk_configuration_stream_delivery FOREIGN KEY(tenant_id,delivery_id) REFERENCES configuration_deliveries(tenant_id,id)
);

CREATE TABLE configuration_receipts (
    tenant_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    delivery_id VARCHAR(36) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    response_json TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,registration_id,id),
    CONSTRAINT fk_configuration_receipt_head FOREIGN KEY(tenant_id,registration_id) REFERENCES configuration_device_heads(tenant_id,registration_id),
    CONSTRAINT fk_configuration_receipt_delivery FOREIGN KEY(tenant_id,delivery_id) REFERENCES configuration_deliveries(tenant_id,id)
);

CREATE TABLE access_requests (
    requester_kind VARCHAR(16) NOT NULL DEFAULT 'MEMBER',
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

CREATE TABLE deprovision_previews (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    device_version BIGINT NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    preview_hash VARCHAR(64) NOT NULL,
    expires_at BIGINT NOT NULL,
    operation_id VARCHAR(36) NULL,
    PRIMARY KEY(tenant_id,id)
);

CREATE INDEX ix_deprovision_preview_expiry ON deprovision_previews(expires_at);

CREATE TABLE deprovision_operations (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    command_id VARCHAR(36) NOT NULL,
    key_thumbprint VARCHAR(64) NOT NULL,
    compact_jws TEXT NOT NULL,
    command_hash VARCHAR(64) NOT NULL,
    state VARCHAR(40) NOT NULL,
    local_evidence VARCHAR(40) NOT NULL,
    reason_code VARCHAR(60) NULL,
    issued_at BIGINT NOT NULL,
    absolute_not_after BIGINT NOT NULL,
    served_at BIGINT NULL,
    updated_at BIGINT NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_cleanup_command UNIQUE(tenant_id,command_id)
);

CREATE INDEX ix_deprovision_device ON deprovision_operations(tenant_id,device_id,id);

CREATE INDEX ix_deprovision_expiry ON deprovision_operations(state,absolute_not_after);

CREATE TABLE deprovision_heads (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    operation_id VARCHAR(36) NULL,
    PRIMARY KEY(tenant_id,device_id,registration_id)
);

CREATE TABLE cleanup_receipts (
    tenant_id VARCHAR(36) NOT NULL,
    operation_id VARCHAR(36) NOT NULL,
    receipt_id VARCHAR(36) NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    stage VARCHAR(30) NOT NULL,
    received_at BIGINT NOT NULL,
    response_json TEXT NOT NULL,
    PRIMARY KEY(tenant_id,operation_id,receipt_id),
    CONSTRAINT fk_cleanup_receipt FOREIGN KEY(tenant_id,operation_id) REFERENCES deprovision_operations(tenant_id,id)
);

CREATE TABLE quota_calendars (
    tenant_id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    time_zone VARCHAR(100) NOT NULL,
    PRIMARY KEY(tenant_id,subject_id),
    CONSTRAINT fk_quota_calendar_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);

CREATE TABLE quota_pools (
    plan_version BIGINT NULL,
    plan_id VARCHAR(36) NULL,
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

ALTER TABLE quota_pools ADD CONSTRAINT fk_quota_pool_revision FOREIGN KEY(tenant_id,plan_id,plan_version)
    REFERENCES quota_plan_revisions(tenant_id,plan_id,version);

ALTER TABLE quota_pools ADD CONSTRAINT ck_quota_pool_source CHECK(
    (plan_id IS NULL AND plan_version IS NULL) OR (plan_id IS NOT NULL AND plan_version IS NOT NULL));

CREATE TABLE access_window_documents (
    current_attempt INT NOT NULL DEFAULT 1,
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    request_id VARCHAR(36) NOT NULL,
    approval_version BIGINT NOT NULL,
    action VARCHAR(40) NOT NULL,
    signed_document TEXT NOT NULL,
    issued_at BIGINT NOT NULL,
    delivery_state VARCHAR(20) NOT NULL,
    last_receipt_at BIGINT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_access_document_version UNIQUE(tenant_id,request_id,approval_version),
    CONSTRAINT fk_access_document_request FOREIGN KEY(tenant_id,request_id) REFERENCES access_requests(tenant_id,id)
);

CREATE TABLE access_window_receipts (
    tenant_id VARCHAR(36) NOT NULL,
    document_id VARCHAR(36) NOT NULL,
    phase VARCHAR(20) NOT NULL,
    reason_code VARCHAR(40) NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,document_id,phase),
    CONSTRAINT fk_access_receipt_document FOREIGN KEY(tenant_id,document_id) REFERENCES access_window_documents(tenant_id,id)
);

CREATE INDEX ix_access_device_sync ON access_requests(tenant_id,device_id,registration_id,id);

CREATE TABLE access_window_attempts (
    tenant_id VARCHAR(36) NOT NULL,
    document_id VARCHAR(36) NOT NULL,
    attempt_number INT NOT NULL,
    created_at BIGINT NOT NULL,
    delivery_state VARCHAR(20) NOT NULL,
    reason_code VARCHAR(40) NULL,
    last_receipt_at BIGINT NULL,
    PRIMARY KEY(tenant_id,document_id,attempt_number),
    CONSTRAINT ck_access_attempt_range CHECK(attempt_number BETWEEN 1 AND 10),
    CONSTRAINT fk_access_attempt_document FOREIGN KEY(tenant_id,document_id) REFERENCES access_window_documents(tenant_id,id)
);

CREATE TABLE access_window_attempt_receipts (
    tenant_id VARCHAR(36) NOT NULL,
    document_id VARCHAR(36) NOT NULL,
    attempt_number INT NOT NULL,
    phase VARCHAR(20) NOT NULL,
    reason_code VARCHAR(40) NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,document_id,attempt_number,phase),
    CONSTRAINT fk_access_receipt_attempt FOREIGN KEY(tenant_id,document_id,attempt_number) REFERENCES access_window_attempts(tenant_id,document_id,attempt_number)
);

CREATE TABLE ownership_heads (
    tenant_id VARCHAR(36) PRIMARY KEY,
    pending_transfer_id VARCHAR(36),
    CONSTRAINT fk_ownership_head_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE TABLE ownership_transfers (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    source_actor_id VARCHAR(255) NOT NULL,
    source_actor_key VARCHAR(64) NOT NULL,
    target_actor_id VARCHAR(255) NOT NULL,
    target_actor_key VARCHAR(64) NOT NULL,
    source_member_version BIGINT NOT NULL,
    target_member_version BIGINT NOT NULL,
    target_role VARCHAR(30) NOT NULL,
    former_owner_role VARCHAR(30) NOT NULL,
    tenant_version BIGINT NOT NULL,
    state VARCHAR(30) NOT NULL,
    reason VARCHAR(50),
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (tenant_id, id),
    CONSTRAINT fk_ownership_transfer_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE INDEX ix_ownership_target ON ownership_transfers(tenant_id,target_actor_key,id);

CREATE TABLE actor_profiles (
    actor_key VARCHAR(64) NOT NULL PRIMARY KEY,
    actor_id VARCHAR(255) NOT NULL,
    display_name VARCHAR(100),
    verified_email VARCHAR(254),
    claims_issued_at BIGINT NOT NULL,
    observed_at BIGINT NOT NULL
);

CREATE INDEX ix_preview_creator ON policy_previews(tenant_id,creator_actor_key,expires_at);

CREATE INDEX ix_invitation_creator ON member_invitations(tenant_id,inviter_actor_id,revoked_at);

CREATE INDEX ix_enrollment_creator ON device_enrollments(tenant_id,creator_actor_id,state);

CREATE TABLE membership_access_changes (
    class_ids_json TEXT,
    previous_class_ids_json TEXT,
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    member_key VARCHAR(64) NOT NULL,
    change_type VARCHAR(20) NOT NULL,
    previous_role VARCHAR(30) NOT NULL,
    previous_subject_id VARCHAR(36),
    role VARCHAR(30),
    subject_id VARCHAR(36),
    member_version BIGINT NOT NULL,
    changed_by_actor_id VARCHAR(255) NOT NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id,id),
    CONSTRAINT uq_member_access_epoch UNIQUE(tenant_id,member_key,member_version),
    CONSTRAINT fk_member_access_history FOREIGN KEY(tenant_id,member_key) REFERENCES tenant_members(tenant_id,actor_key)
);

CREATE TABLE organization_classes (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    name VARCHAR(100) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    archived_at BIGINT,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_class_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

CREATE TABLE organization_class_students (
    tenant_id VARCHAR(36) NOT NULL,
    class_id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    added_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,class_id,subject_id),
    CONSTRAINT fk_class_student_class FOREIGN KEY(tenant_id,class_id) REFERENCES organization_classes(tenant_id,id),
    CONSTRAINT fk_class_student_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);

CREATE INDEX ix_class_student_subject ON organization_class_students(tenant_id,subject_id,class_id);

CREATE TABLE tenant_member_class_scopes (
    tenant_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    class_id VARCHAR(36) NOT NULL,
    member_version BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,actor_key,class_id),
    CONSTRAINT fk_class_scope_member FOREIGN KEY(tenant_id,actor_key) REFERENCES tenant_members(tenant_id,actor_key),
    CONSTRAINT fk_class_scope_class FOREIGN KEY(tenant_id,class_id) REFERENCES organization_classes(tenant_id,id)
);

CREATE INDEX ix_class_scope_class ON tenant_member_class_scopes(tenant_id,class_id,actor_key);

ALTER TABLE member_invitations ADD CONSTRAINT uq_invitation_tenant UNIQUE(tenant_id,id);

CREATE TABLE invitation_class_scopes (
    invitation_id VARCHAR(36) NOT NULL,
    tenant_id VARCHAR(36) NOT NULL,
    class_id VARCHAR(36) NOT NULL,
    PRIMARY KEY(invitation_id,class_id),
    CONSTRAINT fk_invitation_scope_invitation FOREIGN KEY(tenant_id,invitation_id) REFERENCES member_invitations(tenant_id,id),
    CONSTRAINT fk_invitation_scope_class FOREIGN KEY(tenant_id,class_id) REFERENCES organization_classes(tenant_id,id)
);

CREATE TABLE device_observation_settings (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    version BIGINT NOT NULL,
    inventory_enabled BOOLEAN NOT NULL,
    usage_enabled BOOLEAN NOT NULL,
    updated_at BIGINT NOT NULL,
    last_reason VARCHAR(300) NOT NULL,
    PRIMARY KEY (tenant_id, device_id),
    CONSTRAINT fk_observation_settings_device FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);

CREATE TABLE usage_observation_heads (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    sequence_number BIGINT NOT NULL,
    report_id VARCHAR(36) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, device_id),
    CONSTRAINT fk_usage_head_device FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);

CREATE TABLE usage_observation_batches (
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    sequence_number BIGINT NOT NULL,
    report_id VARCHAR(36) NOT NULL,
    authorization_version BIGINT NOT NULL,
    payload_json MEDIUMTEXT NOT NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, device_id, sequence_number),
    CONSTRAINT uq_usage_report UNIQUE (tenant_id, device_id, report_id),
    CONSTRAINT fk_usage_batch_device FOREIGN KEY (tenant_id, device_id, registration_id)
        REFERENCES devices(tenant_id, id, registration_id)
);

CREATE INDEX ix_usage_observation_retention ON usage_observation_batches(received_at);

CREATE TABLE notification_events (
    requester_kind VARCHAR(16) NOT NULL DEFAULT 'MEMBER',
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    request_id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    requester_actor_key VARCHAR(64) NOT NULL,
    request_version BIGINT NOT NULL,
    state VARCHAR(40) NOT NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_notification_request_version UNIQUE(tenant_id,request_id,request_version),
    CONSTRAINT fk_notification_request FOREIGN KEY(tenant_id,request_id) REFERENCES access_requests(tenant_id,id) ON DELETE CASCADE,
    CONSTRAINT ck_notification_version CHECK(request_version>=0)
);

CREATE INDEX ix_notification_time ON notification_events(tenant_id,occurred_at,id);

CREATE INDEX ix_notification_requester ON notification_events(tenant_id,requester_actor_key,occurred_at,id);

CREATE INDEX ix_notification_retention ON notification_events(occurred_at,tenant_id,id);

CREATE TABLE notification_reads (
    tenant_id VARCHAR(36) NOT NULL,
    notification_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    read_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,notification_id,actor_key),
    CONSTRAINT fk_notification_read_event FOREIGN KEY(tenant_id,notification_id) REFERENCES notification_events(tenant_id,id) ON DELETE CASCADE,
    CONSTRAINT fk_notification_read_member FOREIGN KEY(tenant_id,actor_key) REFERENCES tenant_members(tenant_id,actor_key) ON DELETE CASCADE
);

CREATE INDEX ix_notification_read_actor ON notification_reads(tenant_id,actor_key,notification_id);

CREATE TABLE audit_export_heads (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    CONSTRAINT fk_export_head_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

CREATE TABLE audit_exports (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    creator_key VARCHAR(64) NOT NULL,
    member_version BIGINT NOT NULL,
    state VARCHAR(20) NOT NULL,
    range_from BIGINT NOT NULL,
    range_to BIGINT NOT NULL,
    requested_to BIGINT NOT NULL,
    action_filter VARCHAR(100),
    resource_filter VARCHAR(100),
    correlation_filter VARCHAR(36),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    next_attempt_at BIGINT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    claim_token VARCHAR(36),
    lease_until BIGINT,
    record_count INTEGER,
    byte_count BIGINT,
    failure_code VARCHAR(60),
    artifact LONGTEXT,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT fk_export_creator FOREIGN KEY(tenant_id,creator_key) REFERENCES tenant_members(tenant_id,actor_key)
);

CREATE INDEX ix_export_creator_time ON audit_exports(tenant_id,creator_key,created_at,id);

CREATE INDEX ix_export_queue ON audit_exports(state,next_attempt_at,created_at,id);

CREATE INDEX ix_export_lease ON audit_exports(state,lease_until);

CREATE INDEX ix_export_expiry ON audit_exports(expires_at,state);

CREATE INDEX ix_access_device_requester ON access_requests(tenant_id,device_id,registration_id,requester_kind,id);

CREATE TABLE application_classifications (
    tenant_id VARCHAR(36) NOT NULL,
    identity_hash VARCHAR(64) NOT NULL,
    platform VARCHAR(20) NOT NULL,
    profile VARCHAR(20) NOT NULL,
    package_name VARCHAR(255) NOT NULL,
    category VARCHAR(24) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NULL,
    PRIMARY KEY(tenant_id,identity_hash),
    CONSTRAINT fk_application_classification_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

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

CREATE TABLE support_pairing_creation_locks (
    actor_key VARCHAR(64) NOT NULL PRIMARY KEY
);

CREATE TABLE support_pairing_heads (
    actor_key VARCHAR(64) NOT NULL PRIMARY KEY,
    create_window BIGINT NOT NULL DEFAULT 0,
    create_count INTEGER NOT NULL DEFAULT 0,
    resolve_window BIGINT NOT NULL DEFAULT 0,
    resolve_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE support_pairing_requests (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    recipient_actor_id VARCHAR(255) NOT NULL,
    recipient_key VARCHAR(64) NOT NULL,
    display_name VARCHAR(100),
    verified_email VARCHAR(254),
    code_hash VARCHAR(64) NOT NULL,
    state VARCHAR(20) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT uq_support_pairing_code UNIQUE(code_hash)
);

CREATE INDEX ix_support_pairing_recipient ON support_pairing_requests(recipient_key,id);

CREATE INDEX ix_support_pairing_pending ON support_pairing_requests(recipient_key,state,expires_at,id);

CREATE INDEX ix_support_pairing_expiry ON support_pairing_requests(expires_at,id);

CREATE TABLE support_pairing_events (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    request_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    action VARCHAR(30) NOT NULL,
    occurred_at BIGINT NOT NULL,
    CONSTRAINT fk_support_pairing_event FOREIGN KEY(request_id) REFERENCES support_pairing_requests(id)
);

CREATE INDEX ix_support_pairing_event_request ON support_pairing_events(request_id,occurred_at,id);

CREATE TABLE support_grant_heads (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    CONSTRAINT fk_support_grant_head FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);

CREATE TABLE support_grants (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    creator_actor_id VARCHAR(255) NOT NULL,
    creator_key VARCHAR(64) NOT NULL,
    creator_member_version BIGINT NOT NULL,
    recipient_actor_id VARCHAR(255) NOT NULL,
    recipient_key VARCHAR(64) NOT NULL,
    recipient_display_name VARCHAR(100),
    recipient_verified_email VARCHAR(254),
    pairing_id VARCHAR(36) NOT NULL,
    type_mask INTEGER NOT NULL,
    state VARCHAR(20) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT uq_support_grant_tenant UNIQUE(tenant_id,id),
    CONSTRAINT uq_support_grant_pairing UNIQUE(pairing_id),
    CONSTRAINT fk_support_grant_pairing FOREIGN KEY(pairing_id) REFERENCES support_pairing_requests(id),
    CONSTRAINT fk_support_grant_creator FOREIGN KEY(tenant_id,creator_key) REFERENCES tenant_members(tenant_id,actor_key),
    CONSTRAINT fk_support_grant_device FOREIGN KEY(tenant_id,device_id) REFERENCES devices(tenant_id,id),
    CONSTRAINT fk_support_grant_subject FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);

CREATE INDEX ix_support_grant_recipient ON support_grants(recipient_key,id);

CREATE INDEX ix_support_grant_device ON support_grants(tenant_id,device_id,id);

CREATE INDEX ix_support_grant_capacity ON support_grants(tenant_id,state,expires_at,id);

CREATE TABLE commercial_accounts (
    tenant_id VARCHAR(36) NOT NULL PRIMARY KEY,
    version BIGINT NOT NULL DEFAULT 0,
    CONSTRAINT fk_commercial_account_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE TABLE commercial_sources (
    tenant_id VARCHAR(36) NOT NULL,
    source_system VARCHAR(30) NOT NULL,
    source_key VARCHAR(64) NOT NULL,
    source_revision BIGINT NOT NULL,
    product_key VARCHAR(80) NOT NULL,
    capacity_kind VARCHAR(10) NOT NULL,
    device_capacity INTEGER NOT NULL,
    features_json TEXT NOT NULL,
    active_from BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    state VARCHAR(10) NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    evidence_hash VARCHAR(64) NOT NULL,
    verified_by VARCHAR(255) NOT NULL,
    verified_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, source_system, source_key),
    CONSTRAINT fk_commercial_source_account FOREIGN KEY (tenant_id) REFERENCES commercial_accounts(tenant_id)
);

CREATE INDEX ix_commercial_source_expiry ON commercial_sources(expires_at, state);

CREATE INDEX ix_commercial_source_active ON commercial_sources(tenant_id, state, active_from, expires_at);

CREATE TABLE commercial_source_events (
    tenant_id VARCHAR(36) NOT NULL,
    source_system VARCHAR(30) NOT NULL,
    source_key VARCHAR(64) NOT NULL,
    source_revision BIGINT NOT NULL,
    id VARCHAR(36) NOT NULL,
    product_key VARCHAR(80) NOT NULL,
    capacity_kind VARCHAR(10) NOT NULL,
    device_capacity INTEGER NOT NULL,
    features_json TEXT NOT NULL,
    active_from BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    state VARCHAR(10) NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    evidence_hash VARCHAR(64) NOT NULL,
    verified_by VARCHAR(255) NOT NULL,
    verified_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id, source_system, source_key, source_revision),
    CONSTRAINT uq_commercial_event_id UNIQUE(id),
    CONSTRAINT fk_commercial_event_source FOREIGN KEY (tenant_id, source_system, source_key)
      REFERENCES commercial_sources(tenant_id, source_system, source_key)
);

CREATE INDEX ix_commercial_event_time ON commercial_source_events(tenant_id, verified_at, id);

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

CREATE TABLE commercial_catalog_offers (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    offer_key VARCHAR(64) NOT NULL,
    sku VARCHAR(80) NOT NULL,
    region VARCHAR(2) NOT NULL,
    channel VARCHAR(24) NOT NULL,
    state VARCHAR(16) NOT NULL,
    revision BIGINT NOT NULL,
    payload_json TEXT NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    created_by VARCHAR(255) NOT NULL,
    last_editor VARCHAR(255) NOT NULL,
    approved_by VARCHAR(255),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT uq_commercial_offer_key UNIQUE (offer_key)
);

CREATE INDEX ix_commercial_offer_operator ON commercial_catalog_offers(state, id);

CREATE INDEX ix_commercial_offer_region ON commercial_catalog_offers(region, channel, state);

CREATE TABLE commercial_catalog_events (
    offer_id VARCHAR(36) NOT NULL,
    revision BIGINT NOT NULL,
    event_id VARCHAR(36) NOT NULL,
    action VARCHAR(24) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    reason VARCHAR(500),
    correlation_id VARCHAR(36) NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    payload_json TEXT NOT NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY (offer_id, revision),
    CONSTRAINT uq_commercial_catalog_event_id UNIQUE (event_id),
    CONSTRAINT fk_commercial_catalog_event_offer FOREIGN KEY (offer_id)
      REFERENCES commercial_catalog_offers(id)
);

CREATE INDEX ix_commercial_catalog_event_time ON commercial_catalog_events(occurred_at, event_id);

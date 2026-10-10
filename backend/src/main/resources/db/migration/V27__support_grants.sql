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

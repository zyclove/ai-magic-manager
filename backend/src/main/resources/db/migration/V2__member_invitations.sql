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

-- Included verbatim in the unreleased 1.0.0 baseline; not an upgrade for an existing database.
CREATE TABLE family_phone_invitations (
 id VARCHAR(36) NOT NULL PRIMARY KEY,
 tenant_id VARCHAR(36) NOT NULL,
 inviter_actor_id VARCHAR(255) NOT NULL,
 recipient_phone_hash VARCHAR(64) NOT NULL,
 recipient_phone_masked VARCHAR(20) NOT NULL,
 token_hash VARCHAR(64) NOT NULL,
 expires_at BIGINT NOT NULL,
 created_at BIGINT NOT NULL,
 consumed_at BIGINT NULL,
 consumed_by_actor_key VARCHAR(64) NULL,
 revoked_at BIGINT NULL,
 accepted_member_version BIGINT NULL,
 CONSTRAINT uq_family_phone_invitation_token UNIQUE(token_hash),
 CONSTRAINT fk_family_phone_invitation_tenant FOREIGN KEY(tenant_id) REFERENCES tenants(id)
);
CREATE INDEX ix_family_phone_invitation_tenant ON family_phone_invitations(tenant_id,created_at,id);

CREATE TABLE family_invitation_attempts (
 actor_key VARCHAR(64) NOT NULL PRIMARY KEY,
 window_start BIGINT NOT NULL,
 attempts INT NOT NULL
);

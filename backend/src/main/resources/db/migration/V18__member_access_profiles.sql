-- Optional display evidence from authenticated issuer claims, never role authority.
CREATE TABLE actor_profiles (
    actor_key VARCHAR(64) NOT NULL PRIMARY KEY,
    actor_id VARCHAR(255) NOT NULL,
    display_name VARCHAR(100),
    verified_email VARCHAR(254),
    claims_issued_at BIGINT NOT NULL,
    observed_at BIGINT NOT NULL
);

-- Existing previews have unknown creators and require conservative re-review on scope loss.
ALTER TABLE policy_previews ADD COLUMN creator_actor_key VARCHAR(64);
CREATE INDEX ix_preview_creator ON policy_previews(tenant_id,creator_actor_key,expires_at);
CREATE INDEX ix_invitation_creator ON member_invitations(tenant_id,inviter_actor_id,revoked_at);
CREATE INDEX ix_enrollment_creator ON device_enrollments(tenant_id,creator_actor_id,state);

CREATE TABLE membership_access_changes (
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

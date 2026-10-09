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
ALTER TABLE membership_access_changes ADD COLUMN previous_class_ids_json TEXT;
ALTER TABLE membership_access_changes ADD COLUMN class_ids_json TEXT;

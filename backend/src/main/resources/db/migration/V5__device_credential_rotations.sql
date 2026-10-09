-- This credential-owned row serializes activation/rotation/revocation for a registration.
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

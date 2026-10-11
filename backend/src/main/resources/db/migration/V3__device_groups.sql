-- Institution-owned device groups. Membership is tied to a registration cycle,
-- so a newly enrolled device cannot inherit an old group's future policy scope.
CREATE TABLE device_groups (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    name VARCHAR(100) NOT NULL,
    name_key VARCHAR(64) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    archived_at BIGINT,
    PRIMARY KEY (tenant_id,id),
    CONSTRAINT uq_device_group_name UNIQUE (tenant_id,name_key),
    CONSTRAINT fk_device_group_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id)
);

CREATE TABLE device_group_members (
    tenant_id VARCHAR(36) NOT NULL,
    group_id VARCHAR(36) NOT NULL,
    device_id VARCHAR(36) NOT NULL,
    registration_id VARCHAR(36) NOT NULL,
    added_at BIGINT NOT NULL,
    PRIMARY KEY (tenant_id,group_id,device_id),
    CONSTRAINT fk_device_group_member_group FOREIGN KEY (tenant_id,group_id)
      REFERENCES device_groups(tenant_id,id),
    CONSTRAINT fk_device_group_member_device FOREIGN KEY (tenant_id,device_id,registration_id)
      REFERENCES devices(tenant_id,id,registration_id)
);

CREATE INDEX ix_device_group_member_device
  ON device_group_members(tenant_id,device_id,group_id);

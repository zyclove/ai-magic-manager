-- A state fact is stored once, independent of the number of currently authorized readers.
CREATE TABLE notification_events (
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

-- Preserve the current fact for pre-existing requests. Do not invent missing transition history.
INSERT INTO notification_events(tenant_id,id,request_id,subject_id,device_id,requester_actor_key,request_version,state,occurred_at)
SELECT tenant_id,id,id,subject_id,device_id,requester_actor_key,version,state,updated_at FROM access_requests;

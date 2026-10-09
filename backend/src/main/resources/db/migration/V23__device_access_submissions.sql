-- Explicit principal kind; legacy user requests retain MEMBER authority semantics.
ALTER TABLE access_requests ADD COLUMN requester_kind VARCHAR(16) NOT NULL DEFAULT 'MEMBER';
CREATE INDEX ix_access_device_requester ON access_requests(tenant_id,device_id,registration_id,requester_kind,id);
-- A matching audit actor key cannot grant a member access to device-originated notifications.
ALTER TABLE notification_events ADD COLUMN requester_kind VARCHAR(16) NOT NULL DEFAULT 'MEMBER';

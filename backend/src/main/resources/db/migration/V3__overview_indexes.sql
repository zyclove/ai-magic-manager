-- Tenant-scoped dashboard aggregates must avoid scanning another tenant's rows.
CREATE INDEX ix_subject_active_count ON subjects(tenant_id, archived_at, id);
CREATE INDEX ix_device_observation_count ON devices(tenant_id, state, last_heartbeat_at);
CREATE INDEX ix_access_pending_count ON access_requests(tenant_id, state, request_expires_at);

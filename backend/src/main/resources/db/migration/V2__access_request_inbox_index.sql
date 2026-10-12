-- Keyset paging for a tenant's state-filtered adult inbox. The query still
-- applies subject and requester scope before rows are returned.
CREATE INDEX ix_access_tenant_state_id ON access_requests(tenant_id,state,id);

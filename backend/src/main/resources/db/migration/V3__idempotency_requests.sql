-- Only non-secret resource responses are retained. Invite/device secrets must not use this journal.
CREATE TABLE idempotency_requests (
    scope_id VARCHAR(100) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    operation VARCHAR(80) NOT NULL,
    key_hash VARCHAR(64) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    response_body TEXT NULL,
    expires_at BIGINT NOT NULL,
    PRIMARY KEY (scope_id, actor_key, operation, key_hash)
);
CREATE INDEX ix_idempotency_expiry ON idempotency_requests(expires_at);

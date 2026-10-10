CREATE TABLE support_pairing_creation_locks (
    actor_key VARCHAR(64) NOT NULL PRIMARY KEY
);
CREATE TABLE support_pairing_heads (
    actor_key VARCHAR(64) NOT NULL PRIMARY KEY,
    create_window BIGINT NOT NULL DEFAULT 0,
    create_count INTEGER NOT NULL DEFAULT 0,
    resolve_window BIGINT NOT NULL DEFAULT 0,
    resolve_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE support_pairing_requests (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    recipient_actor_id VARCHAR(255) NOT NULL,
    recipient_key VARCHAR(64) NOT NULL,
    display_name VARCHAR(100),
    verified_email VARCHAR(254),
    code_hash VARCHAR(64) NOT NULL,
    state VARCHAR(20) NOT NULL,
    version BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT uq_support_pairing_code UNIQUE(code_hash)
);
CREATE INDEX ix_support_pairing_recipient ON support_pairing_requests(recipient_key,id);
CREATE INDEX ix_support_pairing_pending ON support_pairing_requests(recipient_key,state,expires_at,id);
CREATE INDEX ix_support_pairing_expiry ON support_pairing_requests(expires_at,id);
CREATE TABLE support_pairing_events (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    request_id VARCHAR(36) NOT NULL,
    actor_key VARCHAR(64) NOT NULL,
    action VARCHAR(30) NOT NULL,
    occurred_at BIGINT NOT NULL,
    CONSTRAINT fk_support_pairing_event FOREIGN KEY(request_id) REFERENCES support_pairing_requests(id)
);
CREATE INDEX ix_support_pairing_event_request ON support_pairing_events(request_id,occurred_at,id);

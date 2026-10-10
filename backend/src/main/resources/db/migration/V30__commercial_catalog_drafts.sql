-- Platform operator drafts are global, not tenant purchases. Approval does not open sales.
CREATE TABLE commercial_catalog_offers (
    id VARCHAR(36) NOT NULL PRIMARY KEY,
    offer_key VARCHAR(64) NOT NULL,
    sku VARCHAR(80) NOT NULL,
    region VARCHAR(2) NOT NULL,
    channel VARCHAR(24) NOT NULL,
    state VARCHAR(16) NOT NULL,
    revision BIGINT NOT NULL,
    payload_json TEXT NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    created_by VARCHAR(255) NOT NULL,
    last_editor VARCHAR(255) NOT NULL,
    approved_by VARCHAR(255),
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    CONSTRAINT uq_commercial_offer_key UNIQUE (offer_key)
);
CREATE INDEX ix_commercial_offer_operator ON commercial_catalog_offers(state, id);
CREATE INDEX ix_commercial_offer_region ON commercial_catalog_offers(region, channel, state);

-- Every accepted transition stores the complete immutable catalog fact and actor.
CREATE TABLE commercial_catalog_events (
    offer_id VARCHAR(36) NOT NULL,
    revision BIGINT NOT NULL,
    event_id VARCHAR(36) NOT NULL,
    action VARCHAR(24) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    reason VARCHAR(500),
    correlation_id VARCHAR(36) NOT NULL,
    payload_hash VARCHAR(64) NOT NULL,
    payload_json TEXT NOT NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY (offer_id, revision),
    CONSTRAINT uq_commercial_catalog_event_id UNIQUE (event_id),
    CONSTRAINT fk_commercial_catalog_event_offer FOREIGN KEY (offer_id)
      REFERENCES commercial_catalog_offers(id)
);
CREATE INDEX ix_commercial_catalog_event_time ON commercial_catalog_events(occurred_at, event_id);

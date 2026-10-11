-- Provider enrollment is separate from a local agent/device registration.
-- Store only the SHA-256 digest of the random correlation nonce, never token value or QR.
CREATE TABLE managed_enrollment_intents (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    subject_id VARCHAR(36) NOT NULL,
    provider VARCHAR(32) NOT NULL,
    enterprise_id VARCHAR(128) NOT NULL,
    binding_version BIGINT NOT NULL,
    policy_id VARCHAR(128) NOT NULL,
    policy_version BIGINT,
    token_name VARCHAR(300),
    nonce_hash VARCHAR(64) NOT NULL,
    provider_device_id VARCHAR(128),
    provider_mode VARCHAR(32),
    state VARCHAR(20) NOT NULL,
    version BIGINT NOT NULL,
    requested_by VARCHAR(255) NOT NULL,
    created_at BIGINT NOT NULL,
    issued_at BIGINT,
    expires_at BIGINT NOT NULL,
    verified_at BIGINT,
    updated_at BIGINT NOT NULL,
    cleanup_claim_id VARCHAR(36),
    cleanup_lease_until BIGINT,
    cleanup_attempts INTEGER NOT NULL DEFAULT 0,
    next_cleanup_at BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_managed_intent_id UNIQUE(id),
    CONSTRAINT uq_managed_intent_nonce UNIQUE(nonce_hash),
    CONSTRAINT uq_managed_intent_token UNIQUE(token_name),
    CONSTRAINT uq_managed_intent_device UNIQUE(provider,enterprise_id,provider_device_id),
    CONSTRAINT fk_managed_intent_binding FOREIGN KEY(tenant_id)
      REFERENCES managed_enterprise_bindings(tenant_id),
    CONSTRAINT fk_managed_intent_subject FOREIGN KEY(tenant_id,subject_id)
      REFERENCES subjects(tenant_id,id),
    CONSTRAINT ck_managed_intent_state CHECK(state IN
      ('PREPARING','ISSUED','VERIFIED','CANCEL_PENDING','CANCELLED','FAILED','EXPIRED'))
);
CREATE INDEX ix_managed_intent_subject ON managed_enrollment_intents(tenant_id,subject_id,state,expires_at);
CREATE INDEX ix_managed_intent_cleanup ON managed_enrollment_intents(state,next_cleanup_at,id);

CREATE TABLE managed_enrollment_intent_events (
    tenant_id VARCHAR(36) NOT NULL,
    intent_id VARCHAR(36) NOT NULL,
    version BIGINT NOT NULL,
    id VARCHAR(36) NOT NULL,
    action VARCHAR(24) NOT NULL,
    actor_id VARCHAR(255) NOT NULL,
    correlation_id VARCHAR(36) NOT NULL,
    occurred_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,intent_id,version),
    CONSTRAINT uq_managed_intent_event UNIQUE(id),
    CONSTRAINT fk_managed_intent_event FOREIGN KEY(tenant_id,intent_id)
      REFERENCES managed_enrollment_intents(tenant_id,id)
);

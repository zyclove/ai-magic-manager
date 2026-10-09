ALTER TABLE device_enrollments ADD COLUMN recovery_attempts INTEGER NOT NULL DEFAULT 0;

-- One proof purpose + jti can be consumed only once. No original proof/nonce/private key is retained.
CREATE TABLE enrollment_proofs (
    tenant_id VARCHAR(36) NOT NULL,
    enrollment_id VARCHAR(36) NOT NULL,
    purpose VARCHAR(60) NOT NULL,
    jti_hash VARCHAR(64) NOT NULL,
    consumed_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,enrollment_id,purpose,jti_hash),
    CONSTRAINT fk_proof_enrollment FOREIGN KEY(tenant_id,enrollment_id) REFERENCES device_enrollments(tenant_id,id)
);

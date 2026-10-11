-- Provision only in a new, independently backed-up database. Runtime never executes this file.
CREATE TABLE erasure_ledger_head (
    singleton_id INTEGER NOT NULL PRIMARY KEY,
    ledger_id VARCHAR(36) NOT NULL,
    format_version INTEGER NOT NULL,
    last_sequence BIGINT NOT NULL,
    last_hash VARCHAR(64) NOT NULL,
    CONSTRAINT uq_erasure_ledger_identity UNIQUE (ledger_id),
    CONSTRAINT ck_erasure_ledger_singleton CHECK (singleton_id = 1),
    CONSTRAINT ck_erasure_ledger_sequence CHECK (last_sequence >= 0)
) ENGINE=InnoDB;
CREATE TABLE erasure_ledger_entries (
    sequence_number BIGINT NOT NULL PRIMARY KEY,
    request_id VARCHAR(36) NOT NULL,
    request_hash VARCHAR(64) NOT NULL,
    request_json MEDIUMTEXT NOT NULL,
    accepted_at BIGINT NOT NULL,
    previous_hash VARCHAR(64) NOT NULL,
    entry_hash VARCHAR(64) NOT NULL,
    CONSTRAINT uq_erasure_ledger_request UNIQUE (request_id),
    CONSTRAINT ck_erasure_ledger_positive_sequence CHECK (sequence_number > 0),
    CONSTRAINT ck_erasure_ledger_accepted_time CHECK (accepted_at > 0)
) ENGINE=InnoDB;

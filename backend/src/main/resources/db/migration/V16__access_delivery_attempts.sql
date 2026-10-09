ALTER TABLE access_window_documents ADD COLUMN current_attempt INT NOT NULL DEFAULT 1;

CREATE TABLE access_window_attempts (
    tenant_id VARCHAR(36) NOT NULL,
    document_id VARCHAR(36) NOT NULL,
    attempt_number INT NOT NULL,
    created_at BIGINT NOT NULL,
    delivery_state VARCHAR(20) NOT NULL,
    reason_code VARCHAR(40) NULL,
    last_receipt_at BIGINT NULL,
    PRIMARY KEY(tenant_id,document_id,attempt_number),
    CONSTRAINT ck_access_attempt_range CHECK(attempt_number BETWEEN 1 AND 10),
    CONSTRAINT fk_access_attempt_document FOREIGN KEY(tenant_id,document_id) REFERENCES access_window_documents(tenant_id,id)
);

CREATE TABLE access_window_attempt_receipts (
    tenant_id VARCHAR(36) NOT NULL,
    document_id VARCHAR(36) NOT NULL,
    attempt_number INT NOT NULL,
    phase VARCHAR(20) NOT NULL,
    reason_code VARCHAR(40) NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,document_id,attempt_number,phase),
    CONSTRAINT fk_access_receipt_attempt FOREIGN KEY(tenant_id,document_id,attempt_number) REFERENCES access_window_attempts(tenant_id,document_id,attempt_number)
);

INSERT INTO access_window_attempts(tenant_id,document_id,attempt_number,created_at,delivery_state,reason_code,last_receipt_at)
SELECT d.tenant_id,d.id,1,d.issued_at,d.delivery_state,r.reason_code,d.last_receipt_at
FROM access_window_documents d LEFT JOIN access_window_receipts r
ON r.tenant_id=d.tenant_id AND r.document_id=d.id AND r.phase='REJECTED';

INSERT INTO access_window_attempt_receipts(tenant_id,document_id,attempt_number,phase,reason_code,received_at)
SELECT tenant_id,document_id,1,phase,reason_code,received_at FROM access_window_receipts;

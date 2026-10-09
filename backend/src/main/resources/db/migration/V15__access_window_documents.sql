CREATE TABLE access_window_documents (
    tenant_id VARCHAR(36) NOT NULL,
    id VARCHAR(36) NOT NULL,
    request_id VARCHAR(36) NOT NULL,
    approval_version BIGINT NOT NULL,
    action VARCHAR(40) NOT NULL,
    signed_document TEXT NOT NULL,
    issued_at BIGINT NOT NULL,
    delivery_state VARCHAR(20) NOT NULL,
    last_receipt_at BIGINT NULL,
    PRIMARY KEY(tenant_id,id),
    CONSTRAINT uq_access_document_version UNIQUE(tenant_id,request_id,approval_version),
    CONSTRAINT fk_access_document_request FOREIGN KEY(tenant_id,request_id) REFERENCES access_requests(tenant_id,id)
);
CREATE TABLE access_window_receipts (
    tenant_id VARCHAR(36) NOT NULL,
    document_id VARCHAR(36) NOT NULL,
    phase VARCHAR(20) NOT NULL,
    reason_code VARCHAR(40) NULL,
    received_at BIGINT NOT NULL,
    PRIMARY KEY(tenant_id,document_id,phase),
    CONSTRAINT fk_access_receipt_document FOREIGN KEY(tenant_id,document_id) REFERENCES access_window_documents(tenant_id,id)
);
CREATE INDEX ix_access_device_sync ON access_requests(tenant_id,device_id,registration_id,id);

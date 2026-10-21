-- 未发布初始化基线的片段；不得直接对已有生产数据库执行。
CREATE TABLE IF NOT EXISTS family_refund_reviews (
    refund_id VARCHAR(36) NOT NULL PRIMARY KEY,
    tenant_id VARCHAR(36) NOT NULL,
    decision VARCHAR(16) NOT NULL,
    note VARCHAR(200) NOT NULL,
    reviewer_key VARCHAR(64) NOT NULL,
    reviewed_at BIGINT NOT NULL,
    preview_hash VARCHAR(64) NOT NULL,
    CONSTRAINT fk_family_review_refund FOREIGN KEY (refund_id) REFERENCES family_refund_requests(id)
);

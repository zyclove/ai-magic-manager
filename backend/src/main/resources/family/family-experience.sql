CREATE TABLE family_rules (
 tenant_id VARCHAR(36) NOT NULL,
 subject_id VARCHAR(36) NOT NULL,
 policy_id VARCHAR(36) NOT NULL,
 version BIGINT NOT NULL,
 source_sequence BIGINT NOT NULL DEFAULT 0,
 rules_json TEXT NOT NULL,
 updated_at BIGINT NOT NULL,
 PRIMARY KEY(tenant_id,subject_id),
 FOREIGN KEY(tenant_id,subject_id) REFERENCES subjects(tenant_id,id)
);
CREATE TABLE family_runtime_reports (
 tenant_id VARCHAR(36) NOT NULL,
 device_id VARCHAR(36) NOT NULL,
 registration_id VARCHAR(36) NOT NULL,
 report_sequence BIGINT NOT NULL,
 observed_at BIGINT NOT NULL,
 received_at BIGINT NOT NULL,
 report_json TEXT NOT NULL,
 PRIMARY KEY(tenant_id,device_id)
);
CREATE TABLE family_guardian_declarations (
 actor_key VARCHAR(64) NOT NULL PRIMARY KEY,
 phone_hash VARCHAR(64) NOT NULL,
 declaration_version VARCHAR(40) NOT NULL,
 declared_at BIGINT NOT NULL,
 tenant_id VARCHAR(36) NOT NULL
);
CREATE TABLE family_ai_suggestions (
 tenant_id VARCHAR(36) NOT NULL,
 id VARCHAR(36) NOT NULL,
 actor_key VARCHAR(64) NOT NULL,
 subject_id VARCHAR(36) NOT NULL,
 rule_version BIGINT NOT NULL,
 request_hash VARCHAR(64) NOT NULL,
 task VARCHAR(30) NOT NULL,
 result_json TEXT NOT NULL,
 created_at BIGINT NOT NULL,
 expires_at BIGINT NOT NULL,
 PRIMARY KEY(tenant_id,id)
);
CREATE TABLE family_ai_months (
 tenant_id VARCHAR(36) NOT NULL,
 month_key VARCHAR(7) NOT NULL,
 completed INT NOT NULL DEFAULT 0,
 PRIMARY KEY(tenant_id,month_key)
);

CREATE TABLE family_access_requests (
 tenant_id VARCHAR(36) NOT NULL,id VARCHAR(36) NOT NULL,subject_id VARCHAR(36) NOT NULL,
 device_id VARCHAR(36) NOT NULL,registration_id VARCHAR(36) NOT NULL,base_rule_version BIGINT NOT NULL,
 state VARCHAR(20) NOT NULL,requested_seconds INT NOT NULL,granted_seconds INT NULL,reason VARCHAR(300) NOT NULL,
 created_at BIGINT NOT NULL,expires_at BIGINT NOT NULL,not_after BIGINT NULL,version BIGINT NOT NULL,
 PRIMARY KEY(tenant_id,id)
);
CREATE INDEX ix_family_requests_device ON family_access_requests(tenant_id,device_id,created_at);
CREATE TABLE family_temporary_grants (
 tenant_id VARCHAR(36) NOT NULL,device_id VARCHAR(36) NOT NULL,registration_id VARCHAR(36) NOT NULL,
 subject_id VARCHAR(36) NOT NULL,not_after BIGINT NOT NULL,request_id VARCHAR(36) NOT NULL,
 PRIMARY KEY(tenant_id,device_id)
);

-- Versioned default price configuration; this alone does not enable sales.
CREATE TABLE family_product_offers (
 plan_key VARCHAR(40) NOT NULL PRIMARY KEY,version BIGINT NOT NULL,price_minor INT NOT NULL,
 proposed_price INT NULL,proposed_version BIGINT NULL,proposed_actor VARCHAR(64) NULL
);
INSERT INTO family_product_offers(plan_key,version,price_minor) VALUES('FAMILY_MONTH',1,1900),('FAMILY_YEAR',1,19900);
CREATE TABLE family_product_offer_events (
 id VARCHAR(36) NOT NULL PRIMARY KEY,plan_key VARCHAR(40) NOT NULL,version BIGINT NOT NULL,
 operation VARCHAR(20) NOT NULL,price_minor INT NOT NULL,actor_key VARCHAR(64) NOT NULL,occurred_at BIGINT NOT NULL
);

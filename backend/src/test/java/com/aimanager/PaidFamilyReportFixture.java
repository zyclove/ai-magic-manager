package com.aimanager;

import org.springframework.jdbc.core.JdbcTemplate;

/** 旧报告聚合用例显式使用付费权益；免费与到期边界由独立 journey 验证。 */
final class PaidFamilyReportFixture {
  static void grant(JdbcTemplate db,String tenant,long now) {
    db.update("INSERT INTO commercial_accounts(tenant_id,version) VALUES(?,1)",tenant);
    db.update("INSERT INTO commercial_sources(tenant_id,source_system,source_key,source_revision,product_key,capacity_kind,device_capacity,features_json,active_from,expires_at,state,payload_hash,evidence_hash,verified_by,verified_at)"
        +" VALUES(?,'CONTRACT',?,1,'FAMILY','BASE',3,'[]',?,?,'ACTIVE',?,?,'system:report-fixture',?)",
        tenant,"a".repeat(64),now-86400000,now+86400000,"b".repeat(64),"c".repeat(64),now);
  }
  private PaidFamilyReportFixture(){}
}

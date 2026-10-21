package com.aimanager.family;
import java.time.Clock;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
/** Renews signed offline validity without changing the guardian's rule-content revision. */
@Component
@ConditionalOnProperty(name="manager.family.rule-renewal.enabled",havingValue="true",matchIfMissing=true)
class FamilyRuleRenewalJob {
  private final JdbcTemplate jdbc;private final Clock clock;private final FamilyRulesService rules;
  FamilyRuleRenewalJob(JdbcTemplate jdbc,Clock clock,FamilyRulesService rules){this.jdbc=jdbc;this.clock=clock;this.rules=rules;}
  @Scheduled(fixedDelayString="${manager.family.rule-renewal.delay-ms:3600000}",initialDelayString="${manager.family.rule-renewal.initial-delay-ms:60000}")
  void renew(){
    var rows=jdbc.queryForList("SELECT r.tenant_id,r.subject_id,m.actor_id FROM family_rules r JOIN subjects s ON s.tenant_id=r.tenant_id AND s.id=r.subject_id JOIN tenant_members m ON m.tenant_id=r.tenant_id AND m.role='OWNER' AND m.revoked_at IS NULL WHERE s.archived_at IS NULL AND r.updated_at<? ORDER BY r.updated_at LIMIT 50",clock.millis()-86400000);
    for(var row:rows){try{rules.republish((String)row.get("tenant_id"),(String)row.get("actor_id"),(String)row.get("subject_id"));}
      catch(Exception failure){LoggerFactory.getLogger(getClass()).warn("Family configuration renewal deferred: {}",failure.getClass().getSimpleName());}}
  }
}

package com.aimanager.quota.internal;

import com.aimanager.quota.QuotaPlanMaintenance;
import com.aimanager.shared.DomainException;
import java.time.Clock;
import org.slf4j.*;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

@Service
class QuotaPlanWorker implements QuotaPlanMaintenance {
  private static final Logger LOG = LoggerFactory.getLogger(QuotaPlanWorker.class);
  private final JdbcTemplate db;
  private final QuotaPlanService plans;
  private final Clock clock;

  QuotaPlanWorker(JdbcTemplate db, QuotaPlanService plans, Clock clock) {
    this.db = db;
    this.plans = plans;
    this.clock = clock;
  }

  @Override
  public int materializeDue(int limit) {
    if (limit < 1 || limit > 1000) throw DomainException.invalid("INVALID_PAGE_SIZE");
    var due =
        db.query(
            "SELECT tenant_id,id FROM quota_plans WHERE next_materialize_at<=? ORDER BY"
                + " next_materialize_at,id LIMIT ?",
            (row, index) -> new Target(row.getString("tenant_id"), row.getString("id")),
            clock.millis(),
            limit);
    int changed = 0;
    for (var target : due) {
      try {
        if (plans.materializeOne(target.tenant(), target.id())) changed++;
      } catch (RuntimeException failure) {
        LOG.warn("Quota daily materialization failed: {}", failure.getClass().getSimpleName());
        // A failed subject must not monopolize every batch. No ledger transaction is retained here.
        db.update(
            "UPDATE quota_plans SET next_materialize_at=? WHERE tenant_id=? AND id=? AND"
                + " next_materialize_at<=?",
            clock.millis() + 60000,
            target.tenant(),
            target.id(),
            clock.millis());
      }
    }
    return changed;
  }

  private record Target(String tenant, String id) {}
}

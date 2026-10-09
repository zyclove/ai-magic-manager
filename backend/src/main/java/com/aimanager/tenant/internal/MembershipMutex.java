package com.aimanager.tenant.internal;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import java.util.Collection;
import java.util.Comparator;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/** Membership control row precedes stable actor locks; no other module acquires this mutex. */
@Component
class MembershipMutex {
  private final JdbcTemplate jdbc;

  MembershipMutex(JdbcTemplate jdbc) {
    this.jdbc = jdbc;
  }

  String lock(String tenant) {
    if (!TransactionSynchronizationManager.isActualTransactionActive())
      throw new IllegalStateException("Transaction required");
    var rows =
        jdbc.query(
            "SELECT pending_transfer_id FROM ownership_heads WHERE tenant_id=? FOR UPDATE",
            (r, n) -> new Head(r.getString(1)),
            tenant);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0).pending();
  }

  void actors(String tenant, Collection<String> actors) {
    actors.stream()
        .distinct()
        .sorted(Comparator.comparing(ActorKeys::key))
        .forEach(
            actor ->
                jdbc.queryForList(
                    "SELECT actor_key FROM tenant_members WHERE tenant_id=? AND actor_key=? FOR"
                        + " UPDATE",
                    tenant,
                    ActorKeys.key(actor)));
  }

  private record Head(String pending) {}
}

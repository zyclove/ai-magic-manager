package com.aimanager.support.internal;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import java.time.Clock;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

/** Rate attempts commit independently so a failed lookup cannot roll its rate usage back. */
@Service
class SupportPairingBudget {
  private final JdbcTemplate jdbc;
  private final Clock clock;

  SupportPairingBudget(JdbcTemplate jdbc, Clock clock) {
    this.jdbc = jdbc;
    this.clock = clock;
  }

  @Transactional(propagation = Propagation.REQUIRES_NEW, timeout = 5)
  public void creation(String actor) {
    consume(actor, "create", 5);
  }

  @Transactional(propagation = Propagation.REQUIRES_NEW, timeout = 5)
  public void resolution(String actor) {
    consume(actor, "resolve", 60);
  }

  private void consume(String actor, String operation, int maximum) {
    String key = ActorKeys.key(actor);
    // Obtain a write lock directly. Catching a duplicate INSERT first takes shared locks on
    // MySQL, so parallel transactions can deadlock when both later upgrade to FOR UPDATE.
    jdbc.update(
        "INSERT INTO support_pairing_heads(actor_key) VALUES(?)"
            + " ON DUPLICATE KEY UPDATE actor_key=actor_key",
        key);
    var previous =
        jdbc.queryForMap(
            "SELECT "
                + operation
                + "_window AS window_start,"
                + operation
                + "_count AS attempt_count FROM support_pairing_heads WHERE actor_key=? FOR UPDATE",
            key);
    long now = clock.millis(), start = ((Number) previous.get("window_start")).longValue();
    int count = ((Number) previous.get("attempt_count")).intValue();
    if (now < start || now - start >= 60000) {
      start = now;
      count = 0;
    }
    if (count >= maximum)
      throw new DomainException(HttpStatus.TOO_MANY_REQUESTS, "SUPPORT_PAIRING_RATE_LIMITED");
    jdbc.update(
        "UPDATE support_pairing_heads SET "
            + operation
            + "_window=?,"
            + operation
            + "_count=? WHERE actor_key=?",
        start,
        count + 1,
        key);
  }
}

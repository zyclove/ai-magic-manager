package com.aimanager.policy.internal;

import com.aimanager.policy.PolicyDiagnosticHashes;
import com.aimanager.shared.DomainException;
import java.sql.Connection;
import java.util.Map;
import java.util.TreeMap;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

@Service
class PolicyDiagnosticHashReader implements PolicyDiagnosticHashes {
  private final JdbcTemplate jdbc;

  PolicyDiagnosticHashReader(JdbcTemplate jdbc) {
    this.jdbc = jdbc;
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public Map<String, String> forAuthorizedDiagnostic(String tenant, Map<String, String> refs) {
    if (!Integer.valueOf(Connection.TRANSACTION_READ_COMMITTED)
        .equals(TransactionSynchronizationManager.getCurrentTransactionIsolationLevel()))
      throw new IllegalStateException("Diagnostic hashes require READ_COMMITTED");
    if (refs.size() > 100)
      throw new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "DIAGNOSTIC_TOO_LARGE");
    var result = new TreeMap<String, String>();
    // Versions are immutable. Do not invert publication's policy-before-device lock order.
    for (var entry : new TreeMap<>(refs).entrySet()) {
      var hashes =
          jdbc.queryForList(
              "SELECT preview_hash FROM policy_versions WHERE tenant_id=?"
                  + " AND id=? AND policy_id=?",
              String.class,
              tenant,
              entry.getKey(),
              entry.getValue());
      if (hashes.size() != 1 || hashes.get(0) == null)
        throw new DomainException(HttpStatus.BAD_GATEWAY, "DIAGNOSTIC_SOURCE_INVALID");
      result.put(entry.getKey(), hashes.get(0));
    }
    return Map.copyOf(result);
  }
}

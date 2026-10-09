package com.aimanager.audit;

import com.aimanager.shared.DomainException;
import java.util.*;

/** Canonical audit selection shared by interactive reads and asynchronous exports. */
public record AuditSelection(
    long from, long to, String action, String resourceId, String correlationId) {
  public AuditSelection {
    if (from < 0 || to <= from || to > 8640000000000000L || to - from > 366L * 86400000)
      throw DomainException.invalid("INVALID_AUDIT_RANGE");
    if (action != null && !action.matches("[A-Z][A-Z0-9_]{0,99}"))
      throw DomainException.invalid("INVALID_AUDIT_ACTION");
    if (resourceId != null && !resourceId.matches("[0-9a-f]{64}")) uuid(resourceId);
    if (correlationId != null) uuid(correlationId);
  }

  public static void uuid(String value) {
    try {
      if (!UUID.fromString(value).toString().equals(value)) throw new IllegalArgumentException();
    } catch (IllegalArgumentException invalid) {
      throw DomainException.invalid("INVALID_AUDIT_ID");
    }
  }

  public Map<String, Object> attributes() {
    var result = new TreeMap<String, Object>();
    result.put("from", from);
    result.put("to", to);
    result.put("action", action);
    result.put("resourceId", resourceId);
    result.put("correlationId", correlationId);
    return Collections.unmodifiableMap(result);
  }

  public String fingerprintMaterial() {
    return from + "|" + to + "|" + action + "|" + resourceId + "|" + correlationId;
  }

  public Predicate predicate(String tenant) {
    var sql = new StringBuilder("tenant_id=? AND occurred_at>=? AND occurred_at<?");
    var parameters = new ArrayList<Object>(List.of(tenant, from, to));
    if (action != null) {
      sql.append(" AND action=?");
      parameters.add(action);
    }
    if (resourceId != null) {
      sql.append(" AND resource_id=?");
      parameters.add(resourceId);
    }
    if (correlationId != null) {
      sql.append(" AND correlation_id=?");
      parameters.add(correlationId);
    }
    return new Predicate(sql.toString(), List.copyOf(parameters));
  }

  public record Predicate(String sql, List<Object> parameters) {}
}

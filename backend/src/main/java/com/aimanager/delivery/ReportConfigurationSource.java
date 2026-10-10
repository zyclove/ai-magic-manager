package com.aimanager.delivery;

import com.aimanager.fleet.Device;
import java.util.List;
import java.util.Map;

/**
 * Current device-scoped configuration evidence, never historical or verified execution. Call only
 * inside the report transaction after current member, scope and device authorization; retain those
 * locks until the response has been checked for serialization and size.
 */
public interface ReportConfigurationSource {
  Map<String, State> forAuthorizedReport(String tenant, List<Device> devices);

  record State(long checkedAt, String evidenceStatus, List<Configuration> configurations) {
    public State {
      configurations = List.copyOf(configurations);
    }
  }

  record Configuration(
      String id,
      String policyId,
      String versionId,
      long sourceSequence,
      String action,
      String deliveryState,
      long issuedAt,
      long deliveryExpiresAt,
      Long firstServedAt,
      Long receivedReportedAt,
      Long storedReportedAt,
      String rejectionCode,
      String name,
      List<Rule> rules) {
    public Configuration {
      rules = List.copyOf(rules);
    }
  }

  record Rule(
      String kind,
      String predictedEffect,
      String status,
      String reasonCode,
      String applicationName,
      String platform,
      String profile,
      String packageName,
      String scheduleName,
      String permission,
      String domain,
      Long seconds,
      boolean required) {}
}

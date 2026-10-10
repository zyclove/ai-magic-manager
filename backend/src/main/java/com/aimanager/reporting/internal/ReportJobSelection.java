package com.aimanager.reporting.internal;

import com.aimanager.shared.DomainException;
import java.util.*;

record ReportJobSelection(
    List<String> deviceIds,
    long from,
    long to,
    String timeZone,
    String period,
    UsageReportScope.Selection scope) {
  ReportJobSelection {
    if (deviceIds == null
        || deviceIds.isEmpty()
        || deviceIds.size() > 200
        || new HashSet<>(deviceIds).size() != deviceIds.size()
        || deviceIds.stream()
            .anyMatch(
                id ->
                    id == null
                        || !id.matches(
                            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
        || scope == null) throw DomainException.invalid("INVALID_REPORT_SELECTION");
    deviceIds = deviceIds.stream().sorted().toList();
  }
}

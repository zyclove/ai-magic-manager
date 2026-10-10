package com.aimanager.reporting.internal;

import com.aimanager.deviceidentity.DeviceContext;
import com.aimanager.shared.DomainException;
import java.util.Set;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.core.OAuth2AuthenticatedPrincipal;
import org.springframework.util.MultiValueMap;
import org.springframework.web.bind.annotation.*;

/**
 * Device credentials authorize exactly the current authenticated registration, never a selector.
 */
@RestController
class DeviceUsageReportController {
  private final UsageReportService reports;

  DeviceUsageReportController(UsageReportService reports) {
    this.reports = reports;
  }

  @GetMapping("/api/v1/device-api/usage-report")
  ResponseEntity<UsageReportService.Report> read(
      @AuthenticationPrincipal OAuth2AuthenticatedPrincipal actor,
      @RequestParam long from,
      @RequestParam long to,
      @RequestParam String timeZone,
      @RequestParam(defaultValue = "DAY") String period,
      @RequestParam MultiValueMap<String, String> parameters) {
    if (!Set.of("from", "to", "timeZone", "period").containsAll(parameters.keySet())
        || parameters.values().stream().anyMatch(values -> values.size() != 1))
      throw DomainException.invalid("INVALID_USAGE_REPORT_QUERY");
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(reports.queryDevice(DeviceContext.from(actor), from, to, timeZone, period));
  }
}

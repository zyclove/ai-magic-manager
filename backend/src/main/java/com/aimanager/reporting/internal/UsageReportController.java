package com.aimanager.reporting.internal;

import java.util.List;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
class UsageReportController {
  private final UsageReportService reports;

  UsageReportController(UsageReportService reports) {
    this.reports = reports;
  }

  @GetMapping("/api/v1/tenants/{tenantId}/usage-reports")
  ResponseEntity<UsageReportService.Report> query(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam List<String> deviceId,
      @RequestParam long from,
      @RequestParam long to,
      @RequestParam String timeZone,
      @RequestParam(defaultValue = "DAY") String period,
      @RequestParam(defaultValue = "DEVICES") String scopeKind,
      @RequestParam(required = false) String scopeId,
      @RequestParam(required = false) Long scopeVersion) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(
            reports.query(
                tenantId,
                actor.getSubject(),
                deviceId,
                from,
                to,
                timeZone,
                period,
                new UsageReportScope.Selection(scopeKind, scopeId, scopeVersion)));
  }
}

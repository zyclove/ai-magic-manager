package com.aimanager.reporting.internal;

import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/** Adult-only explanation of seven complete local days; creates no policy or stored profile. */
@RestController
class WellbeingInsightController {
  private final WellbeingInsightService service;

  WellbeingInsightController(WellbeingInsightService service) {
    this.service = service;
  }

  @GetMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/wellbeing-insight")
  ResponseEntity<WellbeingInsightService.Insight> read(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String deviceId) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(service.read(tenantId, actor.getSubject(), deviceId));
  }
}

package com.aimanager.schedule.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.tenant.TenantAccess;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/** Read-only drafting assistance; normal schedule creation remains the only write path. */
@RestController
class SchedulePresetController {
  private final TenantAccess access;
  private final SchedulePresetCatalog presets;

  SchedulePresetController(TenantAccess access, SchedulePresetCatalog presets) {
    this.access = access;
    this.presets = presets;
  }

  @GetMapping("/api/v1/tenants/{tenantId}/schedule-presets")
  ResponseEntity<SchedulePresetCatalog.Catalog> list(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenantId) {
    access.requireRole(tenantId, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    return ResponseEntity.ok().cacheControl(CacheControl.noStore())
        .varyBy("Authorization").body(presets.read());
  }
}

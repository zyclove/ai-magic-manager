package com.aimanager.overview.internal;

import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/overview")
class OverviewController {
  private final OverviewReadService reads;

  OverviewController(OverviewReadService reads) {
    this.reads = reads;
  }

  /** Counts and recent activity are projected from the caller's current persisted membership. */
  @GetMapping
  ResponseEntity<OverviewReadService.Summary> get(
      @AuthenticationPrincipal Jwt actor, @PathVariable String tenantId) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .body(reads.read(tenantId, actor.getSubject()));
  }
}

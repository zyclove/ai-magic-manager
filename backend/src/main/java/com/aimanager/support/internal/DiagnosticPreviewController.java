package com.aimanager.support.internal;

import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
class DiagnosticPreviewController {
  private final DiagnosticPreviewService previews;

  DiagnosticPreviewController(DiagnosticPreviewService previews) {
    this.previews = previews;
  }

  @GetMapping("/api/v1/tenants/{tenantId}/devices/{deviceId}/diagnostic-preview")
  ResponseEntity<byte[]> preview(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String deviceId) {
    return ResponseEntity.ok()
        .contentType(MediaType.APPLICATION_JSON)
        .cacheControl(CacheControl.noStore())
        .header("Vary", "Authorization")
        .body(previews.preview(tenantId, deviceId, actor));
  }
}

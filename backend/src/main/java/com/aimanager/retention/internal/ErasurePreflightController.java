package com.aimanager.retention.internal;

import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
final class ErasurePreflightController {
  private final ErasurePreflightService service;

  ErasurePreflightController(ErasurePreflightService service) {
    this.service = service;
  }

  @GetMapping("/api/v1/tenants/{tenant}/subjects/{subject}/erasure-preflight")
  ResponseEntity<ErasurePreflightService.Preflight> inspect(
      @PathVariable String tenant,
      @PathVariable String subject,
      @AuthenticationPrincipal Jwt actor) {
    return ResponseEntity.ok()
        .header("Cache-Control", "no-store")
        .body(service.inspect(tenant, subject, actor));
  }
}

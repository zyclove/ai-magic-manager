package com.aimanager.retention.internal;

import com.aimanager.shared.ResourceVersions;
import org.springframework.http.*;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenant}/subjects/{subject}/erasure-previews")
class ErasurePreviewController {
  private final ErasurePreviewService service;

  ErasurePreviewController(ErasurePreviewService service) {
    this.service = service;
  }

  @PostMapping
  ResponseEntity<ErasurePreviewService.Preview> create(
      @PathVariable String tenant,
      @PathVariable String subject,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(HttpStatus.CREATED, service.create(tenant, subject, actor, etag, key));
  }

  @GetMapping("/{id}")
  ResponseEntity<ErasurePreviewService.Preview> get(
      @PathVariable String tenant,
      @PathVariable String subject,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor) {
    return response(HttpStatus.OK, service.get(tenant, subject, id, actor));
  }

  @PostMapping("/{id}/cancel")
  ResponseEntity<ErasurePreviewService.Preview> cancel(
      @PathVariable String tenant,
      @PathVariable String subject,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(name = "If-Match", required = false) String etag) {
    return response(HttpStatus.OK, service.cancel(tenant, subject, id, actor, etag));
  }

  private ResponseEntity<ErasurePreviewService.Preview> response(
      HttpStatus status, ErasurePreviewService.Preview body) {
    return ResponseEntity.status(status)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .eTag(ResourceVersions.tag(body.version()))
        .body(body);
  }
}

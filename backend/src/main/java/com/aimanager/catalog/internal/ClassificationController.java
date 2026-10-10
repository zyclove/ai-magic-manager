package com.aimanager.catalog.internal;

import com.aimanager.catalog.ApplicationCategories.*;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/applications/{applicationId}/classification")
class ClassificationController {
  private final ClassificationService service;

  ClassificationController(ClassificationService service) {
    this.service = service;
  }

  @GetMapping
  ResponseEntity<Classification> read(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String applicationId) {
    return response(service.read(tenantId, actor.getSubject(), applicationId));
  }

  @PutMapping
  ResponseEntity<Classification> update(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String applicationId,
      @RequestHeader(name = "If-Match", required = false) String version,
      @RequestHeader(name = "Idempotency-Key", required = false) String key,
      @Valid @RequestBody Update input) {
    return response(
        service.update(
            tenantId,
            actor.getSubject(),
            applicationId,
            ResourceVersions.require(version),
            key,
            input.category()));
  }

  private ResponseEntity<Classification> response(Classification value) {
    return ResponseEntity.ok()
        .header("Cache-Control", "no-store")
        .header("Vary", "Authorization")
        .eTag(ResourceVersions.tag(value.version()))
        .body(value);
  }

  record Update(@NotNull Category category) {}
}

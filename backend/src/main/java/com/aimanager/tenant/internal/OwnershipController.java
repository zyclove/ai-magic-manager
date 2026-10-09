package com.aimanager.tenant.internal;

import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/ownership-transfers")
class OwnershipController {
  private final OwnershipService service;

  OwnershipController(OwnershipService service) {
    this.service = service;
  }

  @GetMapping
  ItemPage<OwnershipService.Transfer> list(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return service.list(tenantId, actor.getSubject(), limit, cursor);
  }

  @GetMapping("/{id}")
  ResponseEntity<OwnershipService.Transfer> get(
      @PathVariable String tenantId, @PathVariable String id, @AuthenticationPrincipal Jwt actor) {
    return response(HttpStatus.OK, service.get(tenantId, id, actor.getSubject()));
  }

  @PostMapping
  ResponseEntity<OwnershipService.Transfer> start(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @Valid @RequestBody Start input,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return response(
        HttpStatus.CREATED, service.start(tenantId, actor, input.targetActorId(), etag, key));
  }

  @PostMapping("/{id}/{action:accept|decline|cancel}")
  ResponseEntity<OwnershipService.Transfer> act(
      @PathVariable String tenantId,
      @PathVariable String id,
      @PathVariable String action,
      @AuthenticationPrincipal Jwt actor,
      Authentication auth,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    boolean adult =
        auth.getAuthorities().stream()
            .anyMatch(a -> "SCOPE_tenant:create".equals(a.getAuthority()));
    return response(HttpStatus.OK, service.act(tenantId, id, actor, adult, action, etag, key));
  }

  private ResponseEntity<OwnershipService.Transfer> response(
      HttpStatus status, OwnershipService.Transfer t) {
    return ResponseEntity.status(status).eTag(ResourceVersions.tag(t.version())).body(t);
  }

  record Start(@NotBlank @Size(max = 255) String targetActorId) {}
}

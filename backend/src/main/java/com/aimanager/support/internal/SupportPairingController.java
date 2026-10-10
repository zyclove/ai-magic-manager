package com.aimanager.support.internal;

import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
class SupportPairingController {
  private final SupportPairingService service;

  SupportPairingController(SupportPairingService service) {
    this.service = service;
  }

  @PostMapping("/api/v1/support/pairing-requests")
  ResponseEntity<SupportPairingService.Created> create(
      @AuthenticationPrincipal Jwt actor,
      Authentication auth,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    var result = service.create(actor, adult(auth), key);
    return response(HttpStatus.CREATED, result.request().version(), result);
  }

  @GetMapping("/api/v1/support/pairing-requests")
  ResponseEntity<ItemPage<SupportPairingService.Pairing>> list(
      @AuthenticationPrincipal Jwt actor,
      Authentication auth,
      @RequestParam(defaultValue = "25") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(service.list(actor, adult(auth), limit, cursor));
  }

  @GetMapping("/api/v1/support/pairing-requests/{id}")
  ResponseEntity<SupportPairingService.Pairing> get(
      @PathVariable String id, @AuthenticationPrincipal Jwt actor, Authentication auth) {
    var result = service.get(id, actor, adult(auth));
    return response(HttpStatus.OK, result.version(), result);
  }

  @PostMapping("/api/v1/support/pairing-requests/{id}/cancel")
  ResponseEntity<SupportPairingService.Pairing> cancel(
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      Authentication auth,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    var result = service.cancel(id, actor, adult(auth), etag, key);
    return response(HttpStatus.OK, result.version(), result);
  }

  @PostMapping("/api/v1/tenants/{tenant}/support-pairing/resolve")
  ResponseEntity<SupportPairingService.Pairing> resolve(
      @PathVariable String tenant,
      @AuthenticationPrincipal Jwt actor,
      @Valid @RequestBody Resolve input) {
    var result = service.resolve(tenant, actor, input.code());
    return response(HttpStatus.OK, result.version(), result);
  }

  private boolean adult(Authentication auth) {
    return auth.getAuthorities().stream()
        .anyMatch(a -> a.getAuthority().equals("SCOPE_tenant:create"));
  }

  private <T> ResponseEntity<T> response(HttpStatus status, long version, T body) {
    return ResponseEntity.status(status)
        .eTag(ResourceVersions.tag(version))
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(body);
  }

  record Resolve(@NotBlank @Pattern(regexp = "[A-Za-z0-9_-]{43}") String code) {}
}

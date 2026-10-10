package com.aimanager.support.internal;

import com.aimanager.shared.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import java.util.List;
import org.springframework.http.*;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
class SupportGrantController {
  private final SupportGrantService service;

  SupportGrantController(SupportGrantService service) {
    this.service = service;
  }

  @PostMapping("/api/v1/tenants/{tenant}/devices/{device}/support-grants")
  ResponseEntity<SupportGrantStore.Grant> create(
      @PathVariable String tenant,
      @PathVariable String device,
      @AuthenticationPrincipal Jwt actor,
      @Valid @RequestBody Create input,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return grant(
        HttpStatus.CREATED,
        service.create(
            tenant,
            device,
            actor,
            new SupportGrantService.Create(
                input.pairingCode(),
                input.recipientActorId(),
                input.registrationId(),
                input.diagnosticTypes(),
                input.durationMinutes()),
            etag,
            key));
  }

  @GetMapping("/api/v1/tenants/{tenant}/support-grants")
  ResponseEntity<ItemPage<SupportGrantStore.Grant>> list(
      @PathVariable String tenant,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue = "25") int limit,
      @RequestParam(required = false) String cursor) {
    return page(service.customerList(tenant, actor, limit, cursor));
  }

  @GetMapping("/api/v1/tenants/{tenant}/support-grants/{id}")
  ResponseEntity<SupportGrantStore.Grant> get(
      @PathVariable String tenant, @PathVariable String id, @AuthenticationPrincipal Jwt actor) {
    return grant(HttpStatus.OK, service.customerGet(tenant, id, actor));
  }

  @PostMapping("/api/v1/tenants/{tenant}/support-grants/{id}/revoke")
  ResponseEntity<SupportGrantStore.Grant> revoke(
      @PathVariable String tenant,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return grant(HttpStatus.OK, service.revoke(tenant, id, actor, etag, key));
  }

  @GetMapping("/api/v1/support/grants")
  ResponseEntity<ItemPage<SupportGrantStore.Grant>> received(
      @AuthenticationPrincipal Jwt actor,
      Authentication auth,
      @RequestParam(defaultValue = "25") int limit,
      @RequestParam(required = false) String cursor) {
    return page(service.recipientList(actor, adult(auth), limit, cursor));
  }

  @GetMapping("/api/v1/support/grants/{id}")
  ResponseEntity<SupportGrantStore.Grant> receivedOne(
      @PathVariable String id, @AuthenticationPrincipal Jwt actor, Authentication auth) {
    return grant(HttpStatus.OK, service.recipientGet(id, actor, adult(auth)));
  }

  @GetMapping("/api/v1/support/grants/{id}/diagnostic-preview")
  ResponseEntity<byte[]> preview(
      @PathVariable String id, @AuthenticationPrincipal Jwt actor, Authentication auth) {
    return ResponseEntity.ok()
        .contentType(MediaType.APPLICATION_JSON)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(service.preview(id, actor, adult(auth)));
  }

  private boolean adult(Authentication auth) {
    return auth.getAuthorities().stream()
        .anyMatch(a -> a.getAuthority().equals("SCOPE_tenant:create"));
  }

  private ResponseEntity<SupportGrantStore.Grant> grant(
      HttpStatus status, SupportGrantStore.Grant value) {
    return ResponseEntity.status(status)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .eTag(ResourceVersions.tag(value.version()))
        .body(value);
  }

  private ResponseEntity<ItemPage<SupportGrantStore.Grant>> page(
      ItemPage<SupportGrantStore.Grant> value) {
    return ResponseEntity.ok()
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(value);
  }

  record Create(
      @NotBlank @Pattern(regexp = "[A-Za-z0-9_-]{43}") String pairingCode,
      @NotBlank @Size(max = 255) String recipientActorId,
      @NotBlank @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
          String registrationId,
      @NotNull @Size(min = 1, max = 3) List<@NotBlank String> diagnosticTypes,
      @Min(5) @Max(1440) int durationMinutes) {}
}

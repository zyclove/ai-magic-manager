package com.aimanager.support.internal;

import com.aimanager.shared.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.*;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

@RestController
class DiagnosticPackageController {
  private final DiagnosticPackageService jobs;

  DiagnosticPackageController(DiagnosticPackageService jobs) {
    this.jobs = jobs;
  }

  record Create(
      @NotBlank @Pattern(regexp = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
          String registrationId) {}

  @PostMapping("/api/v1/tenants/{tenant}/devices/{device}/diagnostic-packages")
  ResponseEntity<DiagnosticPackageStore.Job> createAdmin(
      @PathVariable String tenant,
      @PathVariable String device,
      @AuthenticationPrincipal Jwt actor,
      @Valid @RequestBody Create input,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return job(
        HttpStatus.ACCEPTED,
        jobs.createAdmin(tenant, device, input.registrationId(), actor, etag, key));
  }

  @PostMapping("/api/v1/support/grants/{grant}/diagnostic-packages")
  ResponseEntity<DiagnosticPackageStore.Job> createRecipient(
      @PathVariable String grant,
      @AuthenticationPrincipal Jwt actor,
      Authentication auth,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return job(HttpStatus.ACCEPTED, jobs.createRecipient(grant, actor, adult(auth), key));
  }

  @GetMapping({
    "/api/v1/tenants/{tenant}/diagnostic-packages",
    "/api/v1/support/diagnostic-packages"
  })
  ResponseEntity<ItemPage<DiagnosticPackageStore.Job>> list(
      @PathVariable(required = false) String tenant,
      @AuthenticationPrincipal Jwt actor,
      Authentication auth,
      @RequestParam(defaultValue = "25") int limit,
      @RequestParam(required = false) String cursor) {
    return response(
        HttpStatus.OK, jobs.list(tenant, actor, adult(auth), mode(tenant), limit, cursor));
  }

  @GetMapping({
    "/api/v1/tenants/{tenant}/diagnostic-packages/{id}",
    "/api/v1/support/diagnostic-packages/{id}"
  })
  ResponseEntity<DiagnosticPackageStore.Job> get(
      @PathVariable(required = false) String tenant,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      Authentication auth) {
    return job(HttpStatus.OK, jobs.get(tenant, id, actor, adult(auth), mode(tenant)));
  }

  @PostMapping({
    "/api/v1/tenants/{tenant}/diagnostic-packages/{id}/cancel",
    "/api/v1/support/diagnostic-packages/{id}/cancel"
  })
  ResponseEntity<DiagnosticPackageStore.Job> cancel(
      @PathVariable(required = false) String tenant,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      Authentication auth,
      @RequestHeader(name = "If-Match", required = false) String etag,
      @RequestHeader(name = "Idempotency-Key", required = false) String key) {
    return job(HttpStatus.OK, jobs.cancel(tenant, id, actor, adult(auth), mode(tenant), etag, key));
  }

  @GetMapping({
    "/api/v1/tenants/{tenant}/diagnostic-packages/{id}/content",
    "/api/v1/support/diagnostic-packages/{id}/content"
  })
  ResponseEntity<byte[]> content(
      @PathVariable(required = false) String tenant,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      Authentication auth) {
    byte[] bytes = jobs.content(tenant, id, actor, adult(auth), mode(tenant));
    return ResponseEntity.ok()
        .contentType(MediaType.APPLICATION_JSON)
        .contentLength(bytes.length)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .header(
            HttpHeaders.CONTENT_DISPOSITION,
            ContentDisposition.attachment()
                .filename("diagnostic-" + id + ".json")
                .build()
                .toString())
        .body(bytes);
  }

  private String mode(String tenant) {
    return tenant == null ? "SUPPORT_GRANT" : "ADMIN";
  }

  private boolean adult(Authentication auth) {
    return auth.getAuthorities().stream()
        .anyMatch(value -> value.getAuthority().equals("SCOPE_tenant:create"));
  }

  private ResponseEntity<DiagnosticPackageStore.Job> job(
      HttpStatus status, DiagnosticPackageStore.Job value) {
    return ResponseEntity.status(status)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .eTag(ResourceVersions.tag(value.version()))
        .body(value);
  }

  private <T> ResponseEntity<T> response(HttpStatus status, T value) {
    return ResponseEntity.status(status)
        .cacheControl(CacheControl.noStore())
        .varyBy("Authorization")
        .body(value);
  }
}

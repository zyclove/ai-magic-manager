package com.aimanager.managedandroid.internal;

import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Administrator-only enrollment: provider secrets are sent once with no-store responses. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/managed-android/enrollment-intents")
class ManagedEnrollmentController {
  private final ManagedEnrollmentService service;
  private final RecentAuthentication recent;

  ManagedEnrollmentController(ManagedEnrollmentService service, RecentAuthentication recent) {
    this.service = service;
    this.recent = recent;
  }

  @PostMapping
  ResponseEntity<ManagedEnrollmentService.Issued> create(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @RequestBody Create input) {
    recent.require(actor);
    if (input == null || input.subjectId() == null)
      throw DomainException.invalid("INVALID_MANAGED_ENROLLMENT");
    var result = service.issue(tenantId, actor.getSubject(), input.subjectId());
    return ResponseEntity.status(HttpStatus.CREATED)
        .eTag(ResourceVersions.tag(result.intent().version()))
        .cacheControl(CacheControl.noStore()).header("Vary", "Authorization")
        .body(result);
  }

  @GetMapping
  ResponseEntity<ItemPage<ManagedEnrollmentService.View>> list(
      @PathVariable String tenantId,
      @AuthenticationPrincipal Jwt actor,
      @RequestParam(defaultValue = "50") int limit,
      @RequestParam(required = false) String cursor) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).header("Vary", "Authorization")
        .body(service.list(tenantId, actor.getSubject(), limit, cursor));
  }

  @GetMapping("/{id}")
  ResponseEntity<ManagedEnrollmentService.View> get(
      @PathVariable String tenantId,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor) {
    return response(service.get(tenantId, id, actor.getSubject()));
  }

  /** On-demand provider read; no cache and no claim about the local child agent. */
  @GetMapping("/{id}/provider-status")
  ResponseEntity<ManagedEnrollmentService.ProviderStatus> providerStatus(
      @PathVariable String tenantId,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor) {
    return ResponseEntity.ok().cacheControl(CacheControl.noStore()).header("Vary", "Authorization")
        .body(service.providerStatus(tenantId, id, actor.getSubject()));
  }

  @PostMapping("/{id}/verify")
  ResponseEntity<ManagedEnrollmentService.View> verify(
      @PathVariable String tenantId,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String ifMatch,
      @RequestBody Verify input) {
    recent.require(actor);
    if (input == null) throw DomainException.invalid("INVALID_PROVIDER_DEVICE_ID");
    return response(service.verify(tenantId, id, actor.getSubject(), input.providerDeviceId(),
        ResourceVersions.require(ifMatch)));
  }

  @PostMapping("/{id}/cancel")
  ResponseEntity<ManagedEnrollmentService.View> cancel(
      @PathVariable String tenantId,
      @PathVariable String id,
      @AuthenticationPrincipal Jwt actor,
      @RequestHeader(value = "If-Match", required = false) String ifMatch) {
    recent.require(actor);
    return response(service.cancel(tenantId, id, actor.getSubject(), ResourceVersions.require(ifMatch)));
  }

  private static ResponseEntity<ManagedEnrollmentService.View> response(
      ManagedEnrollmentService.View view) {
    return ResponseEntity.ok().eTag(ResourceVersions.tag(view.version()))
        .cacheControl(CacheControl.noStore()).header("Vary", "Authorization").body(view);
  }

  record Create(String subjectId) {}
  record Verify(String providerDeviceId) {}
}
